extends Node

# 3v3 团队模式的**六人真实网络链路端到端探针**。场景模式(autoload 必须已实例化)。
#
# 跑法(用户侧):
#   timeout 1800 bash tests/probe/team_match_probe.sh
# 或直接:
#   "$GODOT" --headless --path . --quit-after 54000 res://tests/probe/team_match_probe.tscn
# 判据:**文本 `TEAM MATCH PROBE: ALL-OK`**(不看退出码 —— 探针挂住时 `--quit-after` 到期仍
# exit 0 且一行 ALL-OK 都不打印,只看退出码会把"没跑完"读成"通过")。
#
# ═══ 五相(brief = `.superpowers/sdd/b-task-8-brief.md`;每相的存在理由见对应注释)═══
#   阶段 1 六人开局 —— 实际大厅(池外端口)+ 6 个 headless 客户端各跑**真 mp_lobby 页**:
#        建房 → 点公开列表加入 → **各自选边(3 A / 3 B)** → 房主点开始 → 6 端都进 `team_game`。
#        断言:6 端都进对局;每端的 `match_sync.teams` 与大厅的 `team_of` **逐端一致**;
#        每端本地玩家与权威快照收敛(阶段 1 的 C2 面)。
#        - 阶段 1 同时覆盖"从没被实际运行过"的 ①:等待室渲染路径(`team_room_state` 真正到达并被
#          画出来 —— 每端都登记了 `room_states>0` 与名单行数)。
#   阶段 2 按队散点 —— 开局那一刻 6 个出生点两两分组:**队内最大距离 < 队间最小距离**
#        (与 A 册 `team_host_probe` 的同一条判据,这里在真实网络链路上再验一次)。
#   阶段 3 子弹穿透队友(负)+ 爆炸满效(正)——
#        甲(1 队最低 role)走到队友乙身边(≤170px 且视线通畅)连射:乙 hp **不变**;
#        再换榴弹贴脸一投:乙 hp **下降**且被推飞。
#        - 这一对**缺一不可**:只验"穿透"会让"伤害系统整个坏了"也测试全部通过。
#        - 另外从**乙端**独立取证:数"从我身边飞过(≤45px)的**非自己**子弹"——没有它,
#          "乙 hp 不变"可以靠"子弹根本没飞到"骗过(墙挡住的测试漏检)。
#   阶段 4 **打到 9 杀**(回合机收局)→ ROUND_OVER → 第 2 局开局后各端出生点已对调(用**生产函数**
#        `TeamHost.compute_swap_spawns` 算期望,再与实测比对)。-  9 杀是**脚本机器人尽力交火 +
#        回退模式(K 自杀脱困)**共同的结果:实测机器人在平台跳跃图上接近不了对手,9 杀多半由
#        回退模式推动(逐端读数 `REC BACKOFF`,裁判照实打印输出)—— 故这一相验的是**回合机 +
#        整队换边 + 换边重拉 match_sync**(那三样与"谁杀的"无关),而不是"枪法"。
#        断言各端 `scores` 的键是队号 1/2、`rounds_won` 六端一致。
#   阶段 5 少人继续 —— 6 号客户端在 PLAYING 中途**按 ESC 离场**(唯一走 `safe_change_scene`
#        的局内退出路径)→ 服务器**不**终局、其余 5 端仍持续收到快照(间隔 < 1s)、且掉线者
#        已被移出对局(见 watcher 文件头对 brief 那句"排行榜标离开"的照实偏离)。
#
# ═══ 拓扑(自当大厅/裁判;全部子进程由本进程 `OS.create_process` 直接启动)═══
#   本进程 = 实际大厅(`NetBus.start_server(LOBBY_PORT)` + `RoomManager`),**不占 7777**
#   c1..c6 = 6 个 headless 客户端,各自跑真 `mp_lobby` → 真 `team_game`
#   worker = 由**真** `RoomManager.team_start` 经 `WorkerLauncher.spawn_team_worker` 启动
#            (与生产逐字同一条路径,探针只是把它的起投端口拨到池外,见下方常量)
#   - 端口纪律(与 reconnect_probe 同源):大厅与 worker **都落在实际大厅的 worker 端口池
#     (7800~8299)之外、且不占 7777** —— 本机常驻一个实际大厅时,池内端口可能被它发给别人
#     的对局,而本探针收尾会按端口终止 worker 进程,会把别人那一局一起终止。
#
# ═══ 前提 ═══
#   **请确认没有别的 Godot 占着 7777**(本探针不占 7777,但别终止用户自己的服务端)。
#   客户端子进程的 stdout 父进程看不到(Windows `CreateProcess` 不继承句柄)→ 每个子进程
#   都带 `--log-file`;失败时本探针把**每个客户端的引擎日志尾部**一起打印出来。
#   收尾**按 PID 杀**本进程启动过的**全部**子进程(客户端是从临时端口连出去的,只按端口杀
#   根本杀不到;对局侧没有第二个进程可杀 —— 它就是本进程,见 `_kill_children`)。
#
# ═══ 时间预算 ═══
#   阶段 1~③ 约 40~90s;阶段 4 打到 9 杀是**脚本机器人尽力交火 + 回退模式**的结果,是本探针最大的时间
#   不确定项(上限 `BRAWL_MAX`=210s);阶段 5 的观察窗要等满 60s 宽限期(上限 `OBSERVE_MAX`=110s)。
#   整跑量级 3~10 分钟;安全网 `--quit-after 54000`(60fps 下 = 900s;`run/max_fps=60`);
#   本进程自己的收工上限 `FINAL_TIMEOUT`=780s(> 等结果预算 `RESULT_WAIT`=680s;
#   - `RESULT_WAIT` 一旦超过 780 就必须同步抬 `FINAL_TIMEOUT`,否则收工上限会先于预算到点)。

const RESULT_PREFIX := "team_match_probe_"
# 端口分配规范：大厅与对局共用同一端口，使用独立的 29200 端口，避开默认 7777 端口与常见服务端口。
const LOBBY_PORT := 29200
const CLIENT_COUNT := 6
const CHILD_QUIT_AFTER := "54000"  # 子进程保底处理(60fps ≈ 900s);正常由本进程收尾/按 PID 杀
const BOOT_TIMEOUT := 45.0         # 等"6 人进房并选边完毕"的上限
const FINAL_TIMEOUT := 780.0       # 本进程的收工上限(整跑量级 4~10 分钟;预算见下)
# 等 6 份客户端结果文件的上限。-  必须**大于**客户端自己的时间线(它们的相位全靠自己的时钟推),
#   且**逐项按 watcher 的常量求和算出来** —— 别凭印象写:这行漂过两次,一次把 `RENDEZVOUS_MAX`
#   记成了 70(实际是 **100**),一次停在宽限期还是 30s 时的那份求和(2026-09-21 宽限期 30 → 60,
#   `OBSERVE_MAX` 60 → 110,整条求和随之 +50)。越时的表象是"只收到 N/6 份客户端结果",
#   读起来像产品故障,其实是**探针自己的预算算错了**。逐项(各项都是 watcher 的常量):
#     进局 ~5s + SETTLE 1.2 + RENDEZVOUS_MAX 100 + BRAWL_MAX 210 + 换局 SETTLE 1.2
#     + OBSERVE_MAX 110 + PEER_WAIT 120 ≈ 547.4s;
#     进局那一档的硬上限是 `ENTER_TIMEOUT` **90s**(不是 5s),最坏 ≈ 632.4s  ->  取 680 提供容错保障两种走法。
#   - 680 < `FINAL_TIMEOUT` 780(收工上限仍在预算之上);**一旦本值超过 780 就必须同步抬
#     `FINAL_TIMEOUT`**,否则收工上限先到点  ->  症状同样是"只收到 N/6 份结果"。
const RESULT_WAIT := 680.0

var _role := "lobby"
var _who := "c1"
var _idx := 1
var _t := 0.0
var _stage := 0
var _rm: Node = null
var _code := ""
var _match_id := 0
var _ready_seen := false
var _start_t := -1.0
var _child_pids: Array[int] = []
var _hb := 30.0
var _lobby_teams: Dictionary = {}   # 选边完毕那一刻大厅的队伍表(房在开局后被消费掉,不能再读)
var _failures: Array[String] = []
var _notes: Array[String] = []
var _dims_failed := false           # 地图尺寸读不到的 FAIL 只记一次(见 _grid_dims)
var _done := false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			_role = a.trim_prefix("--role=")
		elif a.begins_with("--who="):
			_who = a.trim_prefix("--who=")
		elif a.begins_with("--lobby-port="):
			pass   # 端口是常量(池外);argv 里带着只为人工单起客户端时清楚
	_idx = int(_who.trim_prefix("c")) if _who.begins_with("c") else 1
	if _role == "lobby":
		_run_orchestrator()
	else:
		_run_client()


# ════════════════════ 裁判(大厅)════════════════════

func _run_orchestrator() -> void:
	var err := NetBus.start_server(LOBBY_PORT)
	if err != OK:
		print("PROBE: 大厅监听失败 err=%d(端口 %d 被占?本探针**不占 7777**,该端口是本探针自己的)"
				% [err, LOBBY_PORT])
		get_tree().quit(1)
		return
	_rm = RoomManager.new()
	add_child(_rm)
	# 单进程单端口架构下，对局作为当前进程内的 MatchSession 子节点运行，无需启动外部 worker 子进程。
	# 测试结束时直接按记录的 PID 清理客户端子进程。
	# 检查前序测试产生的临时文件清理状态，若清理失败（前序进程未退出）则终止测试，防止状态污染。
	if not _clean():
		print("PROBE: 清理失败(多半是上一跑的进程还活着)—— 不拉起客户端,直接退出")
		get_tree().quit(1)
		return
	print("PROBE: 大厅就绪(port %d,池外;对局与它**同进程同端口**)" % LOBBY_PORT)
	if OS.get_cmdline_user_args().has("--nospawn"):
		print("PROBE: --nospawn:不拉客户端子进程,请人工另起 6 个 `-- --role=cN`")
		print("PROBE: ★ 此模式**不会**判 ALL-OK —— 跨端断言一条都跑不到(见 _finish 的闸门),收尾必记一条 FAIL")
		return
	for i in range(1, CLIENT_COUNT + 1):
		_spawn_client(i)


func _spawn_client(i: int) -> void:
	var argv := PackedStringArray(["--headless", "--path",
			ProjectSettings.globalize_path("res://"), "--quit-after", CHILD_QUIT_AFTER,
			"--log-file", _godot_log_path("c%d" % i),
			"res://tests/probe/team_match_probe.tscn", "--", "--role=c%d" % i, "--who=c%d" % i,
			"--lobby-port=%d" % LOBBY_PORT])
	var pid := OS.create_process(OS.get_executable_path(), argv)
	if pid > 0:
		_child_pids.append(pid)
	print("PROBE: 拉起客户端 c%d(pid=%d)" % [i, pid])


func _process(delta: float) -> void:
	if _role != "lobby" or _done:
		return
	_t += delta
	if _t > FINAL_TIMEOUT:
		_finish("超时(%.0fs;阶段 %d)\n%s" % [FINAL_TIMEOUT, _stage, _dump()])
		return
	_hb -= delta
	if _hb <= 0.0:
		_hb = 30.0
		print("PROBE: … t=%.0fs 阶段=%d(客户端 %d/6 已出结果)"
				% [_t, _stage, _results_ready()])
	match _stage:
		0:
			_stage_wait_room()
		1:
			_stage_wait_full()
		2:
			_stage_wait_start()
		3:
			_stage_collect()


func _room():
	if _rm == null or _rm.lobby.team_rooms.is_empty():
		return null
	if _code != "" and _rm.lobby.team_rooms.has(_code):
		return _rm.lobby.team_rooms[_code]
	# 只会有我们这一间(大厅是本进程起的,外面的人连不进来)
	_code = str(_rm.lobby.team_rooms.keys()[0])
	return _rm.lobby.team_rooms[_code]


func _stage_wait_room() -> void:
	var tr = _room()
	if tr == null:
		if _t > BOOT_TIMEOUT:
			_finish("%.0fs 内没有 3v3 房(客户端 c1 没建成?)\n%s" % [BOOT_TIMEOUT, _dump()])
		return
	print("PROBE: 3v3 房 %s 已建(房主 peer=%d)" % [_code, tr.host_peer])
	_stage = 1


func _stage_wait_full() -> void:
	var tr = _room()
	if tr == null:
		_finish("房间消失了(c1 掉线?)")
		return
	if tr.players.size() < CLIENT_COUNT:
		if _t > BOOT_TIMEOUT + 30.0:
			_finish("只有 %d/%d 人进了房(选边前)\n%s" % [tr.players.size(), CLIENT_COUNT, _dump()])
		return
	if not _rm.lobby.team_room_ready(tr):
		if _t > BOOT_TIMEOUT + 30.0:
			_finish("6 人已进房但选边没收齐(队号表 %s)\n%s" % [str(tr.team_of), _dump()])
		return
	var by := {1: 0, 2: 0}
	for r in tr.team_of:
		by[int(tr.team_of[r])] = int(by.get(int(tr.team_of[r]), 0)) + 1
	print("PROBE: 6 人已到齐并选边完毕 → 队号表 %s(每队 %s)" % [str(tr.team_of), str(by)])
	# - 立刻**存档**:成员转连 worker 后会陆续断开大厅,`on_peer_left` 把它们从 `player_role`
	#   摘掉,并连带把 `team_of` 里**已无人持有的 role 逐个 erase**(见 lobby_rooms.on_peer_left
	#   的 3v3 那一段)—— 到收尾时再读 `_room()` 拿到的是**空队伍表**。
	#   注意： 2026-09-21 订正本条的**理由**(代码与结论都不变):原先写的是「房在开局那一刻就被对局
	#   消费掉了(`teardown_room`)」—— 对局中的房现在**刻意不拆**(它要活到 worker 退出,否则
	#   "看得见 / 回局"两件事都无从谈起),所以收尾时房**还在**,只是表已经空了。故"必须在这里
	#   存档"照旧成立,变的只是原因。
	for r in tr.team_of:
		_lobby_teams[int(r)] = int(tr.team_of[r])
	_notes.append("大厅队伍表 %s" % str(tr.team_of))
	_stage = 2


func _stage_wait_start() -> void:
	var tr = _room()
	if tr == null:
		_finish("房间消失了(点开始前)")
		return
	if not tr.in_match:
		if _t > BOOT_TIMEOUT + 60.0:
			_finish("房主没有点开始(房内 %d 人,队号表 %s)\n%s"
					% [tr.players.size(), str(tr.team_of), _dump()])
		return
	_match_id = int(tr.match_id)
	_start_t = _t
	# 验证单进程单端口不变式：对局端口必须与大厅端口一致（隧道仅映射该单一端口）。
	_check(NetBus.server_port == LOBBY_PORT,
			"相① ★ 对局就跑在大厅那个端口上(%d;架构要求同进程同端口 —— 隧道只映射这一个)" % NetBus.server_port)
	print("PROBE: 房主已开局 → 对局端口 %d / 局号 %d(t=%.1fs)" % [LOBBY_PORT, _match_id, _t])
	_stage = 3


func _stage_collect() -> void:
	# 单进程架构下直接检查会话对象是否已挂载，不再依赖独立的子进程日志解析。
	if not _ready_seen:
		if _rm == null or _rm.get("_session") == null:
			if _t - _start_t > 30.0:
				_finish("开局 30s 后大厅里仍没有会话节点(对局没挂上来)\n%s" % _dump())
				return
		else:
			_ready_seen = true
			print("PROBE: 对局会话已挂载(t=%.1fs,局号 %d)" % [_t, _match_id])
	var n := _results_ready()
	if n >= CLIENT_COUNT or _t - _start_t > RESULT_WAIT:
		_finish("" if n >= CLIENT_COUNT else "只收到 %d/%d 份客户端结果" % [n, CLIENT_COUNT])


# ════════════════════ 跨端断言(裁判侧)════════════════════

func _finish(why: String) -> void:
	if _done:
		return
	_done = true
	# 注意： **没启动过子进程 = 一条跨端断言都没跑**:阶段 1~⑤ 的全部跨端断言都住在 `_assert_stage3()`
	#   里,而它此前只在"`_child_pids` 非空"时才被调  ->  `--nospawn`(人工另起 6 个客户端排障用)
	#   恒跳过全部跨端断言、`_failures` 为空  ->  打出一行**全空的** `TEAM MATCH PROBE: ALL-OK`,
	#   而此刻只跑过大厅那三个"房间存在吗"的阶段。那正是本册重点扫查的那一类
	#   ("还在跑、还是绿的、但已经什么都不验了")—— 且出现在本册唯一的头条证据上。
	#   故这一支**记失败**:`--nospawn` 是排障模式,不是可判通过的一跑。
	if _child_pids.is_empty():
		_check(false, "没有子进程 → 跨端断言一条都没跑(--nospawn 只用于人工排障;这一跑不判通过)")
	else:
		_assert_stage3()
	_kill_children()
	if why != "":
		_check(false, why)
	print("═══ 探针明细 ═══")
	for n in _notes:
		print("  · " + n)
	for f in _failures:
		print("  ✗ " + f)
	if _failures.is_empty():
		print("TEAM MATCH PROBE: ALL-OK")
	else:
		print("TEAM MATCH PROBE: %d 条失败" % _failures.size())
		print(_dump())
	get_tree().quit(0 if _failures.is_empty() else 1)


func _assert_stage3() -> void:
	# - 队伍表取**开工时存下的那份**:房在开局那一刻就被对局消费掉(teardown_room),
	#   到收尾时 `_room()` 恒 null —— 早先在这里读它,结果是"收尾时读到空房 + 一条假 FAIL"。
	var lobby_teams := _lobby_teams
	if lobby_teams.is_empty():
		_check(false, "大厅队伍表是空的(选边那一刻没存到)")
		return
	# ── 每端的原始读数 ──
	var teams_of := {}      # tag -> {role: team}
	var r1 := {}            # role(int) -> Vector2i
	var r1_team := {}       # role(int) -> team
	var r2 := {}
	var conv_ok := {}
	var bullet := {}
	var grenade := {}
	var round1 := {}
	var near_counts := {}
	var kill_attr := {}
	var kill_unattr := {}
	var teamfmt := {}
	var k2_ok := 0
	var k2_seen := 0
	var msync_seen := 0
	var msync_min := 99
	var esc_tag := ""
	var esc_role := 0
	var roles := {}
	var client_rows := 0
	for i in range(1, CLIENT_COUNT + 1):
		var tag := "c%d" % i
		var text := _read_result(tag)
		if text == "":
			_check(false, "%s 没有结果文件(进程没跑完/崩了)" % tag)
			continue
		if not text.begins_with("OK"):
			_check(false, "%s: %s" % [tag, text.split("\n")[0]])
		client_rows += 1
		var role := int(_tok(_head_line(text), "role", "0"))
		var team := int(_tok(_head_line(text), "team", "0"))
		roles[tag] = role
		var tl := _rec_line(text, "TEAMS")
		teams_of[tag] = _parse_pairs(_tok(tl, "map", ""))
		var rl := _rec_line(text, "R1POS")
		if rl != "":
			var cell := _parse_cell(_tok(rl, "cell", ""))
			r1[role] = cell
			r1_team[role] = int(_tok(rl, "team", "0"))
		var r2l := _rec_line(text, "R2POS")
		if r2l != "":
			r2[role] = _parse_cell(_tok(r2l, "cell", ""))
			# 阶段 4 的另一半:**换边后客户端重拉了一次 match_sync**(进场那次之后必须再有 ——
			# 换边后六端手里那份出生点是旧侧的,重拉那一拍就是把新一侧拿回来)
			msync_min = mini(msync_min, int(_tok(r2l, "msync", "0")))
			msync_seen += 1
		var k2l := _rec_line(text, "K2")
		if k2l != "":
			k2_seen += 1
			if k2l.contains("revived=1"):
				k2_ok += 1
		var cl := _rec_line(text, "CONV")
		if cl != "":
			conv_ok[role] = _tok(cl, "ok", "0") == "1"
		var bl := _rec_line(text, "BULLET")
		if bl != "":
			bullet[role] = bl
		var gl := _rec_line(text, "GRENADE")
		if gl != "":
			grenade[role] = gl
		var rol := _rec_line(text, "ROUND1")
		if rol != "":
			round1[role] = rol
		var inf := _info_line(text)
		near_counts[role] = int(_tok(inf, "near", "0"))
		kill_attr[role] = int(_tok(inf, "killA", "0"))
		kill_unattr[role] = int(_tok(inf, "killU", "0"))
		var shots := int(_tok(inf, "shots", "0"))
		if _tok(inf, "esc", "0") == "1":
			esc_tag = tag
			esc_role = role
		# 阶段 1/"等待室渲染路径"(A 册从没跑到过的那条):每端都必须真收到 team_room_state
		var room_states := int(_tok(inf, "room_states", "0"))
		if room_states <= 0:
			_check(false, "%s 没收到过 team_room_state(等待室渲染路径没跑到)" % tag)
		if int(_tok(inf, "wait_rows", "0")) <= 0:
			_check(false, "%s 的等待室名单一行都没画出来" % tag)
		var tfl := _rec_line(text, "TEAMFMT")
		if tfl != "":
			teamfmt[role] = tfl
		if _tok(inf, "match_over", "0") == "1":
			_check(false, "%s 观察到 MATCH_OVER(相⑤ 要求服务器不终局)" % tag)
		if shots < 0:
			pass
	_check(client_rows == CLIENT_COUNT, "6 端都写出了结果(实得 %d)" % client_rows)

	# ── 阶段 1 队伍表:每端拿到的 teams 必须与大厅下发的**逐值一致** ──
	for tag in teams_of:
		_check(_same_pairs(teams_of[tag], lobby_teams),
				"相① %s 的 match_sync.teams == 大厅队伍表(端 %s / 厅 %s)"
				% [tag, str(teams_of[tag]), str(lobby_teams)])
	var tcount := {1: 0, 2: 0}
	for r in lobby_teams:
		tcount[int(lobby_teams[r])] = int(tcount.get(int(lobby_teams[r]), 0)) + 1
	_check(tcount[1] == 3 and tcount[2] == 3, "相① 大厅队伍表是 3+3(实得 %s)" % str(tcount))

	# ── 阶段 1 队色 + 分队碰撞层(客户端 TEAMFMT 读数;成功也打一行,便于回溯)──
	if teamfmt.size() == CLIENT_COUNT:
		var bad_l := 0
		var bad_m := 0
		var bad_g := 0
		var bad_t := 0
		var bad_n := 0
		for r in teamfmt:
			var tl2: String = teamfmt[r]
			bad_l += 0 if _tok(tl2, "ok_layer", "0") == "1" else 1
			bad_m += 0 if _tok(tl2, "ok_mask", "0") == "1" else 1
			bad_g += int(_tok(tl2, "ghosts_bad", "0"))
			bad_t += int(_tok(tl2, "tints_bad", "0"))
			bad_n += 0 if int(_tok(tl2, "reps", "0")) == CLIENT_COUNT - 1 else 1
		_check(bad_l == 0 and bad_m == 0 and bad_g == 0 and bad_t == 0 and bad_n == 0,
				"相① ★ 队色 + 分队碰撞层六端逐值对齐(层错 %d / 掩码错 %d / 幽灵层错 %d / 队色错 %d / 副本数不对 %d)"
				% [bad_l, bad_m, bad_g, bad_t, bad_n])
	else:
		_check(false, "相① 只有 %d/%d 端写出了 TEAMFMT 读数(队色/分层没验到)"
				% [teamfmt.size(), CLIENT_COUNT])

	# ── 阶段 1 收敛(C2)──
	for r in conv_ok:
		_check(bool(conv_ok[r]), "相① role %d 本地玩家与权威快照收敛" % r)

	# ── 阶段 2 按队散点:队内最大距离 < 队间最小距离 ──
	if r1.size() == CLIENT_COUNT:
		var d := _grid_dims()
		if d == Vector2i.ZERO:
			pass   # 地图尺寸读不到 —— `_grid_dims()` 已记 FAIL;没有尺寸就不算环面距离(算出来只会误导)
		else:
			var max_in := 0
			var min_cross := 1 << 30
			var rs: Array = r1.keys()
			rs.sort()
			for a in range(rs.size()):
				for b in range(a + 1, rs.size()):
					var dist := MazeGenerator.toroidal_dist(r1[rs[a]], r1[rs[b]], d.x, d.y)
					if int(r1_team.get(rs[a], 0)) == int(r1_team.get(rs[b], 0)):
						max_in = maxi(max_in, dist)
					else:
						min_cross = mini(min_cross, dist)
			_check(min_cross > max_in,
					"相② 队间最小距离 %d 格 > 队内最大距离 %d 格(6 个出生点)" % [min_cross, max_in])
			_notes.append("相② 队内最大 %d 格 / 队间最小 %d 格" % [max_in, min_cross])
	else:
		_check(false, "相② 只收到 %d/6 个出生点读数" % r1.size())

	# ── 阶段 3 子弹穿透(负控制)+ 榴弹满效(正控制)──
	var shooter_role := 0
	var victim_role := 0
	var a_roles: Array = []
	for r in lobby_teams:
		if int(lobby_teams[r]) == 1:
			a_roles.append(int(r))
	a_roles.sort()
	if a_roles.size() >= 2:
		shooter_role = int(a_roles[0])
		victim_role = int(a_roles[1])
	var bl: String = bullet.get(shooter_role, "")
	if bl == "":
		_check(false, "相③ 没有甲的 BULLET 读数(role %d 没走到贴脸连射)" % shooter_role)
	else:
		var shots := int(_tok(bl, "shots", "0"))
		var hit := _tok(bl, "hit", "0")
		var los := _tok(bl, "los", "0")
		var before := int(_tok(bl, "before", "-1"))
		var after := int(_tok(bl, "after", "-1"))
		var wtype := int(_tok(bl, "wtype", "0"))
		var near := int(near_counts.get(victim_role, 0))
		var why := _tok(bl, "reason", "")
		if why == "no_bullet_weapon" and wtype == 0:
			# 注意： **空手是缺陷,不是抽签**:`wtype == 0` = 手上没有武器 —— 而这是**已登记的生产
			#   失效**("服务器玩家必须有枪…不发的话服务器上玩家开不了火,PvP **静默哑火**")。
			#   早先这一档与"抽到榴弹/激光"共用一条 `_check(true, …)`,于是空手会让阶段 3 打出一行
			#   **OK** 而不是红 —— 真缺陷被读成"抽签结果"。故先判**武器前提**。
			_check(false, "相③ 甲(role %d)是**空手**(wtype=0)却进了连射子状态 —— 「服务器玩家必须有枪」这条生产前提没成立(空手 = PvP 静默哑火),不是抽签"
					% shooter_role)
		elif why == "no_bullet_weapon":
			# 背包里没有出弹类武器(抽到榴弹/激光,且没有第二把)—— 断言在这里**无法成立**。
			# - 只进 `_notes`,**不占断言账本**:一句恒真的 `_check(true, …)` 是"恒绿空断言",
			#   而它还会把"这一相没验到"伪装成"这一相过了"。
			_notes.append("相③ 子弹那一半**未覆盖**:甲手上是 %d 号(非出弹类)且无第二把武器 —— 枪种抽签" % wtype)
		elif why == "bullet_switch_timeout":
			# - **这一档必须保持红**(与榴弹那半边的口径对齐):背包里**有**出弹枪却 2s 没切过去
			#   = 产品/协议异常(本仓有"滚轮切枪被权威 wslot 拉回"的前科),不是抽签。
			_check(false, "相③ 背包里有出弹类武器却切不过去(bullet_switch_timeout)—— 不是抽签,是缺陷")
		elif why == "rendezvous_timeout" or _tok(bl, "timeout", "0") == "1":
			# - 这一相**没验到**,而不是"枪坏了" —— 判词只许写"未覆盖",否则读日志的人(评审也踩过)
			#   会把它当成产品缺陷。-  **成因照实写"未验证"**:早先这里断言"不是开火/伤害链路的问题",
			#   而那条因果**本探针从未验证过** —— `team_bot_input.gd` 自己写着"输入链丢边沿会产生
			#   **恰好这个症状**且不报错",两者在读数上**分不开**。
			# - 只进 `_notes`,不占断言账本(理由同上一条)。dist/los 是**真读数**(取自超时那一刻,
			#   见 watcher 的 `_tick_meet_shooter`),不再是写死的 -1/0。
			_notes.append(("相③ 子弹那一半**未覆盖**:甲未能在走位窗口内走到乙身边"
					+ "(超时读数 dist=%s los=%s)★ **成因未验证** —— 「输入边沿丢失」症状与「走位没到位」相同"
					+ "(见 team_bot_input.gd),本探针分不清")
					% [_tok(bl, "dist", "?"), los])
		elif shots == 0 and wtype == 6:
			# 注意： 甲手上是**激光枪**(即时光束、不产生子弹) ->  `shots=0` 是**正确行为**,而
			#    "乙 hp 不变"这时是**空断言**。**不能把它算成绿**(那正是"恒绿空断言")也不能算红
			#    (枪没坏)—— 照实标未覆盖,只进 `_notes`。
			_notes.append("相③ 子弹那一半**未覆盖**:甲手上是激光枪(光束武器不产生子弹)—— 枪种抽签")
		else:
			_check(shots > 0,
					"相③ 甲(role %d)真的开了火(本地**峰值并发**子弹数 %d > 0 ⇒ 至少响过一枪)" % [shooter_role, shots])
			_check(los == "1", "相③ 开火那一刻甲与乙视线通畅(否则没打中可能只是被墙挡住)")
			_check(hit == "0" and before == after,
					"相③ ★ 子弹穿透队友:乙(role %d)hp 不变(%d → %d)" % [victim_role, before, after])
			_check(near > 0,
					"相③ ★ 乙端独立取证:有 %d 颗**非自己**子弹从乙身边(≤45px)飞过(否则乙 hp 不变可能是子弹根本没飞到)" % near)
	var gl: String = grenade.get(shooter_role, "")
	if gl == "":
		_check(false, "相③ 没有甲的 GRENADE 读数")
	elif _tok(gl, "thrown", "0") == "1":
		var dmg := int(_tok(gl, "dmg", "0"))
		var moved := float(_tok(gl, "moved", "0"))
		_check(dmg > 0, "相③ ★ 榴弹对队友**满效**:乙掉血 %d 点(before=%s after=%s)"
				% [dmg, _tok(gl, "before", "?"), _tok(gl, "after", "?")])
		_check(moved > 8.0, "相③ ★ 乙被推飞(%.0fpx)" % moved)
	else:
		# - 照实分栏,两种情形**判据不同**(理由见下):
		#   - 本局压根没有榴弹发射器(初始武器是**随机**发的一把,12 把里 2 把是榴弹)——
		#     这是**抽签结果**不是代码缺陷 → 记成**未覆盖**(note),不当红;
		#   - 其余原因(切枪超时/没视线/没枪)—— 那是**探针或产品**的问题 → 红。
		#   把"抽签没抽到"判成红 = 用户跑一次红一次而重启一次可能就绿,那种红没有信息量;
		#   反过来把"切枪失败"记成未覆盖 = 放走真缺陷。两者必须分开。
		var why := _tok(gl, "reason", "?")
		if why == "rendezvous_timeout":
			# - 与子弹那半边**同口径**:判词只写"未覆盖",且不把未经证实的因果写成结论 ——
			#   「输入边沿丢失」与「走位慢」在读数上分不开(见 team_bot_input.gd 文件头)。
			# - 只进 `_notes`,不占断言账本(恒真的 `_check(true, …)` 是"恒绿空断言")。
			_notes.append("相③ 榴弹那一半**未覆盖**:甲没能走到乙的贴脸距离内 ★ 成因未验证(同子弹那半边)")
		elif why == "no_grenade_launcher":
			# - 判词照实:那是**甲自己的背包**里没有 5 号武器(初始/复活只随机发一把),
			#   不等于"本局无人持榴弹发射器" —— 早先那句是过度断言。
			_notes.append("相③ 榴弹那一半**未覆盖**:甲背包里没有榴弹发射器(初始武器随机发一把)—— 枪种抽签")
		else:
			_check(false, "相③ 榴弹没投出去:%s" % why)

	# ── 阶段 4 ROUND_OVER:比分键是队号、局胜六端一致 ──
	if round1.is_empty():
		_check(false, "相④ 没有任何端观察到 ROUND_OVER(9 杀没打满)")
	else:
		var winners := {}
		var rw := {}
		for r in round1:
			winners[_tok(round1[r], "winner", "0")] = true
			rw[_tok(round1[r], "rounds_won", "")] = true
		_check(winners.size() == 1, "相④ 六端对第 1 局胜者队的看法一致(实得 %s)" % str(winners.keys()))
		_check(not winners.has("0"), "相④ 第 1 局的胜者是一个**队号**(1 或 2,不是 0/role)")
		_check(rw.size() == 1, "相④ rounds_won 六端一致(实得 %s)" % str(rw.keys()))
		var sc := _tok(round1[round1.keys()[0]], "scores", "")
		var bad := ""
		for kv in sc.split(",", false):
			var k := kv.split(":")[0]
			if k != "1" and k != "2":
				bad = k
		_check(bad == "", "相④ scores 的键是队号 1/2(实得 %s)" % sc)
		# - **非无效操作**:ROUND_OVER 不能全靠"脚本机器人自杀脱困(K)"推出来 —— `kill_event` 的
		#   射手为 0 就是无归因(自杀/溺水/坠落),非 0 才是**真实交火**打死的。`kill_event` 是
		#   广播的 → 每个客户端看到同一批,故取**各端最大值**而不是求和。
		var ka := 0
		var ku := 0
		for r in kill_attr:
			ka = maxi(ka, int(kill_attr[r]))
			ku = maxi(ku, int(kill_unattr[r]))
		# - 这一条**记读数、不当红**(理由见 watcher 的 `_tick_backoff`):脚本机器人能不能
		#   在平台跳跃图上接近对手,是**探针的质量**,不是产品缺陷 —— 判成红只会让"用户跑一次
		#   红一次"而重启一次可能就绿(没有信息量)。真交火为 0 时报告里**照实写明**它未覆盖。
		# 注意： 这一栏**只作读数,不作绿断言**(与榴弹那半边同口径):`ka>=1` 会让"9 杀主要靠
		#   回退模式推"这种局面照样测试全部通过(run20 实测:`ka=1` 而 `killU=10`、`REC BACKOFF n=1..7`)。
		# 注意： 回退模式那一句**必须真去解析 `REC BACKOFF` 再下判词**:早先那句话是**写死的**
		#   ("仍在推动回合"),裁判侧**从不解析**这个读数 —— 于是没启用回退模式的那一跑也会
		#   照着念,报告里的"未覆盖分栏"跟着失真。这里按端读一遍(有该行 ⟺ 该端 `_backoff` 被置起)。
		var bo_tags: Array = []
		var bo_max := 0
		for i in range(1, CLIENT_COUNT + 1):
			var bkl := _rec_line(_read_result("c%d" % i), "BACKOFF")
			if bkl == "":
				continue
			bo_tags.append(i)
			bo_max = maxi(bo_max, int(_tok(bkl, "n", "0")))
		if ka >= 1:
			_check(true, "相④ 真实交火击杀 %d 次(读数;这一栏**不是**「非空转」的证明 —— 见下一行的回退模式读数)" % ka)
		var bo_txt := ("**无端报告启用回退模式(REC BACKOFF)**" if bo_tags.is_empty()
				else "**回退模式(REC BACKOFF)被 %d 端启用(最大 n=%d),回合有一部分是它推的**"
						% [bo_tags.size(), bo_max])
		_notes.append("相④ 击杀来源:有归因(真实交火)%d 次 / 无归因(自杀等)%d 次 —— %s;这一半只作读数、不作绿断言"
				% [ka, ku, bo_txt])
		if ka == 0:
			_notes.append("相④ **真实交火击杀 0 次** —— 这一半未覆盖")
		_notes.append("相④ 第 1 局:%s" % round1[round1.keys()[0]])

	# ── 阶段 4 换边:期望值用**生产函数**算,不是探针自己推 ──
	if r2.size() == CLIENT_COUNT and r1.size() == CLIENT_COUNT:
		var want: Dictionary = TeamHost.compute_swap_spawns(r1, lobby_teams)
		_check(not want.is_empty(), "相④ 换边表非空(两队人数相等)")
		var d := _grid_dims()
		if d == Vector2i.ZERO:
			pass   # 地图尺寸读不到 —— `_grid_dims()` 已记 FAIL(同阶段 2)
		else:
			var bad := 0
			for r in want:
				if not r2.has(r):
					bad += 1
					continue
				var got: Vector2i = r2[r]
				var exp: Vector2i = want[r]
				if MazeGenerator.toroidal_dist(got, exp, d.x, d.y) > 1:
					bad += 1
			_check(bad == 0, "相④ ★ 整队换边:第 2 局各端出生点 == 第 1 局对调(生产函数算的期望;不符 %d 个)" % bad)
			# 换边那一拍客户端**重拉 match_sync**:每端都应 ≥2 次应答(进场 1 + 换局 1)
			_check(msync_seen == CLIENT_COUNT and msync_min >= 2,
					"相④ ★ 换边后各端都重拉了 match_sync(六端最少应答次数 %d,应 ≥2)" % msync_min)
	else:
		_check(false, "相④ 换边读数不全(第 2 局出生点 %d/6)" % r2.size())

	# ── 阶段 5 补:K 键自杀端到端(3v3 里 A 册收尾批才接上;此前是静默丢弃)──
	_check(k2_ok >= 1, "相⑤ 补 ★ K 键自杀在 3v3 走通(倒地 → 2s 复活;实得 %d 端报告读数 / %d 端走通)"
			% [k2_seen, k2_ok])

	# ── 阶段 5 少人继续 ──
	_check(esc_tag != "", "相⑤ 有一个客户端按 ESC 离场(实得 %s)" % esc_tag)
	if esc_tag != "":
		_check(esc_role != 0, "相⑤ 离场者的 role 已知(%d)" % esc_role)
		var obs := 0
		var obs_gaps: Array = []
		for i in range(1, CLIENT_COUNT + 1):
			var tag := "c%d" % i
			if tag == esc_tag:
				continue
			var text := _read_result(tag)
			var ll := _rec_line(text, "LEFT")
			if ll == "":
				continue
			if _tok(ll, "gone", "").contains(str(esc_role)):
				obs += 1
			# - 观察窗内的快照间隔:六端一起看。**服务端停发**必然同时命中**所有**在线客户端;
			#   只有**一个**客户端超时,那是**那个进程自己**卡了一下(本机同时跑 8 个 Godot),
			#   而"服务器还在发"这一命题恰好由**其余端的读数**证明(它们的窗口与它同一段墙钟)。
			#   故:≥2 端超 1s  ->  红(服务器停了);恰好 1 端  ->  记读数并说明;全 ≤1s  ->  绿。
			obs_gaps.append([tag, float(_tok(ll, "obsmax", "0").replace("ms", ""))])
		_check(obs == CLIENT_COUNT - 1,
				"相⑤ ★ 其余 %d 端都观察到 role %d 已被移出对局(仍持续收快照、服务器不终局)"
				% [CLIENT_COUNT - 1, esc_role])
		var gap_txt := ""
		for pair in obs_gaps:
			gap_txt += "%s=%.0fms " % [pair[0], float(pair[1])]
		# 注意： 判据是**每一端各自零容忍**(与观察者侧同一条:`_obs_max_gap > 1000` 即红)。
		#   **不做"≥2 端才红"的容忍**:单端超 1s 有两种可能 ——
		#     (甲) 该客户端进程自己卡了一下(本机同时跑 8 个 Godot);
		#     (乙) **服务器对那一个 peer 的定向投递异常**(`snapshot_own` 是逐 peer 定向发的,
		#          只卡一端恰恰是那条路的可疑症状)。
		#   探针**分不清**这两者,故**保守判红**;要放宽得先有能区分它们的证据。
		_check(obs_gaps.is_empty() or gap_max(obs_gaps) <= 1000.0,
				"相⑤ ★ 观察窗内快照连续(被观察的 %d 端最大间隔: %s;单端超 1s 也判红 —— 可能是该客户端自身停顿,也可能是服务器对**该 peer** 的定向投递异常,探针无法区分)"
				% [obs_gaps.size(), gap_txt])


# ════════════════════ 子进程 / 文件 ════════════════════

func _kill_children() -> void:
	# ① **按 PID 杀全部子进程**(首选):六个客户端是从**临时端口**连出去的,不占 worker 端口,
	#    只按端口杀根本杀不到它们 —— 留下的残留进程会干扰后续测试执行、并攥着自己的 `--log-file`
	#    让下一跑的清理静默失败(reconnect_probe 的 `_kill_children` 记过这两条后果)。
	var killed := 0
	for pid in _child_pids:
		if pid > 0 and OS.is_process_running(pid):
			OS.kill(pid)
			killed += 1
	print("PROBE: 按 PID 收尾 %d/%d 个子进程" % [killed, _child_pids.size()])
	_child_pids.clear()
	# 单进程单端口架构下，对局运行在当前进程内，端口即大厅端口，无需针对对局端口清理子进程。
	# 端口清理在探针脚本 team_match_probe.sh 退出时统一执行。


func _godot_log_path(tag: String) -> String:
	return ProjectSettings.globalize_path("user://%s%s.godotlog" % [RESULT_PREFIX, tag])


func _read_result(tag: String) -> String:
	return _read(ProjectSettings.globalize_path("user://%s%s.result" % [RESULT_PREFIX, tag])).strip_edges()


func _results_ready() -> int:
	var n := 0
	for i in range(1, CLIENT_COUNT + 1):
		var t := _read_result("c%d" % i)
		if t.begins_with("OK") or t.begins_with("FAIL"):
			n += 1
	return n


func _read(path: String) -> String:
	if path == "" or not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_as_text() if f != null else ""


func _tail(path: String, n: int) -> String:
	var lines := _read(path).split("\n")
	if lines.size() <= n:
		return "\n".join(lines)
	return "…(前 %d 行省略)\n" % (lines.size() - n) + "\n".join(lines.slice(lines.size() - n))


# 开工前清掉上一跑的产物。-  删除**必须看返回值**:上一跑的客户端若还活着(它攥着自己的
# `.result`/`.log`),删除会失败,新进程会与之混写 → 人会照着混了旧内容的文件做错误归因。
func _clean() -> bool:
	for i in range(1, CLIENT_COUNT + 1):
		for tag in ["c%d" % i]:
			for suffix in ["result", "log", "godotlog"]:
				var p := "user://%s%s.%s" % [RESULT_PREFIX, tag, suffix]
				if not FileAccess.file_exists(p):
					continue
				var err := DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
				if err != OK:
					# 注意： **当场退出,不能只警告**:`_results_ready()` 数的是"存在且以 OK/FAIL 开头"
					#   的文件 —— 上一跑的残留会**被当成这一跑的结果**下判决(而且看不出是旧的)。
					#   删不掉几乎只有一个原因:上一跑的客户端进程还活着(它攥着文件)。
					print("PROBE: 删不掉上一跑的 %s(错误 %d)—— 多半是上一跑的进程还活着;"
							% [p, err] + "残留文件会被当成本跑的读数下判决,故直接退出")
					return false
	return true


func _dump() -> String:
	var out := ""
	for i in range(1, CLIENT_COUNT + 1):
		var tag := "c%d" % i
		out += "  [%s 引擎日志]\n%s\n" % [tag, _tail(_godot_log_path(tag), 25)]
	# 单进程架构下对局与大厅共用标准输出，无独立的 worker 日志，此处记录大厅侧的运行时状态（会话节点状态与局号）。
	out += "  [大厅侧]监听端口 %d / 会话节点 %s / 局号 %d\n" % [NetBus.server_port,
			"已挂载" if (_rm != null and _rm.get("_session") != null) else "无", _match_id]
	return out


# ════════════════════ 读数解析小工具 ════════════════════

func _head_line(text: String) -> String:
	var ls := text.split("\n")
	return ls[0] if ls.size() > 0 else ""


func _rec_line(text: String, key: String) -> String:
	for l in text.split("\n"):
		if l.begins_with("REC " + key):
			return l
	return ""


# 客户端把读数分成**两行** INFO(一行业务读数、一行质量读数)→ 这里必须**两行都并起来**再取键。
# - 早先只取 `INFO snapmax` 那一行  ->  `room_states`/`wait_rows` 永远读不到 0 以外的值  -> 
#   "等待室渲染路径"那两条断言**恒红**(实测 run9:六端全红,而客户端日志里 `room_states=1` 明明在)。
func _info_line(text: String) -> String:
	var out := ""
	for l in text.split("\n"):
		if l.begins_with("INFO "):
			out += l + " "
	return out


func _tok(line: String, key: String, def: String) -> String:
	for part in line.split(" ", false):
		if part.begins_with(key + "="):
			return part.substr(key.length() + 1)
	# 头行的 role=/team= 也在 token 里(head 形如 "OK c1 role=3 team=1")
	return def


func _parse_cell(s: String) -> Vector2i:
	var p := s.split(",")
	if p.size() != 2:
		return Vector2i(-1, -1)
	return Vector2i(int(p[0]), int(p[1]))


func _parse_pairs(s: String) -> Dictionary:
	var out := {}
	for kv in s.split(",", false):
		var p := kv.split(":")
		if p.size() == 2:
			out[int(p[0])] = int(p[1])
	return out


func _same_pairs(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for k in b:
		if not a.has(k) or int(a[k]) != int(b[k]):
			return false
	return true


# 环面回绕尺寸(阶段 2/阶段 4 的格距离要用)。-  **必须来自地图文件本身**,不能回落硬编码:
# 裁判进程**从不加载地图**(它只当大厅),`MazeGenerator.current_grid` 恒空 —— 早先这里回落
# `(150,100)`,恰好等于 `newfactory` 的尺寸,于是"碰巧对";**换图之后会静默按错尺寸回绕**
# (格距离全错,而断言照跑)。改为直接读地图头(`MapFormat.map_size`)。
# 注意： 读不到时**返回 `Vector2i.ZERO` 并记一条 FAIL,绝不回落任何字面量**:回落到一个"本图像素的
#   尺寸"正是上面说的"碰巧对" —— 它会让换图后**照样测试全部通过**。返回零则调用方一眼可见(阶段 2/阶段 4
#   的环面判据直接跳过,而这条 FAIL 已经把整跑判红)。失败**只记一次**(两个调用点各调一次)。
func _grid_dims() -> Vector2i:
	var d := MapFormat.map_size(MatchBootstrap.PVP_MAP)
	if d.x <= 0 or d.y <= 0:
		if not _dims_failed:
			_dims_failed = true
			_check(false, "读不到地图尺寸 %s —— 相②/相④ 的环面判据不可信(**不回落字面量**:回落 (150,100) 恰好是本图尺寸,换图后会静默按错尺寸回绕)"
					% MatchBootstrap.PVP_MAP)
		return Vector2i.ZERO
	return d


func gap_max(a: Array) -> float:
	var m := 0.0
	for pair in a:
		m = maxf(m, float(pair[1]))
	return m


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("  OK  %s" % msg)
	else:
		_failures.append(msg)
		print("  FAIL %s" % msg)


# ════════════════════ 客户端(子进程)════════════════════

func _run_client() -> void:
	var w: Node = load("res://tests/harness/team_match_watcher.gd").new()
	w.set("who", _who)
	w.set("idx", _idx)
	w.set("lobby_port", LOBBY_PORT)
	# 观察者挂 `root`(不是本场景):实际大厅页 → 真 team_game 的那次换场不会把它带走
	get_tree().root.add_child.call_deferred(w)
	print("PROBE[%s]: 客户端就绪,等观察者连大厅 %d" % [_who, LOBBY_PORT])
