#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#define _WIN32_WINNT 0x0A00
#include <windows.h>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <algorithm>
#include <cstring>
#include <map>
#include <string>
#include <vector>

using namespace godot;

struct Handle {
	HANDLE value = nullptr;
	~Handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
	HANDLE release() { HANDLE result = value; value = nullptr; return result; }
};

// CreateProcess receives one command line. Quote each argv item using Windows rules.
static std::wstring quote(const String &value) {
	auto chars = value.utf16();
	std::wstring result = L"\"";
	size_t slashes = 0;
	for (int i = 0; i < chars.length(); ++i) {
		wchar_t c = chars[i];
		if (c == L'\\') { ++slashes; continue; }
		result.append(c == L'"' ? slashes * 2 + 1 : slashes, L'\\');
		result += c;
		slashes = 0;
	}
	result.append(slashes * 2, L'\\');
	return result + L'"';
}

class OwnedProcessGroup : public RefCounted {
	GDCLASS(OwnedProcessGroup, RefCounted)
	struct Child { HANDLE process; HANDLE output; };
	HANDLE job = nullptr;
	std::map<int64_t, Child> children;

	void forget(std::map<int64_t, Child>::iterator child) {
		CloseHandle(child->second.process);
		if (child->second.output) CloseHandle(child->second.output);
		children.erase(child);
	}

	static int64_t error(const char *operation) {
		UtilityFunctions::push_error(operation, ": Windows error ", int64_t(GetLastError()));
		return -1;
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
		if (!job) {
			job = CreateJobObjectW(nullptr, nullptr);
			if (!job) return error("CreateJobObject");
			JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {};
			limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
			if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof(limits))) {
				error("SetInformationJobObject");
				CloseHandle(job); job = nullptr;
				return -1;
			}
		}

		Handle output, writer, input;
		HANDLE inherited[2] = {};
		STARTUPINFOEXW startup = {};
		startup.StartupInfo.cb = sizeof(startup);
		if (capture) {
			SECURITY_ATTRIBUTES security = {sizeof(security), nullptr, TRUE};
			if (!CreatePipe(&output.value, &writer.value, &security, 0)) return error("CreatePipe");
			if (!SetHandleInformation(output.value, HANDLE_FLAG_INHERIT, 0)) return error("SetHandleInformation");
			input.value = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
					&security, OPEN_EXISTING, 0, nullptr);
			if (input.value == INVALID_HANDLE_VALUE) return error("CreateFile NUL");
			inherited[0] = input.value; inherited[1] = writer.value;
			startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
			startup.StartupInfo.hStdInput = input.value;
			startup.StartupInfo.hStdOutput = writer.value;
			startup.StartupInfo.hStdError = writer.value;
		}

		SIZE_T size = 0;
		InitializeProcThreadAttributeList(nullptr, capture ? 2 : 1, 0, &size);
		std::vector<char> storage(size);
		startup.lpAttributeList = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(storage.data());
		if (!InitializeProcThreadAttributeList(startup.lpAttributeList, capture ? 2 : 1, 0, &size))
			return error("InitializeProcThreadAttributeList");
		// Assign the Job as part of creation; the child never runs outside its owner's Job.
		BOOL configured = UpdateProcThreadAttribute(startup.lpAttributeList, 0,
				PROC_THREAD_ATTRIBUTE_JOB_LIST, &job, sizeof(job), nullptr, nullptr);
		if (configured && capture)
			configured = UpdateProcThreadAttribute(startup.lpAttributeList, 0,
					PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherited, sizeof(inherited), nullptr, nullptr);
		if (!configured) {
			error("UpdateProcThreadAttribute");
			DeleteProcThreadAttributeList(startup.lpAttributeList);
			return -1;
		}

		std::wstring command = quote(path);
		for (int i = 0; i < arguments.size(); ++i) command += L" " + quote(arguments[i]);
		auto exe = path.utf16();
		auto directory = path.get_base_dir().utf16();
		PROCESS_INFORMATION process = {};
		BOOL created = CreateProcessW(reinterpret_cast<const wchar_t *>(exe.get_data()), command.data(),
				nullptr, nullptr, capture, CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT,
				nullptr, reinterpret_cast<const wchar_t *>(directory.get_data()), &startup.StartupInfo, &process);
		if (!created) error("CreateProcess");
		DeleteProcThreadAttributeList(startup.lpAttributeList);
		if (!created) return -1;
		CloseHandle(process.hThread);
		children[process.dwProcessId] = {process.hProcess, output.release()};
		return process.dwProcessId;
	}

	bool running(int64_t pid) const {
		auto child = children.find(pid);
		return child != children.end() && WaitForSingleObject(child->second.process, 0) == WAIT_TIMEOUT;
	}

	Array poll(int64_t pid) {
		Array result;
		PackedByteArray output;
		auto child = children.find(pid);
		if (child == children.end()) {
			result.append(false); result.append(-1); result.append(output);
			return result;
		}
		bool alive = running(pid);
		if (child->second.output) {
			DWORD available = 0, count = 0;
			char buffer[16384];
			while (PeekNamedPipe(child->second.output, nullptr, 0, nullptr, &available, nullptr) && available) {
				if (!ReadFile(child->second.output, buffer, std::min<DWORD>(available, sizeof(buffer)), &count, nullptr)) break;
				int64_t offset = output.size();
				output.resize(offset + count);
				memcpy(output.ptrw() + offset, buffer, count);
			}
		}
		DWORD code = STILL_ACTIVE;
		GetExitCodeProcess(child->second.process, &code);
		result.append(alive); result.append(int64_t(code)); result.append(output);
		if (!alive) forget(child);
		return result;
	}

	void stop(int64_t pid) {
		auto child = children.find(pid);
		if (child == children.end()) return;
		if (running(pid)) TerminateProcess(child->second.process, 1);
		WaitForSingleObject(child->second.process, 5000);
		forget(child);
	}

	void stop_all() {
		if (job) { CloseHandle(job); job = nullptr; }
		while (!children.empty()) {
			auto child = children.begin();
			WaitForSingleObject(child->second.process, 5000);
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
