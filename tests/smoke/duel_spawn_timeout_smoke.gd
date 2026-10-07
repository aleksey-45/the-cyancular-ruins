extends SceneTree

# 1v1 对局 Worker 超时退出冒烟测试：
# 实际拉起一个 1v1 Worker 子进程，验证在无任何客户端报道认领（claim）时，
# Worker 能够按预设超时时间（30s）正常退出并释放端口与系统资源。
# 运行方式：
#   source tests/env.sh && timeout 150 "$GODOT" --headless --path . -s res://tests/smoke/duel_spawn_timeout_smoke.gd

# 动态申请空闲 UDP 端口，避免硬编码端口冲突导致的测试失败。
const READY_MARK := "worker 就绪,等待两名玩家"
const TIMEOUT_MARK := "1v1 报到超时"
const READY_WAIT_MS := 40000             # 冷启动 headless 服务端 + 建世界超时上限
const LADDER_WAIT_MS := 60000            # 30s 阶梯等待余量

# 代码特征锚点：断言大厅分支不挂载 MatchSession 节点
const ROOM_ANCHOR := "RoomManager.new()"
const MATCH_MOUNT := "MatchSession.new("


func _initialize() -> void:
	# 加载防御性校验：加载失败立即退出，避免进程挂起
	var S: GDScript = load("res://server/match_session.gd")
	if S == null:
		print("DUEL SPAWN TIMEOUT SMOKE: FAIL(读不到 match_session.gd)")
		quit(1)
		return
	var fails: Array[String] = []
	var port := _free_port()
	if port <= 0:
		print("DUEL SPAWN TIMEOUT SMOKE: FAIL(要不到空闲 UDP 口——先清残留进程再跑)")
		quit(1)
		return
	var log_path := _log_path(port)

	if FileAccess.file_exists(log_path):
		DirAccess.remove_absolute(log_path)
		# 确保旧日志已清理，防止读取历史残留产生假阳性结果
		if FileAccess.file_exists(log_path):
			print("DUEL SPAWN TIMEOUT SMOKE: FAIL(删不掉旧日志 %s —— 先清残留进程再跑)" % log_path)
			quit(1)
			return
	var pid := _spawn(port, log_path)               # 1v1:无 --royale / --team / --ai-roles
	if pid <= 0:
		print("DUEL SPAWN TIMEOUT SMOKE: FAIL(单局服务端拉起失败)")
		quit(1)
		return

	var ready_text := _wait_for(log_path, READY_MARK, READY_WAIT_MS)
	if not ready_text.contains(READY_MARK):
		fails.append("日志里没有「%s」(等了 %.1fs)—— 那一局本身没起来,后面的梯无从谈起。日志尾部:%s"
				% [READY_MARK, READY_WAIT_MS / 1000.0, ready_text.right(400)])
	else:
		var t0 := Time.get_ticks_msec()
		var text := _wait_for(log_path, TIMEOUT_MARK, LADDER_WAIT_MS)
		if not text.contains(TIMEOUT_MARK):
			fails.append("★ 无人 claim 时那一局没在报到梯上收场(等了 %.1fs;缺「%s」)。"
					% [LADDER_WAIT_MS / 1000.0, TIMEOUT_MARK]
					+ "日志尾部:%s" % text.right(400))
		else:
			var elapsed := (Time.get_ticks_msec() - t0) / 1000.0
			print("  [info] 报到梯在就绪后 %.1fs 点火" % elapsed)
			# 耗时校验：点火时间必须大于 25s（避开客户端 25s 的 claim 保底阈值，且排除日志残留假象）
			if elapsed <= 25.0:
				fails.append("★ 报到梯点火太早(就绪后仅 %.1fs,应 >30s;≤25s 已不晚于客户端的 25s claim 兜底)" % elapsed)

	# ── 源码静态门控检查 ──
	# 1. 验证 1v1 超时门控必须包含正向实例标志 _worker，且不得直接否定 worker 标志；
	# 2. 验证大厅主分支与对局会话初始化互斥，大厅流程不加载 MatchSession 实例；
	# 3. 验证 MatchSession 退出逻辑不调用 quit()，统一经由 _finish() 结束对局。
	var SU: GDScript = load("res://tests/lib/scan_util.gd")
	if SU == null:
		fails.append("读不到 tests/lib/scan_util.gd —— 源码级门控检查无法进行")
	else:
		var src: String = SU.read("res://server/match_session.gd")
		if src.is_empty():
			fails.append("读不到 server/match_session.gd —— 源码级门控检查无法进行(导出包里是二进制 token,本冒烟只在编辑器二进制下有效)")
		else:
			var code: String = SU.code_only(src)
			var body: String = SU.func_body(SU.code_view(src), "_process")
			if body.is_empty():
				fails.append("★ 取不到 `MatchSession._process` 的函数体 —— 源码级门控检查无法进行")
			else:
				var gate := _ladder_gate(body, TIMEOUT_MARK)
				if gate.is_empty():
					fails.append("★ `_process` 里找不到 1v1 报到梯(判据是它打的那句 `%s`)" % TIMEOUT_MARK)
				else:
					_check_gate(gate, code, fails)
			# 单进程架构下结束对局不能调用 quit()，必须通过 _finish() 清理对局节点
			if body.contains("get_tree().quit("):
				fails.append("★ `MatchSession._process` 里出现 get_tree().quit( —— 单进程下收场必须走 `_finish()`")
		# 验证大厅分支不挂载对局节点
		_check_lobby_has_no_match(SU, fails)

	if OS.is_process_running(pid):
		OS.kill(pid)
	_finish(fails)


# ────────────────────────── 源码级判定条件 ──────────────────────────

# 静态断言：1v1 超时门控中必须包含托管标记 `_worker`
func _check_gate(gate: String, code: String, fails: Array[String]) -> void:
	var flag := _negated_worker_flag(gate)
	if flag != "":
		fails.append("它**否定**了 worker 标志 `%s` —— 未托管对局的节点里该标志恒 false、取反恒真（梯子会被误触发）" % flag)
		return
	if not (code.contains("var _worker := false") or code.contains("var _worker: bool = false")):
		fails.append("门控用了 `_worker`,但文件里没有 `var _worker := false` 声明")
		return
	# 验证 _worker 存在赋值为 true 的逻辑，保证超时门控能够生效
	if not code.contains("_worker = true"):
		fails.append("`_worker` 从未被置 true —— 报到梯永远不会点火(那一局永驻、占着会话与列表位)")


# 静态断言：大厅初始化流程中不得直接挂载 MatchSession，两分支通过 return 互斥隔离
func _check_lobby_has_no_match(SU, fails: Array[String]) -> void:
	var view: String = SU.code_view(SU.read("res://server/server_main.gd"))
	var ready_body: String = SU.func_body(view, "_ready")
	if ready_body.is_empty():
		fails.append("★ 取不到 `server_main._ready` 的函数体 —— 无法判大厅分支有没有挂对局")
		return
	var at_match := ready_body.find(MATCH_MOUNT)
	var at_room := ready_body.find(ROOM_ANCHOR)
	if at_match < 0:
		fails.append("★ `_ready` 里根本没有 `%s` —— 单局独立服务端那条路没了" % MATCH_MOUNT)
		return
	if at_room < 0:
		fails.append("★ `_ready` 里找不到 `%s` —— 无法切出大厅分支(判据会退化成恒真)" % ROOM_ANCHOR)
		return
	if at_match > at_room:
		fails.append("★ 对局挂载点排在 `%s` **之后** —— 大厅进程可能也托管一局(梯子、`_claims`、快照全乱)" % ROOM_ANCHOR)
		return
	if not ready_body.substr(at_match, at_room - at_match).contains("return"):
		fails.append("★ 对局挂载点与大厅挂载点之间没有 `return` —— 两者不是互斥分支(大厅会先挂一局再挂大厅)")


# 校验门控表达式是否否定了 worker 标志
func _negated_worker_flag(gate: String) -> String:
	for raw in ["_worker", "_royale", "_team_mode"]:
		var flag := str(raw)
		var re := RegEx.new()
		if re.compile("\\bnot\\s*\\(*\\s*%s\\b" % flag) != OK:
			continue
		if re.search(gate) != null:
			return flag
	return ""


# 从 _process 的函数体中提取 1v1 超时门控的完整条件表达式
func _ladder_gate(body: String, mark: String) -> String:
	var lines := body.split("\n")
	var at := -1
	for i in range(lines.size()):
		if lines[i].contains(mark):
			at = i
			break
	if at < 0:
		return ""
	var gate_at := -1
	var floor_indent := _indent_of(lines[at])
	for i in range(at - 1, -1, -1):
		var s: String = lines[i]
		if s.strip_edges().begins_with("func "):
			break
		var ci := _indent_of(s)
		if ci >= floor_indent:
			continue
		var stripped := s.strip_edges()
		if stripped.begins_with("if ") or stripped.begins_with("elif "):
			gate_at = i
		else:
			continue
		floor_indent = ci
	if gate_at < 0:
		return ""
	var first: String = lines[gate_at].strip_edges()
	var cond := first.substr(3 if first.begins_with("if ") else 5)
	var k := gate_at
	while not cond.strip_edges().ends_with(":"):
		k += 1
		if k >= lines.size():
			break
		cond += " " + lines[k].strip_edges()
	cond = cond.strip_edges()
	if cond.ends_with(":"):
		cond = cond.substr(0, cond.length() - 1)
	cond = cond.strip_edges()
	if cond.ends_with("\\"):
		cond = cond.substr(0, cond.length() - 1)
	return _squeeze_ws(cond)


func _squeeze_ws(s: String) -> String:
	var re := RegEx.new()
	if re.compile("\\s+") != OK:
		return s.strip_edges()
	return re.sub(s, " ", true).strip_edges()


func _indent_of(line: String) -> int:
	var n := 0
	while n < line.length() and (line[n] == "\t" or line[n] == " "):
		n += 1
	return n


# 轮询日志直到包含目标标记或超时，返回读取到的日志内容
func _wait_for(path: String, mark: String, max_ms: int) -> String:
	var text := ""
	var waited := 0
	while waited < max_ms:
		OS.delay_msec(250)
		waited += 250
		text = _read(path)
		if text.contains(mark):
			break
	return text


# 组装启动参数并拉起子进程。自定义参数置于 `--` 分隔符之后
func _spawn(port: int, log_path: String) -> int:
	var args := PackedStringArray(["--headless", "--log-file", log_path])
	if OS.has_feature("editor") or OS.has_feature("template_debug"):
		args.append_array(PackedStringArray(["--path", ProjectSettings.globalize_path("res://"),
				"res://server/server_main.tscn"]))
	args.append_array(PackedStringArray(["--", "--worker", "--port", str(port)]))
	return OS.create_process(OS.get_executable_path(), args)


func _log_path(port: int) -> String:
	var dir := ProjectSettings.globalize_path("user://logs")
	DirAccess.make_dir_recursive_absolute(dir)
	return dir.path_join("duel_spawn_%d.log" % port)


# 动态申请系统当前空闲的临时 UDP 端口，避免端口冲突
func _free_port() -> int:
	var p := UDPServer.new()
	if p.listen(0, "127.0.0.1") != OK:
		return 0
	var got := p.get_local_port()
	p.stop()
	return got


func _read(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var s := f.get_as_text()
	f.close()
	return s


func _finish(fails: Array[String]) -> void:
	if fails.is_empty():
		print("DUEL SPAWN TIMEOUT SMOKE: ALL-OK")
		quit(0)
	else:
		print("DUEL SPAWN TIMEOUT SMOKE: FAIL")
		for f in fails:
			print("  - %s" % f)
		quit(1)
