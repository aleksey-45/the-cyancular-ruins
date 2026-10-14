#include <crt_externs.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <cerrno>
#include <cstring>
#include <map>
#include <vector>

using namespace godot;

struct FileDescriptor {
	int value = -1;
	~FileDescriptor() { if (value >= 0) close(value); }
	int release() { int result = value; value = -1; return result; }
};

static pid_t wait_child(pid_t pid, int *status, int options = 0) {
	pid_t result;
	do { result = waitpid(pid, status, options); } while (result < 0 && errno == EINTR);
	return result;
}

class OwnedProcessGroup : public RefCounted {
	GDCLASS(OwnedProcessGroup, RefCounted)
	struct Child { int output; bool exited = false; int code = 259; };
	std::map<int64_t, Child> children;
	pid_t watcher = 0;
	int lifetime = -1;

	static int64_t error(const char *operation, int code = errno) {
		UtilityFunctions::push_error(operation, ": ", String::utf8(strerror(code)));
		return -1;
	}

	bool start_watcher() {
		int pipe_fd[2];
		if (pipe(pipe_fd) < 0) { error("pipe"); return false; }
		FileDescriptor reader, writer;
		reader.value = pipe_fd[0]; writer.value = pipe_fd[1];
		if (fcntl(reader.value, F_SETFD, FD_CLOEXEC) < 0 || fcntl(writer.value, F_SETFD, FD_CLOEXEC) < 0) {
			error("fcntl"); return false;
		}
		pid_t pid = fork();
		if (pid < 0) { error("fork"); return false; }
		if (pid == 0) {
			// After fork, use only async-signal-safe syscalls in this multithreaded host.
			close(writer.value);
			setpgid(0, 0);
			char byte;
			ssize_t count;
			do { count = read(reader.value, &byte, 1); } while (count > 0 || (count < 0 && errno == EINTR));
			kill(-getpid(), SIGKILL);
			_exit(0);
		}
		// Establish the group before spawning its first member.
		if (setpgid(pid, pid) < 0) {
			error("setpgid"); kill(pid, SIGKILL); wait_child(pid, nullptr); return false;
		}
		watcher = pid;
		lifetime = writer.release();
		return true;
	}

	void forget(std::map<int64_t, Child>::iterator child) {
		if (child->second.output >= 0) close(child->second.output);
		children.erase(child);
	}

protected:
	static void _bind_methods() {
		ClassDB::bind_method(D_METHOD("launch", "path", "arguments", "capture"), &OwnedProcessGroup::launch);
		ClassDB::bind_method(D_METHOD("running", "pid"), &OwnedProcessGroup::running);
		ClassDB::bind_method(D_METHOD("poll", "pid"), &OwnedProcessGroup::poll);
		ClassDB::bind_method(D_METHOD("stop", "pid"), &OwnedProcessGroup::stop);
		ClassDB::bind_method(D_METHOD("stop_all"), &OwnedProcessGroup::stop_all);
	}

public:
	~OwnedProcessGroup() { stop_all(); }

	int64_t launch(const String &path, const PackedStringArray &arguments, bool capture) {
		if (!watcher && !start_watcher()) return -1;
		FileDescriptor output, writer;
		if (capture) {
			int pipe_fd[2];
			if (pipe(pipe_fd) < 0) return error("pipe");
			output.value = pipe_fd[0]; writer.value = pipe_fd[1];
			if (fcntl(output.value, F_SETFD, FD_CLOEXEC) < 0 || fcntl(writer.value, F_SETFD, FD_CLOEXEC) < 0 ||
					fcntl(output.value, F_SETFL, O_NONBLOCK) < 0) return error("fcntl");
		}

		std::vector<CharString> values;
		values.push_back(path.utf8());
		for (int i = 0; i < arguments.size(); ++i) values.push_back(arguments[i].utf8());
		std::vector<char *> argv;
		for (auto &value : values) argv.push_back(const_cast<char *>(value.get_data()));
		argv.push_back(nullptr);

		posix_spawnattr_t attributes;
		posix_spawnattr_init(&attributes);
		posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP);
		posix_spawnattr_setpgroup(&attributes, watcher);
		posix_spawn_file_actions_t actions;
		posix_spawn_file_actions_init(&actions);
		auto directory = path.get_base_dir().utf8();
		posix_spawn_file_actions_addchdir_np(&actions, directory.get_data());
		if (capture) {
			posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
			posix_spawn_file_actions_adddup2(&actions, writer.value, STDOUT_FILENO);
			posix_spawn_file_actions_adddup2(&actions, writer.value, STDERR_FILENO);
			posix_spawn_file_actions_addclose(&actions, output.value);
			posix_spawn_file_actions_addclose(&actions, writer.value);
		}
		pid_t pid;
		int code = posix_spawn(&pid, argv[0], &actions, &attributes, argv.data(), *_NSGetEnviron());
		posix_spawn_file_actions_destroy(&actions);
		posix_spawnattr_destroy(&attributes);
		if (code) return error("posix_spawn", code);
		children[pid] = {output.release()};
		return pid;
	}

	bool running(int64_t pid) {
		auto child = children.find(pid);
		if (child == children.end() || child->second.exited) return false;
		int status = 0;
		pid_t result = wait_child(pid, &status, WNOHANG);
		if (result == 0) return true;
		child->second.exited = true;
		child->second.code = result < 0 ? -1 : WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
		return false;
	}

	Array poll(int64_t pid) {
		Array result;
		PackedByteArray output;
		auto child = children.find(pid);
		if (child == children.end()) {
			result.append(false); result.append(-1); result.append(output); return result;
		}
		bool alive = running(pid);
		if (child->second.output >= 0) {
			char buffer[16384];
			while (true) {
				ssize_t count = read(child->second.output, buffer, sizeof(buffer));
				if (count < 0 && errno == EINTR) continue;
				if (count <= 0) break;
				int64_t offset = output.size();
				output.resize(offset + count);
				memcpy(output.ptrw() + offset, buffer, count);
			}
		}
		result.append(alive); result.append(child->second.code); result.append(output);
		if (!alive) forget(child);
		return result;
	}

	void stop(int64_t pid) {
		auto child = children.find(pid);
		if (child == children.end()) return;
		if (running(pid)) { kill(pid, SIGKILL); wait_child(pid, nullptr); }
		forget(child);
	}

	void stop_all() {
		if (lifetime >= 0) { close(lifetime); lifetime = -1; }
		if (watcher) { wait_child(watcher, nullptr); watcher = 0; }
		while (!children.empty()) {
			auto child = children.begin();
			if (!child->second.exited) wait_child(child->first, nullptr);
			forget(child);
		}
	}
};

static void initialize(ModuleInitializationLevel level) {
	if (level == MODULE_INITIALIZATION_LEVEL_SCENE) GDREGISTER_CLASS(OwnedProcessGroup);
}

extern "C" GDExtensionBool GDE_EXPORT process_group_init(GDExtensionInterfaceGetProcAddress get_proc_address,
		GDExtensionClassLibraryPtr library, GDExtensionInitialization *initialization) {
	GDExtensionBinding::InitObject init(get_proc_address, library, initialization);
	init.register_initializer(initialize);
	init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init.init();
}
