extends Node

# 日志持久化管理器（Autoload 单例）。
# 客户端与服务端日志分别写入游戏目录的 log/ 路径下：
#   log/client.log        客户端运行日志
#   log/server.log        服务端运行日志
#   log/<角色>.old.log    上一轮的历史日志（单文件超过 MAX_BYTES 时自动轮转）
#
# 通过 OS.add_logger() 挂载自定义日志接收器，接管引擎的所有输出（print / push_warning / push_error），
# 支持统一的日志落盘路径、进程隔离与文件大小轮转控制。

const ROLE_CLIENT := "client"
const ROLE_SERVER := "server"
## 单份日志大小上限（字节）。超过阈值时轮转为 <角色>.old.log 并清理更早的历史文件。
const MAX_BYTES := 2 * 1024 * 1024

static var _sink: Logger = null
static var _file: FileAccess = null
static var _path := ""            # 当前写盘文件路径
static var _role := ROLE_CLIENT
static var _broken := false       # 写盘失败后停止重试
static var _installed := false


# 自定义日志接收器，实现 Engine 的 Logger 虚接口供 OS.add_logger 注册。
class Sink extends Logger:
	var on_line: Callable

	func _log_message(message: String, error: bool) -> void:
		on_line.call(message, error)

	func _log_error(function: String, file: String, line: int, code: String,
			rationale: String, editor_notify: bool, error_type: int,
			script_backtraces: Array) -> void:
		var text := rationale if not rationale.is_empty() else code
		on_line.call("%s: %s —— %s:%d" % [_type_name(error_type), text, file, line], true)
		for bt in script_backtraces:
			on_line.call(str(bt).strip_edges(), true)

	static func _type_name(error_type: int) -> String:
		match error_type:
			1: return "警告"
			2: return "脚本错误"
			3: return "着色器错误"
			_: return "错误"


func _ready() -> void:
	install()


func _exit_tree() -> void:
	close()


# ── 装配 ──

## 初始化并注册日志接收器（支持幂等调用）。
static func install() -> void:
	if _installed:
		return
	_installed = true
	_sink = Sink.new()
	_sink.on_line = _write
	OS.add_logger(_sink)
	# 专用服务端具有 dedicated_server 运行特性，据此区分输出到 server.log 还是 client.log
	use_role(ROLE_SERVER if OS.has_feature("dedicated_server") else ROLE_CLIENT)


## 切换当前进程日志角色（客户端或服务端）。
static func use_role(role: String) -> void:
	if role == _role and _file != null:
		return
	_role = role
	if _sink == null:
		return
	close()
	_open()


## 获取当前实际写入的日志文件绝对路径（为空表示未落盘）。
static func log_file() -> String:
	return _path


## 获取标准日志输出目录绝对路径。
static func log_dir() -> String:
	return AppPaths.log_dir()


static func close() -> void:
	if _file != null:
		_file.flush()
		_file.close()
		_file = null
	_path = ""


# ── 写盘 ──

static func _write(message: String, error: bool) -> void:
	if _broken or _file == null:
		return
	_file.store_line("[%s]%s %s" % [Time.get_time_string_from_system(),
			" ERROR" if error else "", message])
	# 立即冲刷写入缓冲区，确保异常崩溃时日志及时落盘
	_file.flush()


static func _session_header() -> void:
	var info := preload("res://core/config/build_info.gd")
	_write("===== 会话开始 %s | %s %s | pid=%d =====" % [
			Time.get_datetime_string_from_system(false, true), _role, info.display(),
			OS.get_process_id()], false)
	var args := OS.get_cmdline_args()
	if not args.is_empty():
		_write("命令行参数: %s" % " ".join(args), false)


static func _open() -> void:
	var dir := AppPaths.log_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("%s.log" % _role)
	_rotate(dir, path)
	if FileAccess.file_exists(path):
		_file = FileAccess.open(path, FileAccess.READ_WRITE)
	else:
		_file = FileAccess.open(path, FileAccess.WRITE)
	if _file == null:
		_fallback()
		return
	_file.seek_end()
	_path = path
	_session_header()


# 文件大小超限时将旧日志轮转重命名为 <角色>.old.log，覆盖更早的历史文件
static func _rotate(dir: String, path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var size := f.get_length()
	f.close()
	if size < MAX_BYTES:
		return
	var old := dir.path_join("%s.old.log" % _role)
	if FileAccess.file_exists(old):
		DirAccess.remove_absolute(old)
	DirAccess.rename_absolute(path, old)


# 默认目录不可写时（如无管理员写权限目录）回退写入 user://logs/
static func _fallback() -> void:
	_path = ""
	var u := "user://logs"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(u))
	var fb := u.path_join("%s.log" % _role)
	if FileAccess.file_exists(fb):
		_file = FileAccess.open(fb, FileAccess.READ_WRITE)
	else:
		_file = FileAccess.open(fb, FileAccess.WRITE)
	if _file == null:
		_broken = true
		push_warning("日志: %s 与 %s 都写不进去,本次不落盘" % [AppPaths.log_dir(), fb])
		return
	_file.seek_end()
	_path = ProjectSettings.globalize_path(fb)
	print("日志: %s 写不进去,改写到 %s" % [AppPaths.log_dir(), _path])
