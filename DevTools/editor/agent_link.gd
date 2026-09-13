class_name AgentLink
extends RefCounted

## Agent 施工传输层:把提示词交给施工方执行,拿回日志与完成状态。
## 抽象目的:换 API 不动编辑器 —— 实现 Transport 接口(如 ClaudeCliTransport)即可替换,
## 未来可加 HttpApiTransport(直接调 API,自行管理会话/工具权限)。

signal log_line(text: String)
signal finished(ok: bool, done_marker: bool, summary: String)

const EXIT_MARK := "__AGENT_EXIT_"
const POLL_SEC := 0.2
const START_TIMEOUT_MS := 10000

var is_busy := false
var _timer: Timer = null
var _tag := ""
var _prompt_path := ""
var _log_path := ""
var _log_sent := 0
var _start_ms := 0
var _pid := 0
var _transport = null   # Transport 实例


## Transport 接口(任何实现都要满足):
##   name() -> String
##   start(prompt_abs: String, log_abs: String) -> int   # 返回 pid(0=失败),日志写 log_abs
##   stop(pid: int) -> void
class ClaudeCliTransport:
	# 本机 Claude Code CLI(claude -p,非交互):读 stdin 提示词,输出落日志。
	# bat 机制沿用已验证的做法:零中文/仓库根由 %~dp0 推导/心跳行/退出标记落日志。
	# model 非空 → 追加 --model(本机 ~/.claude 的主模型配置可能指向端点上不存在的模型,
	# 实测 400「模型不存在」→ 显式钉住可用模型是唯一可靠解,也是"可换 API"的一部分)。
	const PROMPT_DIR := "res://DevTools/editor/.prompts"
	const LOG_DIR := "res://DevTools/editor/.logs"
	var model := ""

	func name() -> String:
		return "Claude Code CLI(本机)"

	## bat 内容纯函数(可测):tag = 提示词文件名主干(ASCII)。
	## 纯拼接,不用 % 格式化:bat 里的 cmd 百分号与 GDScript 格式符互相踩(实际踩坑:
	## %s 未替换进 bat → LOGF=%s.log 被 cmd 解析成 s.log,claude 读空文件秒退)。
	static func build_cli_bat(tag: String, flags: String = "-p --permission-mode acceptEdits --output-format text --verbose") -> String:
		var L: Array[String] = [
			"@echo off",
			"setlocal enabledelayedexpansion",
			"rem repo root derived from this bat's own dir: keeps this file ASCII-only",
			"set \"REPO=%~dp0..\\..\\..\"",
			"for %%i in (\"%REPO%\") do set \"REPO=%%~fi\"",
			"cd /d \"%REPO%\"",
			"set \"PROMPT=%REPO%\\DevTools\\editor\\.prompts\\" + tag + ".md\"",
			"set \"LOGF=%REPO%\\DevTools\\editor\\.logs\\" + tag + ".log\"",
			"> \"%LOGF%\" echo __AGENT_STARTED__",
			"claude " + flags + " < \"%PROMPT%\" >> \"%LOGF%\" 2>&1",
			">> \"%LOGF%\" echo " + EXIT_MARK + "!ERRORLEVEL!__",
		]
		return "\r\n".join(L) + "\r\n"

	func start(prompt_abs: String, log_abs: String) -> int:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(PROMPT_DIR))
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(LOG_DIR))
		var tag := prompt_abs.get_file().trim_suffix(".md")
		var bat_abs := ProjectSettings.globalize_path("%s/%s.bat" % [LOG_DIR, tag])
		var f := FileAccess.open(bat_abs, FileAccess.WRITE)
		if f == null:
			return 0
		var flags := "-p --permission-mode acceptEdits --output-format text --verbose"
		if model.strip_edges() != "":
			flags += " --model " + model.strip_edges()
		f.store_string(build_cli_bat(tag, flags))   # 纯 ASCII bat:仓库根从 bat 自身位置向上三级推导
		f.close()
		return OS.create_process("cmd.exe", PackedStringArray(["/c", bat_abs]))

	func stop(pid: int) -> void:
		OS.create_process("cmd.exe", PackedStringArray(["/c", "taskkill /T /F /PID %d" % pid]))


## 发起施工。返回 tag(空=未发起,原因走 log_line)。model:显式钉住模型(可空=跟随本机配置)。
func run(card_type: String, card_id: String, prompt: String, transport = null, model: String = "") -> String:
	if is_busy:
		log_line.emit("[拒绝] 已有 agent 在跑")
		return ""
	_transport = transport if transport != null else ClaudeCliTransport.new()
	if transport == null and model.strip_edges() != "":
		(_transport as Object).set("model", model.strip_edges())
	_tag = "%s_%s_rev%d_%s" % [card_type, card_id, int(card_id.hash() % 1000), _stamp()]
	_tag = "%s_%s_%s" % [card_type, card_id, _stamp()]
	_prompt_path = "%s/%s.md" % [AgentLink.ClaudeCliTransport.PROMPT_DIR, _tag]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(
			AgentLink.ClaudeCliTransport.PROMPT_DIR))   # 先建目录再写文件(否则 .prompts 不存在,写入必败)
	var pf := FileAccess.open(ProjectSettings.globalize_path(_prompt_path), FileAccess.WRITE)
	if pf == null:
		log_line.emit("[失败] 提示词写不进去:%s" % _prompt_path)
		return ""
	pf.store_string(prompt)
	pf.close()
	_log_path = "%s/%s.log" % [AgentLink.ClaudeCliTransport.LOG_DIR, _tag]
	_log_sent = 0
	_start_ms = Time.get_ticks_msec()
	is_busy = true
	log_line.emit("[传输] %s" % (_transport as Object).call("name"))
	_pid = int((_transport as Object).call("start",
			ProjectSettings.globalize_path(_prompt_path), ProjectSettings.globalize_path(_log_path)))
	if _pid <= 0:
		is_busy = false
		log_line.emit("[失败] 传输层没能创建进程——用「复制提示词」手动执行")
		return ""
	log_line.emit("[发起] tag=%s pid=%d" % [_tag, _pid])
	log_line.emit("[提示词] %s(可手动查看/粘贴)" % ProjectSettings.globalize_path(_prompt_path))
	_timer = Timer.new()
	_timer.wait_time = POLL_SEC
	_timer.timeout.connect(_poll)
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		_timer.autostart = true
		tree.root.add_child.call_deferred(_timer)
	return _tag


func stop() -> void:
	if not is_busy or _pid <= 0:
		return
	log_line.emit("[停止] pid=%d" % _pid)
	(_transport as Object).call("stop", _pid)
	is_busy = false
	log_line.emit("[停止] 已复位")


func _poll() -> void:
	if not is_busy:
		return
	if _log_sent == 0 and Time.get_ticks_msec() - _start_ms > START_TIMEOUT_MS \
			and not FileAccess.file_exists(ProjectSettings.globalize_path(_log_path)):
		_finish(false, false, "传输层 10 秒未产生日志——进程没有执行,请用「复制提示词」手动跑")
		return
	var text := FileAccess.get_file_as_string(ProjectSettings.globalize_path(_log_path))
	if text.length() > _log_sent:
		var chunk := text.substr(_log_sent)
		_log_sent = text.length()
		for ln in chunk.split("\n"):
			log_line.emit(ln)
	var idx := text.rfind(EXIT_MARK)
	if idx >= 0:
		var rest := text.substr(idx + EXIT_MARK.length())
		var end := rest.find("__")
		var code := (rest.substr(0, end) if end >= 0 else rest).strip_edges()
		_finish(code == "0", text.contains("CARD-DONE"), "退出码 %s" % code)


func _finish(ok: bool, done: bool, summary: String) -> void:
	is_busy = false
	if _timer != null and is_instance_valid(_timer):
		_timer.queue_free()
		_timer = null
	log_line.emit("[完成] ok=%s CARD-DONE=%s(%s)" % [ok, done, summary])
	finished.emit(ok, done, summary)


func _stamp() -> String:
	return Time.get_time_string_from_system().replace(":", "")
