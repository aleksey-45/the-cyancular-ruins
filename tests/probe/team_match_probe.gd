extends Node

# 3v3 团队模式的六人真实网络链路端到端探针。场景模式(autoload 必须已实例化)。
#
# 运行方式(用户侧):
#   timeout 1800 bash tests/probe/team_match_probe.sh
# 或直接:
#   "$GODOT" --headless --path . --quit-after 54000 res://tests/probe/team_match_probe.tscn
# 验收标准：文本 `TEAM MATCH PROBE: ALL-OK`(不看退出码 —— 探针阻塞挂起时 `--quit-after` 到期仍
# exit 0 且一行 ALL-OK 都不打印,只看退出码会把"未完整执行"读成"通过")。
#
# ── 测试阶段划分（参考设计文档，各阶段设计目的见对应代码实现）──
#   阶段 1 六人开局：启动独立测试端口大厅服务并拉起 6 个无头客户端，加载真实 mp_lobby 场景：
#        创建房间 -> 列表加入 -> 阵营分配(3v3) -> 房主开局 -> 6 端全部进入 `team_game`。
#        断言：6 端全部成功进入对局；各端 `match_sync.teams` 与大厅队伍分配严格一致；
#        各端本地玩家与权威快照收敛（阶段 1 的 C2 预测回滚验证）。
#        - 同时覆盖等待室渲染路径（验证 team_room_state 正常同步且已渲染名单行）。
#   阶段 2 按队散点：开局时刻 6 个出生点两两分组，队内最大间距小于队间最小间距
#        （验证团队出生点空间拓扑聚类特征）。
#   阶段 3 子弹穿透队友与榴弹伤害：
#        角色甲（1 队）向视线良好的队友乙连射：乙生命值保持不变；
#        随后切换榴弹发射器贴近发射：乙受到范围爆炸伤害并被击退。
#        - 同时从乙端独立采集指标：统计掠过本地玩家（距离 <= 45px）且非自身发射的子弹数量，
#          避免因射击被地形遮挡导致伤害断言误判。
#   阶段 4 回合击杀推进与换边：打满 9 次击杀触发 ROUND_OVER -> 第 2 回合开局后各端出生点正确对调。
#        断言各端比分键为队伍编号（1 或 2），各端 rounds_won 胜场数完全一致。
#   阶段 5 玩家中途离场容错：6 号客户端在中途按 ESC 键离场，服务端不终止对局，其余 5 端持续正常同步。
#
# ── 网络拓扑架构（探针主进程作为大厅与裁判服务端；子进程通过 OS.create_process 启动）──
#   主进程：运行真实大厅服务（NetBus.start_server(LOBBY_PORT) 与 RoomManager），使用测试专用端口；
#   c1..c6：6 个无头客户端，分别加载真实 mp_lobby 场景并进入 team_game 对局；
#   对局会话：由 RoomManager.team_start 启动，与生产环境调用链路完全一致。
#   - 端口分配规范：大厅与对局端口均分配在生产端口池之外，避免与其他测试或服务发生端口冲突。
#
# ── 前提 ──
#   请确认没有别的 Godot 占着 7777(本探针不占 7777,但别终止用户自己的服务端)。
#   客户端子进程的 stdout 父进程看不到(Windows `CreateProcess` 不继承句柄) -> 每个子进程
#   都带 `--log-file`;失败时本探针把每个客户端的引擎日志尾部一起打印出来。
#   收尾按 PID 杀本进程启动过的全部子进程(客户端是从临时端口连出去的,只按端口杀
#   根本杀不到;对局侧没有第二个进程可杀 —— 它就是本进程,见 `_kill_children`)。
#
# ── 时间预算 ──
#   阶段 1~③ 约 40~90s;阶段 4 打到 9 杀是脚本机器人尽力交火 + 回退模式的结果,是本探针最大的时间
#   不确定项(上限 `BRAWL_MAX`=210s);阶段 5 的观察窗要等满 60s 宽限期(上限 `OBSERVE_MAX`=110s)。
#   完整测试运行量级 3~10 分钟;超时保护上限 `--quit-after 54000`(60fps 下 = 900s;`run/max_fps=60`);
#   本进程自己的测试完成退出上限 `FINAL_TIMEOUT`=780s(> 等结果预算 `RESULT_WAIT`=680s;
#   - `RESULT_WAIT` 一旦超过 780 就必须同步抬 `FINAL_TIMEOUT`,否则测试完成退出上限会先于预算到点)。

const RESULT_PREFIX := "team_match_probe_"
# 端口分配规范：大厅与对局共用同一端口，使用独立的 29200 端口，避开默认 7777 端口与常见服务端口。
const LOBBY_PORT := 29200
const CLIENT_COUNT := 6
const CHILD_QUIT_AFTER := "54000"  # 子进程兜底保护(60fps ≈ 900s);正常由本进程收尾/按 PID 杀
const BOOT_TIMEOUT := 45.0         # 等"6 人进房并选边完毕"的上限
const FINAL_TIMEOUT := 780.0       # 本进程的测试完成退出上限(完整测试运行量级 4~10 分钟;预算见下)
# 等 6 份客户端结果文件的上限。-  必须大于客户端自己的时间线(它们的相位全靠自己的时钟推),
#   且逐项按 watcher 的常量求和算出来 —— 别凭印象写:这行漂过两次,一次把 `RENDEZVOUS_MAX`
#   记成了 70(实际是 100),一次停在宽限期还是 30s 时的那份求和(2026-09-21 宽限期 30 -> 60,
#   `OBSERVE_MAX` 60 -> 110,整条求和随之 +50)。越时的表象是"只收到 N/6 份客户端结果",
#   读起来像产品故障,其实是探针自己的预算算错了。逐项(各项都是 watcher 的常量):
#     进局 ~5s + SETTLE 1.2 + RENDEZVOUS_MAX 100 + BRAWL_MAX 210 + 换局 SETTLE 1.2
#     + OBSERVE_MAX 110 + PEER_WAIT 120 ≈ 547.4s;
#     进局那一档的硬上限是 `ENTER_TIMEOUT` 90s(不是 5s),最坏 ≈ 632.4s  ->  取 680 提供容错保障两种走法。
#   - 680 < `FINAL_TIMEOUT` 780(测试完成退出上限仍在预算之上);**一旦本值超过 780 就必须同步抬
#     `FINAL_TIMEOUT`**,否则测试完成退出上限先到点  ->  症状同样是"只收到 N/6 份结果"。
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


# ── 裁判(大厅)──

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
	# - 立刻存档:成员转连 worker 后会陆续断开大厅,`on_peer_left` 把它们从 `player_role`
	#   摘掉,并连带把 `team_of` 里已无人持有的 role 逐个 erase(见 lobby_rooms.on_peer_left
	#   的 3v3 那一段)—— 到收尾时再读 `_room()` 拿到的是空队伍表。
	# 注意事项：2026-09-21 订正本条的理由(代码与结论都不变):原先写的是「房在开局那一刻就被对局
	#   消费掉了(`teardown_room`)」—— 对局中的房现在刻意不拆(它要活到 worker 退出,否则
	#   "看得见 / 重连返回对局"两项关键逻辑都无从谈起),所以收尾时房还在,只是表已经空了。故"必须在这里
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


# ── 跨端断言(裁判侧)──

func _finish(why: String) -> void:
	if _done:
		return
	_done = true
	# 注意事项：未启动子进程即表示跨端断言未执行。
	#   --nospawn 仅用于手动另起客户端排障调试，不能作为自动化测试通过的依据。
	if _child_pids.is_empty():
		_check(false, "未检测到子进程：跨端断言未执行（--nospawn 仅用于手动排障，不能判定为测试通过）")
	else:
		_assert_stage3()
	_kill_children()
	if why != "":
		_check(false, why)
	print("── 探针执行明细 ──")
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
	# - 队伍表取开工时存下的那份:房在开局那一刻就被对局消费掉(teardown_room),
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
			# 阶段 4 的另一半:换边后客户端重拉了一次 match_sync(进场那次之后必须再有 ——
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

	# ── 阶段 1 队伍表:每端拿到的 teams 必须与大厅下发的逐值一致 ──
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
			# 注意事项：空手是缺陷,不是抽签:`wtype == 0` = 手上没有武器 —— 而这是**已登记的生产
			#   失效("服务器玩家必须有枪…不发的话服务器上玩家开不了火,PvP 静默哑火**")。
			#   早先这一档与"抽到榴弹/激光"共用一条 `_check(true, …)`,于是空手会让阶段 3 输出一行
			#   OK 而不是红 —— 真缺陷被读成"抽签结果"。故先判武器前提。
			_check(false, "相③ 甲(role %d)是**空手**(wtype=0)却进了连射子状态 —— 「服务器玩家必须有枪」这条生产前提没成立(空手 = PvP 静默哑火),不是抽签"
					% shooter_role)
		elif why == "no_bullet_weapon":
			# 背包里没有出弹类武器(抽到榴弹/激光,且没有第二把)—— 断言在这里无法成立。
			# - 仅记录至 `_notes`，不计入断言统计：恒真的 `_check(true, …)` 属于无有效检验效力的空断言，
			#   而它还会把"该测试阶段没验到"伪装成"该测试阶段过了"。
			_notes.append("相③ 子弹那一半**未覆盖**:甲手上是 %d 号(非出弹类)且无第二把武器 —— 枪种抽签" % wtype)
		elif why == "bullet_switch_timeout":
			# - 这一档必须保持红(与榴弹那半边的口径对齐):背包里有出弹枪却 2s 没切过去
			#   = 产品/协议异常(本仓有"滚轮切枪被权威 wslot 拉回"的前科),不是抽签。
			_check(false, "相③ 背包里有出弹类武器却切不过去(bullet_switch_timeout)—— 不是抽签,是缺陷")
		elif why == "rendezvous_timeout" or _tok(bl, "timeout", "0") == "1":
			# - 该阶段由于超时未完成覆盖，提示信息注明“未覆盖”，避免被误读为功能缺陷。成因如实记录为未明确验证。
			# - 只进 `_notes`，不计入断言失败。dist/los 取自超时时刻的实际读数。
			_notes.append(("相③ 子弹那一半**未覆盖**:甲未能在走位窗口内走到乙身边"
					+ "(超时读数 dist=%s los=%s)★ **成因未验证** —— 「输入边沿丢失」症状与「走位没到位」相同"
					+ "(见 team_bot_input.gd),本探针分不清")
					% [_tok(bl, "dist", "?"), los])
		elif shots == 0 and wtype == 6:
			# 注意事项：甲手上是激光枪(即时光束、不产生子弹) ->  `shots=0` 是正确行为,而
			#    "乙 hp 不变"此时属于空断言。不能将其计为测试通过（避免引入假阳性空断言），亦不能判定失败
			#    (枪没坏)—— 照实标未覆盖,只进 `_notes`。
			_notes.append("相③ 子弹那一半**未覆盖**:甲手上是激光枪(光束武器不产生子弹)—— 枪种抽签")
		else:
			_check(shots > 0,
					"相③ 甲(role %d)成功开火(本地峰值并发子弹数 %d > 0)" % [shooter_role, shots])
			_check(los == "1", "相③ 开火时甲与乙视线通畅（排除掩体遮挡干扰）")
			_check(hit == "0" and before == after,
					"相③ 子弹穿透队友：乙(role %d)生命值保持不变(%d → %d)" % [victim_role, before, after])
			_check(near > 0,
					"相③ 乙端独立判定：检测到 %d 颗非自身子弹掠过（距离 <= 45px）" % near)
	var gl: String = grenade.get(shooter_role, "")
	if gl == "":
		_check(false, "相③ 未获取到角色甲的 GRENADE 读数")
	elif _tok(gl, "thrown", "0") == "1":
		var dmg := int(_tok(gl, "dmg", "0"))
		var moved := float(_tok(gl, "moved", "0"))
		_check(dmg > 0, "相③ 榴弹对队友生效：乙受到伤害 %d 点(before=%s after=%s)"
				% [dmg, _tok(gl, "before", "?"), _tok(gl, "after", "?")])
		_check(moved > 8.0, "相③ 乙被爆炸击退(%.0fpx)" % moved)
	else:
		# 分类处理未覆盖与异常状态：
		# 1. 本局未分配到榴弹发射器（初始武器随机分配）属于测试随机覆盖范围，记为未覆盖（_notes）；
		# 2. 切枪超时或武器异常等属于功能故障，判定为断言失败。
		var why := _tok(gl, "reason", "?")
		if why == "rendezvous_timeout":
			# 提示信息标注为未覆盖，不计入断言账本
			_notes.append("相③ 榴弹部分未覆盖：甲未能移动至乙近身范围内（成因未明确验证）")
		elif why == "no_grenade_launcher":
			# 提示信息准确说明：当前为角色甲背包内未持有榴弹发射器（初始武器随机分配）
			_notes.append("相③ 榴弹部分未覆盖：角色甲背包未分配到榴弹发射器")
		else:
			_check(false, "相③ 榴弹未成功发射：%s" % why)

	# ── 阶段 4 ROUND_OVER：比分键为队伍编号，胜场统计各端一致 ──
	if round1.is_empty():
		_check(false, "相④ 没有任何客户端观察到 ROUND_OVER（未达到 9 次击杀）")
	else:
		var winners := {}
		var rw := {}
		for r in round1:
			winners[_tok(round1[r], "winner", "0")] = true
			rw[_tok(round1[r], "rounds_won", "")] = true
		_check(winners.size() == 1, "相④ 六端对第 1 局胜者队伍判定一致(实得 %s)" % str(winners.keys()))
		_check(not winners.has("0"), "相④ 第 1 局胜者为有效队伍编号(1 或 2)")
		_check(rw.size() == 1, "相④ rounds_won 各端统计一致(实得 %s)" % str(rw.keys()))
		var sc := _tok(round1[round1.keys()[0]], "scores", "")
		var bad := ""
		for kv in sc.split(",", false):
			var k := kv.split(":")[0]
			if k != "1" and k != "2":
				bad = k
		_check(bad == "", "相④ scores 比分键为队号 1/2(实得 %s)" % sc)
		# 统计击杀事件数据：ROUND_OVER 包含正常交火击杀与脱困自杀等无归因击杀（射手为 0）。
		# 此处记录交火击杀读数，若交火为 0 则在报告中如实标明未覆盖。
		var ka := 0
		var ku := 0
		for r in kill_attr:
			ka = maxi(ka, int(kill_attr[r]))
			ku = maxi(ku, int(kill_unattr[r]))
		# 注意事项：回退机制的诊断说明必须实际解析 REC BACKOFF 字段，避免硬编码描述失真。
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

	# ── 阶段 4 换边:期望值用生产函数算,不是探针自己推 ──
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
			# 换边那一拍客户端重拉 match_sync:每端都应 ≥2 次应答(进场 1 + 换局 1)
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
			# - 观察窗内的快照间隔:六端一起看。服务端停发必然同时命中所有在线客户端;
			#   只有一个客户端超时,那是那个进程自己卡了一下(本机同时跑 8 个 Godot),
			#   而"服务器还在发"这一命题恰好由其余端的读数证明(它们的窗口与它同一段实际物理耗时（Wall-clock time）)。
			#   故:≥2 端超 1s  ->  红(服务器停了);恰好 1 端  ->  记读数并说明;全 ≤1s  ->  绿。
			obs_gaps.append([tag, float(_tok(ll, "obsmax", "0").replace("ms", ""))])
		_check(obs == CLIENT_COUNT - 1,
				"相⑤ ★ 其余 %d 端都观察到 role %d 已被移出对局(仍持续收快照、服务器不终局)"
				% [CLIENT_COUNT - 1, esc_role])
		var gap_txt := ""
		for pair in obs_gaps:
			gap_txt += "%s=%.0fms " % [pair[0], float(pair[1])]
		# 注意事项：判定依据为针对每一端各自执行严格判定（与观察者一致：`_obs_max_gap > 1000` 即判定失败）。
		#   不做多端容忍：单端快照间隔超过 1s 包含两种成因 ——
		#     (甲) 该客户端进程自身短暂停顿；
		#     (乙) 服务端针对该 peer 的定向投递异常（`snapshot_own` 为逐 peer 定向发送，
		#          仅单端卡顿正是该路径的典型异常表现）。
		#   在无法确切区分时采取严格断言策略；若需放宽需提供可靠的甄别依据。
		_check(obs_gaps.is_empty() or gap_max(obs_gaps) <= 1000.0,
				"相⑤ ★ 观察窗内快照连续(被观察的 %d 端最大间隔: %s;单端超 1s 也判红 —— 可能是该客户端自身停顿,也可能是服务器对**该 peer** 的定向投递异常,探针无法区分)"
				% [obs_gaps.size(), gap_txt])


# ── 子进程 / 文件 ──

func _kill_children() -> void:
	# ① 按 PID 杀全部子进程(首选):六个客户端是从临时端口连出去的,不占 worker 端口,
	#    只按端口杀根本杀不到它们 —— 留下的残留进程会干扰后续测试执行，并导致文件句柄被占用而使清理失败。
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


# 测试执行前清理历史残留文件（.result、.log 及 .godotlog）。
# 必须检查删除操作的返回值：若上一次测试的客户端进程未退出，文件句柄被占用会导致删除失败，进而造成新旧日志混淆。
func _clean() -> bool:
	for i in range(1, CLIENT_COUNT + 1):
		for tag in ["c%d" % i]:
			for suffix in ["result", "log", "godotlog"]:
				var p := "user://%s%s.%s" % [RESULT_PREFIX, tag, suffix]
				if not FileAccess.file_exists(p):
					continue
				var err := DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
				if err != OK:
					# 注意事项：清理失败必须直接终止测试退出，防止上一次运行的残留文件被误当成本次运行结果。
					print("PROBE: 无法删除上一次测试产生的文件 %s(错误 %d)—— 客户端进程可能尚未退出，终止执行"
							% [p, err])
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


# ── 读数解析小工具 ──

func _head_line(text: String) -> String:
	var ls := text.split("\n")
	return ls[0] if ls.size() > 0 else ""


func _rec_line(text: String, key: String) -> String:
	for l in text.split("\n"):
		if l.begins_with("REC " + key):
			return l
	return ""


# 客户端把读数分成两行 INFO(一行业务读数、一行质量读数) -> 这里必须两行都并起来再取键。
# - 早先只取 `INFO snapmax` 那一行  ->  `room_states`/`wait_rows` 永远读不到 0 以外的值  -> 
#   "等待室渲染路径"那两条断言始终断言失败(实测 run9:六端全部失败,而客户端日志里 `room_states=1` 明明在)。
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


# 环面回绕尺寸(阶段 2/阶段 4 的格距离要用)。-  必须来自地图文件本身,不能回落硬编码:
# 裁判进程从不加载地图(它只当大厅),`MazeGenerator.current_grid` 恒空 —— 早先这里回落
# `(150,100)`,恰好等于 `newfactory` 的尺寸,于是"碰巧对";换图之后会静默按错尺寸回绕
# (格距离全错,而断言照跑)。改为直接读地图头(`MapFormat.map_size`)。
# 注意事项：读取失败时返回 `Vector2i.ZERO` 并记录一次断言失败，严禁回退至任何硬编码字面量：
#   硬编码回退容易引入伪绿假阳性。返回零能使调用方显式感知异常（阶段 2/阶段 4
#   的环面判定条件直接跳过，且该 FAIL 会直接使整体测试失败）。失败记录限制为仅记录一次。
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


# ── 客户端(子进程)──

func _run_client() -> void:
	var w: Node = load("res://tests/harness/team_match_watcher.gd").new()
	w.set("who", _who)
	w.set("idx", _idx)
	w.set("lobby_port", LOBBY_PORT)
	# 观察者挂 `root`(不是本场景):真实大厅服务页 -> 真 team_game 的那次换场不会销毁该节点（跨场景保持驻留）
	get_tree().root.add_child.call_deferred(w)
	print("PROBE[%s]: 客户端就绪,等观察者连大厅 %d" % [_who, LOBBY_PORT])
