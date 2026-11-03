class_name NetDiag
extends RefCounted

# 结构化诊断日志(三模式共用;默认关)。两种开启方式:

const DIR_NAME := "user://logs"
# 心跳指标默认采样间隔(ms);`--diag-verbose` 下回到 1s。★ 传 1Hz 会把 10 分钟的局写成 ~200KB,这正是旧 diag 文件难读的原因。
const METRIC_INTERVAL_MS := 10000

static var _checked := false
static var _enabled := false
static var _role := ""
static var _path := ""
static var _file: FileAccess = null
static var _mutex := Mutex.new()
static var _count := 0
static var _open_failed := false

# ── 心跳指标(与事件分开落盘)──
static var _metrics_path := ""
static var _metrics_file: FileAccess = null
static var _metrics_failed := false
static var _metrics_count := 0
static var _metrics_last: Dictionary = {}   # event -> 上次写盘 t(ms);同名事件按 METRIC_INTERVAL_MS 节流
static var _verbose_checked := false
static var _verbose := false

static var _ops_checked := false
static var _ops_skipped := false
static var _ops_failed := false
static var _ops_warned := false
static var _ops_path := ""
static var _ops_file: FileAccess = null


## 是否开启(懒查一次;`--diag` 必须在 `--` 之后,或环境变量 `CYR_DIAG=1`)。
## ★ 2026-10-30 追加:**导出构建里的服务端默认开** —— 打包后的服务端必须永远有日志可查(运营/排障前提),
##   所以不再要求服主记得加 `--diag`。开发态 / 客户端仍默认关(测试与正常对局行为逐字不变)。
static func enabled() -> bool:
	if not _checked:
		_checked = true
		_enabled = OS.get_cmdline_user_args().has("--diag") or OS.get_environment("CYR_DIAG") == "1"
		if not _enabled and role() == "server" and OS.has_feature("template"):
			_enabled = true
	return _enabled


## 本进程角色(server / client),写进每一行便于多进程日志并排读。
## ★ 导出标记:服务端导出用 `serverui`(项目主场景覆盖),worker 命令行带 `--worker`;两者都算服务端。
static func role() -> String:
	if _role.is_empty():
		var ua := OS.get_cmdline_user_args()
		_role = "server" if (OS.has_feature("dedicated_server") or OS.has_feature("serverui")
				or ua.has("--worker") or ua.has("--server")) else "client"
	return _role


static func set_role(r: String) -> void:
	_role = r


## 日志落盘目录(2026-10-30)。**打包后的服务端** = exe 同目录的 `log/`(导出即生效,不需要任何开关);
## 其余(开发态 / 编辑器 / 客户端) = `user://logs`。选择逻辑收在 NetMetrics.server_log_dir(纯函数,`-s` 可测)——
## 别在这里另写一份判据:口径漂了就等于"打包后日志又回 user://",而现场没人找得到它。
## ★ 2026-10-31:`CYR_LOG_DIR` 环境变量可整体覆盖(真链路批按 entry 分目录、子进程继承环境);
##   生产不设它 ⇒ 行为逐字不变。
static func log_dir() -> String:
	var override := OS.get_environment("CYR_LOG_DIR")
	if not override.is_empty():
		return override
	return NetMetrics.server_log_dir(
			role() == "server",
			OS.has_feature("template"),
			OS.get_executable_path().get_base_dir(),
			ProjectSettings.globalize_path(DIR_NAME))


## 是否开「心跳逐秒」(默认 10s 一条):`--diag-verbose` 或 `CYR_DIAG_VERBOSE=1`。
static func verbose() -> bool:
	if not _verbose_checked:
		_verbose_checked = true
		_verbose = OS.get_cmdline_user_args().has("--diag-verbose") or OS.get_environment("CYR_DIAG_VERBOSE") == "1"
	return _verbose


static func metric_interval_ms() -> int:
	return 1000 if verbose() else METRIC_INTERVAL_MS


## 该不该写这条心跳?纯函数(冒烟可测):`last_ms < 0` = 本进程第一次 ⇒ 写;否则要满一个间隔。
static func metric_due(last_ms: int, now_ms: int, interval_ms: int) -> bool:
	if last_ms < 0:
		return true
	return now_ms - last_ms >= maxi(interval_ms, 1)


const OPS_KEEP := 60
const OPS_WARN_BYTES := 8 * 1024 * 1024


static func should_audit(role_name: String) -> bool:
	return role_name != "client"


static func ops_file_name(role_name: String, pid: int, stamp: String) -> String:
	return "ops-%s-%d-%s.jsonl" % [role_name, pid, stamp]


static func ops_files_to_keep(names: PackedStringArray, keep: int) -> PackedStringArray:
	var ops: Array[String] = []
	for n in names:
		if n.begins_with("ops-") and n.ends_with(".jsonl"):
			ops.append(n)
	ops.sort_custom(func(a: String, b: String) -> bool:
		return a.substr(a.rfind("-") + 1) > b.substr(b.rfind("-") + 1))
	var out := PackedStringArray()
	for i in mini(keep, ops.size()):
		out.append(ops[i])
	return out


## 写一条事件。`data` 只放标量/数组/字典(向量请拆成 [x, y]);`urgent=true` 立即落盘(错误/断线这类必须活到崩溃之后的)。
static func log_event(event: String, data: Dictionary = {}, urgent := false) -> void:
	if not enabled():
		return
	_ensure_open()
	if _file == null:
		return
	var line := JSON.stringify({
		"t": Time.get_ticks_msec(),
		"pid": OS.get_process_id(),
		"role": role(),
		"event": event,
		"data": data,
	})
	_mutex.lock()
	_file.store_line(line)
	_count += 1
	# ★ 服务端每行都刷:worker 可能被强杀/崩溃,缓冲区里的"最后几条"恰恰是最值钱的现场。
	#   服务端事件率低(1Hz 采样 + 少量事件),每行 flush 的代价可以忽略;客户端保留原语义(只在 urgent 刷)。
	if urgent or role() == "server":
		_file.flush()
	_mutex.unlock()


## 当前日志文件绝对路径(未开启/未落盘为空)。
static func file_path() -> String:
	return _path


## 已写条数(诊断/探针用)。
static func count() -> int:
	return _count


## 写一条**心跳指标**(queue / snapshot_tx / snap_rx 这类周期读数)。
## ★ 与 log_event 分文件 + 按 METRIC_INTERVAL_MS 节流(默认 10s;`--diag-verbose` 1s):
##   旧实现每秒每角色一行 ⇒ 7 分钟就 200KB、长局 700KB,真正稀有的 rollback/snap_gap 被埋在中间。
static func log_metric(event: String, data: Dictionary = {}) -> void:
	if not enabled():
		return
	var now := Time.get_ticks_msec()
	var last := int(_metrics_last.get(event, -1))
	if not metric_due(last, now, metric_interval_ms()):
		return
	_metrics_last[event] = now
	_ensure_metrics_open()
	if _metrics_file == null:
		return
	var line := JSON.stringify({
		"t": now,
		"pid": OS.get_process_id(),
		"role": role(),
		"event": event,
		"data": data,
	})
	_mutex.lock()
	_metrics_file.store_line(line)
	_metrics_count += 1
	if role() == "server":
		_metrics_file.flush()
	_mutex.unlock()


## 心跳指标文件绝对路径(未开启/未落盘为空)。
static func metrics_path() -> String:
	return _metrics_path


static func _ensure_metrics_open() -> void:
	if _metrics_file != null or _metrics_failed:
		return
	_mutex.lock()
	if _metrics_file == null and not _metrics_failed:
		var dir := log_dir()
		DirAccess.make_dir_recursive_absolute(dir)
		var stamp := Time.get_datetime_string_from_system().replace(":", "").replace("-", "").replace(" ", "_")
		var path := dir.path_join("metrics-%s-%d-%s.jsonl" % [role(), OS.get_process_id(), stamp])
		_metrics_file = FileAccess.open(path, FileAccess.WRITE)
		if _metrics_file == null:
			_metrics_failed = true
			push_warning("NetDiag: 无法创建 %s(指标不落盘)" % path)
		else:
			_metrics_path = path
			_metrics_file.store_line(JSON.stringify({
				"t": Time.get_ticks_msec(), "pid": OS.get_process_id(), "role": role(),
				"event": "metrics_start", "data": {"log": path, "interval_ms": metric_interval_ms()},
			}))
	_mutex.unlock()


static func flush() -> void:
	_mutex.lock()
	if _file != null:
		_file.flush()
	if _metrics_file != null:
		_metrics_file.flush()
	_mutex.unlock()


static func close() -> void:
	_mutex.lock()
	if _file != null:
		_file.flush()
		_file.close()
		_file = null
	if _metrics_file != null:
		_metrics_file.flush()
		_metrics_file.close()
		_metrics_file = null
	_mutex.unlock()


static func _ensure_open() -> void:
	if _file != null or _open_failed:
		return
	_mutex.lock()
	if _file == null and not _open_failed:
		var dir := log_dir()
		DirAccess.make_dir_recursive_absolute(dir)
		var stamp := Time.get_datetime_string_from_system().replace(":", "").replace("-", "").replace(" ", "_")
		var path := dir.path_join("diag-%s-%d-%s.jsonl" % [role(), OS.get_process_id(), stamp])
		_file = FileAccess.open(path, FileAccess.WRITE)
		if _file == null:
			_open_failed = true
			push_warning("NetDiag: 无法创建 %s(本次不落盘)" % path)
		else:
			_path = path
			_file.store_line(JSON.stringify({
				"t": Time.get_ticks_msec(),
				"pid": OS.get_process_id(),
				"role": role(),
				"event": "session_start",
				"data": {
					"build": preload("res://core/config/build_info.gd").display(),
					"version": ProjectSettings.get_setting("application/config/version"),
					"engine": Engine.get_version_info()["string"],
					"os": OS.get_name(),
					"log": path,
				},
			}))
	_mutex.unlock()


static func audit(event: String, data: Dictionary = {}) -> void:
	if _ops_skipped or _ops_failed:
		return
	if not _ops_checked:
		_ops_checked = true
		_ops_skipped = not should_audit(role())
		if _ops_skipped:
			return
	_ensure_audit_open()
	if _ops_file == null:
		return
	var line := JSON.stringify({
		"t": Time.get_ticks_msec(),
		"pid": OS.get_process_id(),
		"role": role(),
		"event": event,
		"data": data,
	})
	_mutex.lock()
	_ops_file.store_line(line)
	_ops_file.flush()
	if not _ops_warned and _ops_file.get_length() > OPS_WARN_BYTES:
		_ops_warned = true
		push_warning("NetDiag: 审计文件超过 %d 字节(%s)" % [OPS_WARN_BYTES, _ops_path])
	_mutex.unlock()


static func _ensure_audit_open() -> void:
	if _ops_file != null or _ops_failed or _ops_skipped or not _ops_checked:
		return
	_mutex.lock()
	if _ops_file == null and not _ops_failed:
		var dir := log_dir()
		DirAccess.make_dir_recursive_absolute(dir)
		_prune_ops(dir)
		var stamp := Time.get_datetime_string_from_system().replace(":", "").replace("-", "").replace(" ", "_")
		var path := dir.path_join(ops_file_name(role(), OS.get_process_id(), stamp))
		_ops_file = FileAccess.open(path, FileAccess.WRITE)
		if _ops_file == null:
			_ops_failed = true
			push_warning("NetDiag: 无法创建 %s(审计不落盘)" % path)
		else:
			_ops_path = path
			_ops_file.store_line(JSON.stringify({
				"t": Time.get_ticks_msec(), "pid": OS.get_process_id(), "role": role(),
				"event": "session_start", "data": {"log": path},
			}))
	_mutex.unlock()


static func _prune_ops(dir_path: String) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	var names := PackedStringArray()
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if not d.current_is_dir():
			names.append(f)
		f = d.get_next()
	d.list_dir_end()
	var keep := ops_files_to_keep(names, OPS_KEEP)
	for n in names:
		if n.begins_with("ops-") and n.ends_with(".jsonl") and not keep.has(n):
			DirAccess.remove_absolute(dir_path.path_join(n))


static func tail_lines(path: String, n: int) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var all := FileAccess.get_file_as_string(path).split("\n")
	var out: Array[String] = []
	for i in range(all.size() - 1, -1, -1):
		var s := str(all[i]).strip_edges()
		if not s.is_empty():
			out.push_front(s)
			if out.size() >= n:
				break
	return " ↵ ".join(out)


# ── 测试专用(生产路径不会调)──────────────────────────────────────────────
# ★ 存在的理由:`--diag` 是**命令行开关**,而 `-s` 冒烟的 `OS.get_cmdline_user_args()` 里只有测试自己的参数
# (`-s res://...`),没法在不改产品判定分支的前提下打开它。测试用这两个函数直接注入路径/开关。
static func begin_for_test(path: String) -> void:
	_checked = true
	_enabled = true
	_open_failed = false
	_path = path
	var dir := path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	_file = FileAccess.open(path, FileAccess.WRITE)
	_file.store_line(JSON.stringify({
		"t": Time.get_ticks_msec(), "pid": OS.get_process_id(), "role": role(),
		"event": "session_start", "data": {"test": true},
	}))


static func end_for_test() -> void:
	close()
	_checked = true
	_enabled = false
	_path = ""
	_count = 0
	_open_failed = false
	_metrics_path = ""
	_metrics_failed = false
	_metrics_count = 0
	_metrics_last.clear()


static func begin_metrics_for_test(path: String) -> void:
	_metrics_failed = false
	_metrics_path = path
	_metrics_count = 0
	_metrics_last.clear()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	_metrics_file = FileAccess.open(path, FileAccess.WRITE)
	if _metrics_file == null:
		_metrics_failed = true
		return
	_metrics_file.store_line(JSON.stringify({
		"t": Time.get_ticks_msec(), "pid": OS.get_process_id(), "role": role(),
		"event": "metrics_start", "data": {"test": true},
	}))


static func metrics_count() -> int:
	return _metrics_count


static func end_metrics_for_test() -> void:
	if _metrics_file != null:
		_metrics_file.flush()
		_metrics_file.close()
	_metrics_file = null
	_metrics_path = ""
	_metrics_failed = false
	_metrics_count = 0
	_metrics_last.clear()


