class_name AgentRunner
extends Node

# Claude Code CLI 进程管理(DevTools):把提示词喂给本机 claude -p 非交互执行。
# 只懂「进程与日志」;提示词在 prompt_builder.gd,UI 在 card_editor.gd。
#
# 机制:
#  - 提示词写 .prompts/<tag>.md;.bat 启动器写 .logs/<tag>.bat,经文件 stdin 重定向喂入
#    (绕开 Windows 引号/长度地狱;bat 内 setlocal enabledelayedexpansion 拿真实退出码)
#  - 尾部 echo __CLAUDE_EXIT_<n>__ 落进日志(pipe 拿不到子进程退出码)
#  - Timer 0.2s 轮询日志文件,增量推给 LogPanel;并发锁:同一时刻只允许一个 agent
#  - 停止 = taskkill /T /F(cmd 壳连同 claude 子进程;OS.kill 只杀得到壳)

signal log_line(text: String)
signal finished(ok: bool, card_done: bool, summary: String)

const PROMPT_DIR := "res://DevTools/cards/.prompts"
const LOG_DIR := "res://DevTools/cards/.logs"
const EXIT_MARK := "__CLAUDE_EXIT_"
const POLL_SEC := 0.2
const SOFT_TIMEOUT_MIN := 30   # 软超时:仅日志提醒,不自动杀

var is_busy := false
var _pid := 0
var _log_path := ""
var _log_sent_bytes := 0
var _tag := ""
var _start_ms := 0
var _timeout_warned := false


## CLI 可用性预探测(阻塞,秒回)。失败 → 编辑器提示走「复制提示词」兜底
static func cli_available() -> Dictionary:
	var output: Array = []
	OS.execute("cmd.exe", ["/c", "claude --version"], output, true)
	var text := str(output[0] if not output.is_empty() else "").strip_edges()
	var ok := text.contains("Claude Code") or text.begins_with("2.")
	return {"ok": ok, "version": text}


## 发起施工。permission_mode 默认 acceptEdits(全自动 bypassPermissions 由 UI 勾选显式传入)。
## 返回 tag(空 = 未发起,原因走 log_line)
func run(card: Dictionary, prompt: String, extra_flags: String, permission_mode: String = "acceptEdits") -> String:
	if is_busy:
		log_line.emit("[拒绝] 已有 agent 在跑(同一时刻只允许一个)")
		return ""
	var probe := cli_available()
	if not bool(probe["ok"]):
		log_line.emit("[预探测失败] 找不到可用 claude CLI(%s)——用「复制提示词」手动粘贴执行" % probe["version"])
		return ""
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(PROMPT_DIR))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(LOG_DIR))
	var t := Time.get_time_string_from_system().replace(":", "")
	_tag = "%s_%s_rev%d_%s" % [str(card.get("card_type", "card")), str(card.get("id", "x")), int(card.get("rev", 1)), t]
	var prompt_path := "%s/%s.md" % [PROMPT_DIR, _tag]
	var pf := FileAccess.open(prompt_path, FileAccess.WRITE)
	if pf == null:
		log_line.emit("[失败] 提示词文件写不进去:%s" % prompt_path)
		return ""
	pf.store_string(prompt)
	pf.close()
	# bat 启动器(全绝对路径、正斜杠;内容字面量,不经命令行转义)
	_log_path = "%s/%s.log" % [LOG_DIR, _tag]
	var repo := ProjectSettings.globalize_path("res://")
	var bat_path := "%s/%s.bat" % [LOG_DIR, _tag]
	var bf := FileAccess.open(bat_path, FileAccess.WRITE)
	if bf == null:
		log_line.emit("[失败] 启动器写不进去:%s" % bat_path)
		return ""
	bf.store_string(PromptBuilder.build_cli_bat(repo,
			ProjectSettings.globalize_path(prompt_path),
			ProjectSettings.globalize_path(_log_path),
			extra_flags, permission_mode))
	bf.close()
	_log_sent_bytes = 0
	is_busy = true
	_start_ms = Time.get_ticks_msec()
	_timeout_warned = false
	var pipe := OS.execute_with_pipe("cmd.exe", ["/c", ProjectSettings.globalize_path(bat_path)], false)
	_pid = int(pipe.get("pid", 0)) if typeof(pipe) == TYPE_DICTIONARY else 0
	log_line.emit("[发起] tag=%s pid=%d" % [_tag, _pid])
	log_line.emit("[提示词] %s(可直接查看/手动粘贴执行)" % ProjectSettings.globalize_path(prompt_path))
	var timer := Timer.new()
	timer.wait_time = POLL_SEC
	timer.timeout.connect(_poll)
	add_child(timer)
	timer.start()
	return _tag


func stop() -> void:
	if not is_busy or _pid <= 0:
		return
	log_line.emit("[停止] taskkill /T /F /PID %d" % _pid)
	OS.create_process("cmd.exe", ["/c", "taskkill /T /F /PID %d" % _pid])


func _poll() -> void:
	if not is_busy:
		return
	# 增量读日志推给面板
	var text := FileAccess.get_file_as_string(_log_path)
	if text.length() > _log_sent_bytes:
		var chunk := text.substr(_log_sent_bytes)
		_log_sent_bytes = text.length()
		for ln in chunk.split("\n"):
			log_line.emit(ln)
	# 退出标记 → 收尾
	var idx := text.rfind(EXIT_MARK)
	if idx >= 0:
		var rest := text.substr(idx + EXIT_MARK.length())
		var end := rest.find("__")
		var code := (rest.substr(0, end) if end >= 0 else rest).strip_edges()
		_finish(code == "0", text.contains("CARD-DONE"), "退出码 %s" % code)
		return
	# 软超时提醒
	if not _timeout_warned and Time.get_ticks_msec() - _start_ms > SOFT_TIMEOUT_MIN * 60 * 1000:
		_timeout_warned = true
		log_line.emit("[提醒] 已运行超 %d 分钟(软超时不自动杀;确认没卡死可点「停止」)" % SOFT_TIMEOUT_MIN)


func _finish(ok: bool, card_done: bool, summary: String) -> void:
	is_busy = false
	_pid = 0
	for child in get_children():
		if child is Timer:
			child.queue_free()
	log_line.emit("[结束] %s" % summary)
	finished.emit(ok, card_done, summary)
