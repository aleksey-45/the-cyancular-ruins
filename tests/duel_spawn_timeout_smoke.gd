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
		# ★ 删不掉就**别往下走**:残留的旧日志里两个标记都在,会让本冒烟在 1 秒内打出 ALL-OK
		#   而**什么都没观测**(僵尸 worker 占着日志文件的 Windows 共享冲突正是这种情形 ——
		#   被 timeout 掐掉的上一跑从不执行 kill_worker)。
		if FileAccess.file_exists(log_path):
			print("DUEL SPAWN TIMEOUT SMOKE: FAIL(删不掉旧日志 %s —— 有僵尸 worker 占着它;先清进程再跑)" % log_path)
			quit(1)
			return
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
			var elapsed := (Time.get_ticks_msec() - t0) / 1000.0
			print("  [info] 报到梯在就绪后 %.1fs 点火" % elapsed)
			# ★ 这是**判据**不是读数:它同时拦两种假绿 ——
			#   ① 旧日志残留(那种情况下观测到的耗时 ~0.3s);② 将来有人把 30.0 调小到
			#   客户端兜底(12s 转连 / 25s claim)之下,那会把"转连慢"变成"连不上"。
			#   ★ 取 25.0 而不是 30.0:观测粒度是 250ms 轮询,而门槛是严格的 `> 30.0`
			#   (就绪后实测 29.8s 属正常)。
			if elapsed < 25.0:
				fails.append("★ 报到梯点火太早(就绪后仅 %.1fs,应 >30s;>12s/>25s 是客户端兜底的余量)" % elapsed)

	# ── 源码级门控检查(见下方长注释:本冒烟结构上照不到大厅那一面)──
	# ★ 本冒烟起的是 **worker**,结构上永远进不了大厅模式 ⇒ 它**看不见**下面这条回归:
	#   把那一支的条件写成 **worker-only 标志的否定**(`not _royale and not _team_mode`)时,
	#   大厅进程里四个合取项**全成立** ⇒ `start_server.bat` 起的大厅会在 30 秒后 quit(0) 自杀
	#   (实测发生过)。⇒ 唯一能自动拦住它的是**源码级**检查:那一支必须以**正的** worker 标志开头。
	var src := FileAccess.get_file_as_string("res://server/server_main.gd")
	if src.is_empty():
		fails.append("读不到 server/server_main.gd —— 源码级门控检查无法进行")
	else:
		if not src.contains("var _worker := false"):
			fails.append("★ 缺 `_worker` 实例标志 —— 报到梯若以 worker-only 标志的**否定**为条件,大厅会自杀")
		elif src.contains("elif not _royale and not _team_mode"):
			fails.append("★ 报到梯又用回了 worker-only 标志的**否定** —— 大厅进程里它恒真,会在 30 秒后 quit(0)")
		elif not src.contains("elif _worker and not _match_started and _host == null:"):
			fails.append("★ 1v1 报到梯的条件不是 `elif _worker and not _match_started and _host == null`")

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
