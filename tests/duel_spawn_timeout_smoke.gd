extends SceneTree

# 「1v1 worker 在**一个 claim 都没有**时会自己退出」—— 真拉起一个 worker,再读它自己的日志。
# 跑法: source tests/env.sh && timeout 150 "$GODOT" --headless --path . -s res://tests/duel_spawn_timeout_smoke.gd
# 通过 = `DUEL SPAWN TIMEOUT SMOKE: ALL-OK` 退出 0。
#
# ═══ 为什么需要它 ═══
# `server_main._process` 的报到梯原先只有三支:`_team_mode`(30s 退出)、
# `_royale` 且 ≥2 人(20s 降级开局)、`_royale` 且 <2 人(10s 退出)。
# **纯 1v1 一支都没有** ⇒ 大厅配对完、worker 已拉起,而两个客户端都没 `claim_role`
# (转连失败 / 都在 go_match 后立刻消失)时,worker **永驻**、端口白占到 2h 超龄兜底。
#
# ═══ 三条纪律(与 team_spawn_smoke 同款)═══
# ① 端口必须落在**真大厅的 worker 端口池之外**(池 = 7800 + 500)⇒ 固定用 29015。
# ② **跑前先删日志**:`--log-file` 沿用旧文件会让上一次的"报到超时"行让本跑**假绿**。
# ③ 判成败只看最末那行文本,不数 ERROR、也不看退出码。
#
# ★ **两条断言缺一不可**:`就绪` 证明 worker 本身是健康的(把"开机即崩"与"按梯退出"分开),
#   `报到超时` 才是本项要的行为。少了前者,一个开机就 quit(1) 的 worker 会让后者也失败,
#   而失败原因完全指错方向。
# ★ 30s 的来历(改这里要一起看):客户端侧内建兜底是 **12s 转连 / 25s claim** ⇒ worker
#   必须**晚于**它们退;`RECONNECT` 那套的超时也在这个量级。三处同源,别单独调一个。

const PORT := 29015                      # 池外(池 = 7800..8299)
const READY_MARK := "worker 就绪,等待两名玩家"
const TIMEOUT_MARK := "1v1 报到超时"
const READY_WAIT_MS := 40000             # 冷启动 headless worker + 建世界,给足
const LADDER_WAIT_MS := 60000            # 30s 梯 + 余量


func _initialize() -> void:
	# ★ 空载守卫:load 失败立刻 quit(1),否则后面抛错走不到 quit() → 进程**永久挂起**。
	var L: GDScript = load("res://server/worker_launcher.gd")
	if L == null:
		print("DUEL SPAWN TIMEOUT SMOKE: FAIL(读不到 worker_launcher.gd)")
		quit(1)
		return
	var launcher = L.new()
	var fails: Array[String] = []
	var log_path: String = launcher.log_path(PORT)

	if FileAccess.file_exists(log_path):
		DirAccess.remove_absolute(log_path)          # 纪律 ②
	if not launcher.spawn_worker(PORT):              # 1v1:无 --royale / --team / --ai-roles
		print("DUEL SPAWN TIMEOUT SMOKE: FAIL(1v1 worker 拉起失败)")
		quit(1)
		return

	var ready_text := _wait_for(log_path, READY_MARK, READY_WAIT_MS)
	if not ready_text.contains(READY_MARK):
		fails.append("worker 日志里没有「%s」(等了 %.1fs)—— worker 本身没起来,后面的梯无从谈起。日志尾部:%s"
				% [READY_MARK, READY_WAIT_MS / 1000.0, ready_text.right(400)])
	else:
		var t0 := Time.get_ticks_msec()
		var text := _wait_for(log_path, TIMEOUT_MARK, LADDER_WAIT_MS)
		if not text.contains(TIMEOUT_MARK):
			fails.append("★ 无人 claim 时 worker 没在报到梯上退出(等了 %.1fs;缺「%s」)。"
					% [LADDER_WAIT_MS / 1000.0, TIMEOUT_MARK]
					+ "日志尾部:%s" % text.right(400))
		else:
			print("  [info] 报到梯在就绪后 %.1fs 点火(期望 ≥30s:必须晚于客户端 12s 转连 / 25s claim)"
					% ((Time.get_ticks_msec() - t0) / 1000.0))

	launcher.kill_worker(PORT)
	_finish(fails)


# 轮询日志直到出现 `mark` 或超时;返回**最终**读到的全文(调用方自己判 contains)。
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
