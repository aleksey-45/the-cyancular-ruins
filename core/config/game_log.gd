extends Node

# 日志落盘(autoload)。客户端与服务端各写一份,放在**游戏目录**的 `log/` 下:
#
#   log/client.log        客户端(玩家双击的那个 exe)
#   log/server.log        服务端
#   log/<角色>.old.log    上一轮的(单份超过 MAX_BYTES 时轮转,只留一份旧档)
#
# EasyTier 内核自己的日志同在这个目录下(`log/easytier-host-<pid>/`、`log/easytier-guest-<pid>/`,
# 由 `core/net/tunnel.gd` 传给内核,见那里的 `_append_file_logging`);内核是独立进程、
# 日志名固定,所以按角色分目录,同机跑两条隧道时两边不会互相覆盖。目录名尾部带启动者的
# 游戏进程 pid —— 同机多局各写各的目录,也是孤儿清扫(`Tunnel._reap_orphans`)认领所有权的标记。
#
# ── 为什么不用 Godot 自带的文件日志 ──
# 它的落点由 project.godot 的 `debug/file_logging/log_path` 在**引擎启动时**定,而那个设置:
#   - 只认 `user://` 与绝对路径 —— 写相对路径会让引擎**启动就崩**(signal 11;2026-10-02 实测
#     `log/client.log` 与 `D:/.../log/client.log` 两种写法,前者崩、后者正常);
#   - `res://` 在发布版里是只读的(资源打包进 PCK),写不进去;
#   - 于是它只剩 `%APPDATA%\Godot\app_userdata\...` 一个落点,而且**客户端与服务端同名**
#     (两个进程会互相覆盖同一份 `godot.log`),玩家要看日志还得先离开游戏目录去找。
# 所以 project.godot 里把自带的那份关掉(`debug/file_logging/enable_file_logging=false`),
# 改用 `OS.add_logger()` 接住引擎的全部输出(print / push_warning / push_error / 脚本报错),
# 落点、命名、轮转都由本文件说了算。
#
# - 探针那套 `--log-file <路径>`(引擎自己认的开关)与本记录器**并存**:那个开关在引擎启动时
#   就被吸收清除了,`OS.get_cmdline_args()` 里看不到它(2026-10-02 实测:带与不带,脚本读到的参数
#   一模一样),所以本文件无法据此让路。开发态跑探针时两边各写一份,内容一致、互不影响。
#   发布版不走 `--log-file`,只有本记录器这一份。

const ROLE_CLIENT := "client"
const ROLE_SERVER := "server"
## 单份日志的上限。超了就轮转成 `<角色>.old.log`(旧的 `.old` 直接删)。
const MAX_BYTES := 2 * 1024 * 1024

static var _sink: Logger = null
static var _file: FileAccess = null
static var _path := ""            # 当前写盘的文件(展示、排错用)
static var _role := ROLE_CLIENT
static var _broken := false       # 写盘失败后停手,免得每条日志再失败一次
static var _installed := false


# `Logger` 是引擎给的接日志的口子(`OS.add_logger`);它有两个虚方法,引擎把每条消息交给它们。
# - 参数表是**引擎定的**,少一个参数这个方法就静默不生效(warning 只在编辑器里看得见),
#   改动前先对着 `Logger` 的类文档核一遍(4.7.1 的签名见下)。
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

## 装上记录器并把落点定下来。**幂等**。
static func install() -> void:
	if _installed:
		return
	_installed = true
	_sink = Sink.new()
	_sink.on_line = _write
	OS.add_logger(_sink)
	# 服务端是同一个工程的第二个导出预设(export_presets 的 `dedicated_server=true`),
	# 它在运行时带 `dedicated_server` 特性 —— 拿它分角色,客户端与服务端才不会抢同一个文件。
	# - 开发态跑 `res://server/server_main.tscn` 时没有这个特性,那时由 `server_main.gd`
	#   显式调 `use_role("server")` 补上。
	use_role(ROLE_SERVER if OS.has_feature("dedicated_server") else ROLE_CLIENT)


## 换写哪个角色的日志(同一条命令里只会换一次:服务端在开发态自报家门)。
static func use_role(role: String) -> void:
	if role == _role and _file != null:
		return
	_role = role
	if _sink == null:
		return                      # 还没装(或本进程带 --log-file):只记住角色
	close()
	_open()


## 当前日志文件的绝对路径("" = 没在写盘)。界面与崩溃排查都用它。
static func log_file() -> String:
	return _path


## 日志目录(绝对路径)。即使本次没写盘也返回应有的位置,供提示文案用。
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
	# - 每条都 flush:日志是给"进程没能正常退出"那种场面用的,攒在缓冲里等于没写。
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


# 超上限就把当前这份挪成 `<角色>.old.log`(旧的旧档直接删)。
# - 判据用**上一轮留下的文件大小**,不是"本进程写了多少":本进程写到一半就崩的话,
#   下一次启动正好按这一份的大小决定要不要留档。
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


# 游戏目录写不进去(比如装在 Program Files 下)时的退路:仍按角色分开写进 `user://logs/`。
# - 必须把输出目标路径 —— "日志到底在哪"是排错的第一句话,不能靠人猜。
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
