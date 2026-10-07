extends SceneTree

# 3v3 Worker 启动参数传递与解析验证：
# 实际拉起一个 3v3 Worker 实例，验证大厅拼接的命令行参数能被服务端解析逻辑正确识别并应用。
# 运行方式：
#   timeout 90 "$GODOT" --headless --path . -s res://tests/smoke/team_spawn_smoke.gd

const PORT := 29014                     # 池外/空闲段
const ROLES := [1, 2, 3, 4, 5, 6]
const TEAMS := [1, 1, 1, 2, 2, 2]
# 3v3 模式就绪日志输出标记
const READY_MARK := "3v3 worker 就绪"
# 预期解析出的角色集合与队伍分配日志字符串
const WANT_ROLES := "[1, 2, 3, 4, 5, 6]"
# 队伍映射预期格式（花括号内侧带空格）
const WANT_TEAMS := "队伍 { 1: 1, 2: 1, 3: 1, 4: 2, 5: 2, 6: 2 }"
const MAX_WAIT_MS := 30000              # 启动超时阈值


func _initialize() -> void:
	# 加载守卫：加载失败立即退出
	var S: GDScript = load("res://server/match_session.gd")
	if S == null:
		print("TEAM SPAWN SMOKE: FAIL(读不到 match_session.gd —— 共用判据的宿主)")
		quit(1)
		return
	var fails: Array[String] = []
	var log_path: String = _log_path(PORT)

	# ── 参数校验负例（纯逻辑断言，不创建进程）──
	# 验证 MatchSession.validate 对队伍长度不匹配与队号越界的防御性校验。
	print("  [info] 下面这几条负例是**预期**的拒绝(不会启动任何进程)")
	if str(S.validate(S.Mode.TEAM, [1, 2, 3], {1: 1, 2: 1})).is_empty():
		fails.append("长度不等(roles 3 vs teams 2)应当拒绝")
	if str(S.validate(S.Mode.TEAM, ROLES, {1: 1, 2: 1, 3: 3, 4: 2, 5: 2, 6: 2})).is_empty():
		fails.append("★ 队号越界(3)应当拒绝 —— 解析端只收 1..2 且**静默丢弃**,"
				+ "放行会让那一局带着错的队表开局而大厅以为成功")
	if not str(S.validate(S.Mode.TEAM, ROLES, {1: 1, 2: 1, 3: 1, 4: 2, 5: 2, 6: 2})).is_empty():
		fails.append("正形 roles/teams 应当放行(恒拒绝的判据和没有判据一样坏)")

	# ── 正例：启动实际进程并验证输出 ──
	if FileAccess.file_exists(log_path):
		DirAccess.remove_absolute(log_path)
	var pid := _spawn(PORT, log_path)
	if pid <= 0:
		fails.append("正形 roles/teams 应当拉起成功(create_process 返回 <= 0)")
		_finish(fails)
		return

	var text := ""
	var waited := 0
	while waited < MAX_WAIT_MS:
		OS.delay_msec(250)
		waited += 250
		text = _read(log_path)
		if text.contains(READY_MARK):
			break
	print("  [info] 等待就绪用了 %.1fs(日志 %s)" % [waited / 1000.0, log_path])

	# 验证 3v3 模式正常就绪，角色集合与队伍分配解析正确。
	if not text.contains(READY_MARK):
		fails.append("日志里没有「%s」(等了 %.1fs;日志尾部:%s)"
				% [READY_MARK, waited / 1000.0, text.right(400)])
	else:
		if not text.contains(WANT_ROLES):
			fails.append("--roles 没被解析成 role 集合(缺「%s」)" % WANT_ROLES)
		if not text.contains(WANT_TEAMS):
			fails.append("--teams 没被解析成队伍表 / 与 --roles 的配对错了(缺「%s」)" % WANT_TEAMS)

	if OS.is_process_running(pid):
		OS.kill(pid)
	_finish(fails)


# 组装启动参数并拉起子进程。自定义参数置于 `--` 分隔符之后。
func _spawn(port: int, log_path: String) -> int:
	var args := PackedStringArray(["--headless", "--log-file", log_path])
	if OS.has_feature("editor") or OS.has_feature("template_debug"):
		args.append_array(PackedStringArray(["--path", ProjectSettings.globalize_path("res://"),
				"res://server/server_main.tscn"]))
	args.append_array(PackedStringArray(["--", "--worker", "--team", "--port", str(port),
			"--roles", ",".join(ROLES.map(func(r): return str(int(r)))),
			"--teams", ",".join(TEAMS.map(func(t): return str(int(t))))]))
	return OS.create_process(OS.get_executable_path(), args)


func _log_path(port: int) -> String:
	var dir := ProjectSettings.globalize_path("user://logs")
	DirAccess.make_dir_recursive_absolute(dir)
	return dir.path_join("team_spawn_%d.log" % port)


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
		print("TEAM SPAWN SMOKE: ALL-OK")
		quit(0)
	else:
		print("TEAM SPAWN SMOKE: FAIL")
		for f in fails:
			print("  - %s" % f)
		quit(1)
