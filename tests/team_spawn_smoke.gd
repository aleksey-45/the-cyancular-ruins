extends SceneTree

# 「生成端拼出来的 3v3 worker 命令行**真的被解析端认下**」—— 真拉起一个 worker,再读它自己的日志。
# 跑法: timeout 90 "$GODOT" --headless --path . -s res://tests/team_spawn_smoke.gd
# 通过 = `TEAM SPAWN SMOKE: ALL-OK` 退出 0。
#
# ═══ 为什么需要它 ═══
# ★ `tests/room_sweep_smoke.gd` 的双向断言只能证明"两个文件里都有 `--team` / `--teams` 这两个
#   字符串",证明不了「`WorkerLauncher.spawn_team_worker` 拼出来的那条命令行真的被
#   `server_main._ready` 的 argv 解析认下、并按 **3v3 形态**就绪」。两处各自改对了、拼起来却错
#   (开关顺序 / 逗号串格式 / 值域)时,那一对断言**照样全绿** —— 而表象是"对局永不开始,
#   大厅侧一行报错都没有"(worker 的 ERROR 只写在它自己的 `worker_<port>.log` 里,没人读)。
# ★ 本脚本原是一次性的 scratch(`.superpowers/sdd/_t9_spawn_check.gd`,那里被 `.superpowers/`
#   的 gitignore 挡在仓外),提升进仓是因为**它是这条链路唯一的证明**,且用户需要能复跑。
#
# ═══ 三条纪律 ═══
# ① 端口必须落在**真大厅的 worker 端口池之外**(池 = `WORKER_PORT_BASE 7800` + `SPAN 500`)
#    —— 池内端口会与真大厅拉起的 worker 撞车。本脚本固定用池外的 29014。
# ② **跑前先删日志**:`--log-file` 若沿用旧文件,上一次留下的"3v3 worker 就绪"会让本跑**假绿**
#    (断言读的是文件内容,不是本次进程的输出)。
# ③ 负例那两行 `ERROR: …` 是**预期**的(`spawn_team_worker` 的两条守卫各 `push_error` 一次)。
#    判成败只看最末那行文本,不数 ERROR、也不看退出码。
#
# ★ 兜底:即使收尾的按端口杀失败,worker 自己也会在 30s 的"报到超时梯"上 quit(0) 释放端口
#   (3v3 没有降级开局,收不齐 6 人就退)—— 所以本脚本不会留下永久僵尸。

const PORT := 29014                     # 池外(池 = 7800..8299)
const ROLES := [1, 2, 3, 4, 5, 6]
const TEAMS := [1, 1, 1, 2, 2, 2]
# ★ 判据串与 `server_main._run_worker` 的 `_team_mode` 分支**逐字对应**:那行改了这里要跟着改,
#   不跟着改就**红**(这是有意的 —— 它正是"解析端认下了 `--team` 并按 3v3 形态就绪"的唯一证据)。
const READY_MARK := "3v3 worker 就绪"
# `str(_role_set)` / `str(_team_of_role)` 的**实际打印形态**(去读日志时逐字比对)。
# ★ 这两条是刻意贴住日志格式的:格式一变就红,而"变了却没人注意"正是本脚本要防的事
#   (role 集合与队伍表**同序配对**是 3v3 最容易被改坏的一处)。
const WANT_ROLES := "[1, 2, 3, 4, 5, 6]"
# ★ 注意 Godot 4.7 的 `str(Dictionary)` 是 `{ k: v }`(**花括号内侧各一个空格**)——
#   实测踩到:写成 `{1: 1, …}` 时这条断言恒红(而"红"的样子与"配对错了"一模一样)。
const WANT_TEAMS := "队伍 { 1: 1, 2: 1, 3: 1, 4: 2, 5: 2, 6: 2 }"
const MAX_WAIT_MS := 30000              # 冷启动 headless worker + 建世界,给足


func _initialize() -> void:
	# ★ 空载守卫:load 失败立刻 quit(1),否则后面抛错走不到 quit() → 进程**永久挂起**
	#   (不是干净失败,是超时)。
	var L: GDScript = load("res://server/worker_launcher.gd")
	if L == null:
		print("TEAM SPAWN SMOKE: FAIL(读不到 worker_launcher.gd)")
		quit(1)
		return
	var launcher = L.new()
	var fails: Array[String] = []
	var log_path: String = launcher.log_path(PORT)

	# ── 负例(纯逻辑,不产生子进程)──
	# ★ 这两条守的是 `spawn_team_worker` 的两条 `push_error` 守卫,而 B 册大厅要从**房间数据**
	#   拼 teams —— 最容易踩的就是"长度不等"与"队号越界"。放行的后果不是崩溃而是**静默**:
	#   子进程开机即 quit(1),而本函数返回 `pid > 0`、大厅据此判定"拉起成功"。
	print("  [info] 下面两行 ERROR 是**预期**的(spawn_team_worker 的两条守卫各 push_error 一次)")
	if launcher.spawn_team_worker(PORT, [1, 2, 3], [1, 1]):
		fails.append("长度不等(roles 3 vs teams 2)应当拒绝拉起")
	if launcher.spawn_team_worker(PORT, ROLES, [1, 1, 3, 2, 2, 2]):
		fails.append("★ 队号越界(3)应当拒绝拉起 —— 解析端只收 1..2 且**静默丢弃**,"
				+ "放行会让子进程开机即 quit(1) 而大厅以为成功")

	# ── 正例:真拉起(见文件头纪律 ②:先删日志)──
	if FileAccess.file_exists(log_path):
		DirAccess.remove_absolute(log_path)
	if not launcher.spawn_team_worker(PORT, ROLES, TEAMS):
		fails.append("正形 roles/teams 应当拉起成功")
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
	print("  [info] 等待 worker 就绪用了 %.1fs(日志 %s)" % [waited / 1000.0, log_path])

	# ★ 三条断言各管一件事,缺一条都留一个洞:
	#   ① 按 3v3 形态就绪(证明 `--team` 被认下 —— 1v1 形态会打"worker 就绪,等待两名玩家")
	#   ② `--roles` 被解析成 role 集合   ③ `--teams` 被解析成队伍表(且与 roles 同序配对)
	if not text.contains(READY_MARK):
		fails.append("worker 日志里没有「%s」(等了 %.1fs;日志尾部:%s)"
				% [READY_MARK, waited / 1000.0, text.right(400)])
	else:
		if not text.contains(WANT_ROLES):
			fails.append("--roles 没被解析成 role 集合(缺「%s」)" % WANT_ROLES)
		if not text.contains(WANT_TEAMS):
			fails.append("--teams 没被解析成队伍表 / 与 --roles 的配对错了(缺「%s」)" % WANT_TEAMS)

	launcher.kill_worker(PORT)
	_finish(fails)


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
