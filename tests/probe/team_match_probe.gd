extends Node


const RESULT_PREFIX := "team_match_probe_"
# ★ 端口纪律(与 reconnect_probe 的常量区同源):全仓对局 worker 的池 = WorkerLauncher.WORKER_PORT_BASE(7800)~ +SPAN(500)= 8300 开区间;本探针的大厅与 worker 都取池外(29xxx),同时远离 7777 与常见服务端口。
const LOBBY_PORT := 29200
const WORKER_PORT_OUT := 29250
const POOL_LOW := 7800
const POOL_HIGH := 8300
const CLIENT_COUNT := 6
# 本探针是「六人 3v3」用例:产品闸门已放宽成两队各 ≥1 即可开局(`RoomTypes.team_ready`),
# 探针必须自己等每队 3 人全选完才点开始,否则 worker 侧会被 `team_autofill` 补人(相① 的"端 == 厅"会假红)。
const PROBE_TEAM_SIZE := 3
const CHILD_QUIT_AFTER := "54000"
const BOOT_TIMEOUT := 45.0
const FINAL_TIMEOUT := 800.0
const RESULT_WAIT := 680.0
const MIN_CHECKS := 24

var _role := "lobby"
var _who := "c1"
var _idx := 1
var _t := 0.0
var _stage := 0
var _rm: Node = null
var _code := ""
var _worker_port := 0
var _ready_seen := false
var _start_t := -1.0
var _child_pids: Array[int] = []
var _hb := 30.0
var _lobby_teams: Dictionary = {}
var _failures: Array[String] = []
var _notes: Array[String] = []
var _checks := 0
var _dims_failed := false
var _done := false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			_role = a.trim_prefix("--role=")
		elif a.begins_with("--who="):
			_who = a.trim_prefix("--who=")
		elif a.begins_with("--lobby-port="):
			pass
	_idx = int(_who.trim_prefix("c")) if _who.begins_with("c") else 1
	if _role == "lobby":
		_run_orchestrator()
	else:
		_run_client()



func _run_orchestrator() -> void:
	var err := NetBus.start_server(LOBBY_PORT)
	if err != OK:
		print("PROBE: 大厅监听失败 err=%d(端口 %d 被占?本探针**不占 7777**,该端口是本探针自己的)"
				% [err, LOBBY_PORT])
		get_tree().quit(1)
		return
	_rm = RoomManager.new()
	add_child(_rm)
	_rm.get("_launcher").set("_next_port", WORKER_PORT_OUT)
	# ★ _clean() 失败(上一跑的进程还活着)时必须整段收工:只 push 一条然后继续拉起客户端的话,6 个新客户端与那批残留进程会互相覆盖 .result,而且本进程退出后 _kill_children() 再也不跑 ⇒ 留下一堆孤儿进程攥着文件,把下一跑也逼进这一支(实测复现过)。
	if not _clean():
		print("PROBE: 清理失败(多半是上一跑的进程还活着)—— 不拉起客户端,直接退出")
		get_tree().quit(1)
		return
	print("PROBE: 大厅就绪(port %d,池外);worker 起投端口 %d" % [LOBBY_PORT, WORKER_PORT_OUT])
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
	var by := {1: 0, 2: 0}
	for r in tr.team_of:
		var t := int(tr.team_of[r])
		by[t] = int(by.get(t, 0)) + 1
	if tr.team_of.size() < CLIENT_COUNT or int(by[1]) != PROBE_TEAM_SIZE or int(by[2]) != PROBE_TEAM_SIZE:
		if _t > BOOT_TIMEOUT + 30.0:
			_finish("6 人已进房但选边没收齐(应 %d+%d,实得 %s / 队号表 %s)\n%s"
					% [PROBE_TEAM_SIZE, PROBE_TEAM_SIZE, str(by), str(tr.team_of), _dump()])
		return
	print("PROBE: 6 人已到齐并选边完毕 → 队号表 %s(每队 %s)" % [str(tr.team_of), str(by)])
	# ★ 立刻存档:成员转连 worker 后会陆续断开大厅,on_peer_left 把它们从 player_role 摘掉,并连带把 team_of 里已无人持有的 role 逐个 erase(见 lobby_rooms.on_peer_left 的 3v3 那一段)—— 到收尾时再读 _room() 拿到的是空队伍表。
	#   ★ 订正本条的理由(代码与结论都不变):原先写的是「房在开局那一刻就被对局消费掉了」—— 对局中的房现在刻意不拆(它要活到 worker 退出,否则「看得见 / 回局」都无从谈起),所以收尾时房还在,只是表已经空了。故「必须在这里存档」照旧成立,变的只是原因。
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
	_worker_port = int(tr.worker_port)
	_start_t = _t
	# ★ 端口纪律:worker 必须在池外(否则本探针收尾的"按端口杀 worker"可能误杀别人的对局)
	_check(_worker_port < POOL_LOW or _worker_port >= POOL_HIGH,
			"worker 端口 %d 落在真大厅的端口池 [%d,%d) 之外" % [_worker_port, POOL_LOW, POOL_HIGH])
	print("PROBE: 房主已开局 → worker 端口 %d(t=%.1fs)" % [_worker_port, _t])
	_stage = 3


func _stage_collect() -> void:
	# worker 就绪(读它自己的引擎日志 —— worker 是独立进程,日志是唯一能看到它内部动作的通道)
	if not _ready_seen:
		var txt := _read(_worker_log_path())
		if txt.contains("3v3 worker 就绪"):
			_ready_seen = true
			print("PROBE: worker 已就绪(t=%.1fs)" % _t)
		elif _t - _start_t > 30.0:
			_finish("worker 30s 内没报就绪(日志尾部)\n%s" % _tail(_worker_log_path(), 25))
			return
	var n := _results_ready()
	if n >= CLIENT_COUNT or _t - _start_t > RESULT_WAIT:
		_finish("" if n >= CLIENT_COUNT else "只收到 %d/%d 份客户端结果" % [n, CLIENT_COUNT])



func _finish(why: String) -> void:
	if _done:
		return
	_done = true
	if _child_pids.is_empty():
		_check(false, "没有子进程 → 跨端断言一条都没跑(--nospawn 只用于人工排障;这一跑不判通过)")
	else:
		_assert_stage3()
	_kill_children()
	if why != "":
		_check(false, why)
	if _checks < MIN_CHECKS:
		_check(false, "★ 只跑了 %d 条断言(< MIN_CHECKS=%d)—— 有断言被静默跳过?" % [_checks, MIN_CHECKS])
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
	var lobby_teams := _lobby_teams
	if lobby_teams.is_empty():
		_check(false, "大厅队伍表是空的(选边那一刻没存到)")
		return
	var teams_of := {}
	var r1 := {}
	var r1_team := {}
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
		var b_line := _rec_line(text, "BULLET")
		if b_line != "":
			bullet[role] = b_line
		var g_line := _rec_line(text, "GRENADE")
		if g_line != "":
			grenade[role] = g_line
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

	for tag in teams_of:
		_check(_same_pairs(teams_of[tag], lobby_teams),
				"相① %s 的 match_sync.teams == 大厅队伍表(端 %s / 厅 %s)"
				% [tag, str(teams_of[tag]), str(lobby_teams)])
	var tcount := {1: 0, 2: 0}
	for r in lobby_teams:
		tcount[int(lobby_teams[r])] = int(tcount.get(int(lobby_teams[r]), 0)) + 1
	_check(tcount[1] == 3 and tcount[2] == 3, "相① 大厅队伍表是 3+3(实得 %s)" % str(tcount))

	if teamfmt.size() == CLIENT_COUNT:
		var bad_l := 0
		var bad_m := 0
		var bad_p := 0
		var bad_t := 0
		var bad_n := 0
		for r in teamfmt:
			var tl2: String = teamfmt[r]
			bad_l += 0 if _tok(tl2, "ok_layer", "0") == "1" else 1
			bad_m += 0 if _tok(tl2, "ok_mask", "0") == "1" else 1
			bad_p += int(_tok(tl2, "probes_bad", "0"))
			bad_t += int(_tok(tl2, "tints_bad", "0"))
			bad_n += 0 if int(_tok(tl2, "reps", "0")) == CLIENT_COUNT - 1 else 1
		_check(bad_l == 0 and bad_m == 0 and bad_p == 0 and bad_t == 0 and bad_n == 0,
				"相① ★ 队色 + 玩家不互挡契约六端逐值对齐(层错 %d / 掩码错 %d / 副本几何探针非零碰撞 %d / 队色错 %d / 副本数不对 %d)"
				% [bad_l, bad_m, bad_p, bad_t, bad_n])
	else:
		_check(false, "相① 只有 %d/%d 端写出了 TEAMFMT 读数(队色/分层没验到)"
				% [teamfmt.size(), CLIENT_COUNT])

	_check(conv_ok.size() == CLIENT_COUNT, "相① 六端都写出了 CONV(收敛)读数(实得 %d)" % conv_ok.size())
	var conv_bad := 0
	for r in conv_ok:
		if not bool(conv_ok[r]):
			conv_bad += 1
	_check(conv_ok.size() == CLIENT_COUNT and conv_bad == 0,
			"相① 六端本地玩家与权威快照收敛(不符 %d 端)" % conv_bad)

	if r1.size() == CLIENT_COUNT:
		var d := _grid_dims()
		if d == Vector2i.ZERO:
			pass
		else:
			var wrong_side := 0
			var side_counts := {1: 0, 2: 0}
			for r in r1:
				var want := int(r1_team.get(int(r), 0))
				var got := SpawnChooser.side_of(r1[r], d)
				side_counts[got] = int(side_counts.get(got, 0)) + 1
				if want == 0 or got != want:
					wrong_side += 1
			_check(wrong_side == 0, "相② ★ 每人都出生在自己队那半边(队1=左半/队2=右半;错 %d 人)" % wrong_side)
			_check(int(side_counts[1]) == PROBE_TEAM_SIZE and int(side_counts[2]) == PROBE_TEAM_SIZE,
					"相② 两侧各 %d 人(实得 %d / %d)" % [PROBE_TEAM_SIZE, side_counts[1], side_counts[2]])
			_notes.append("相② 侧分布 %d/%d" % [side_counts[1], side_counts[2]])
	else:
		_check(false, "相② 只收到 %d/6 个出生点读数" % r1.size())

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
			# ★★ 空手是缺陷,不是抽签:wtype == 0 = 手上没有武器 —— 而这是已登记的生产失效(服务器玩家必须有枪,不发的话服务器上玩家开不了火,PvP 静默哑火)。
			_check(false, "相③ 甲(role %d)是**空手**(wtype=0)却进了连射子状态 —— 「服务器玩家必须有枪」这条生产前提没成立(空手 = PvP 静默哑火),不是抽签"
					% shooter_role)
		elif why == "no_bullet_weapon":
			_notes.append("相③ 子弹那一半**未覆盖**:甲手上是 %d 号(非出弹类)且无第二把武器 —— 枪种抽签" % wtype)
		elif why == "bullet_switch_timeout":
			_check(false, "相③ 背包里有出弹类武器却切不过去(bullet_switch_timeout)—— 不是抽签,是缺陷")
		elif why == "rendezvous_timeout" or _tok(bl, "timeout", "0") == "1":
			_notes.append(("相③ 子弹那一半**未覆盖**:甲未能在走位窗口内走到乙身边"
					+ "(超时读数 dist=%s los=%s)★ **成因未验证** —— 「输入边沿丢失」症状与「走位没到位」相同"
					+ "(见 team_bot_input.gd),本探针分不清")
					% [_tok(bl, "dist", "?"), los])
		elif shots == 0 and wtype == 6:
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
		var why := _tok(gl, "reason", "?")
		if why == "rendezvous_timeout":
			_notes.append("相③ 榴弹那一半**未覆盖**:甲没能走到乙的贴脸距离内 ★ 成因未验证(同子弹那半边)")
		elif why == "no_grenade_launcher":
			_notes.append("相③ 榴弹那一半**未覆盖**:甲背包里没有榴弹发射器(初始武器随机发一把)—— 枪种抽签")
		else:
			_check(false, "相③ 榴弹没投出去:%s" % why)

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
		var ka := 0
		var ku := 0
		for r in kill_attr:
			ka = maxi(ka, int(kill_attr[r]))
			ku = maxi(ku, int(kill_unattr[r]))
		var bo_tags: Array = []
		var bo_max := 0
		for i in range(1, CLIENT_COUNT + 1):
			var bkl := _rec_line(_read_result("c%d" % i), "BACKOFF")
			if bkl == "":
				continue
			bo_tags.append(i)
			bo_max = maxi(bo_max, int(_tok(bkl, "n", "0")))
		if ka >= 1:
			_notes.append("相④ 真实交火击杀 %d 次(读数;这一栏**不是**「非空转」的证明 —— 见回退模式读数)" % ka)
		var bo_txt := ("**无端报告启用回退模式(REC BACKOFF)**" if bo_tags.is_empty()
				else "**回退模式(REC BACKOFF)被 %d 端启用(最大 n=%d),回合有一部分是它推的**"
						% [bo_tags.size(), bo_max])
		_notes.append("相④ 击杀来源:有归因(真实交火)%d 次 / 无归因(自杀等)%d 次 —— %s;这一半只作读数、不作绿断言"
				% [ka, ku, bo_txt])
		if ka == 0:
			_notes.append("相④ **真实交火击杀 0 次** —— 这一半未覆盖")
		_notes.append("相④ 第 1 局:%s" % round1[round1.keys()[0]])

	if r2.size() == CLIENT_COUNT and r1.size() == CLIENT_COUNT:
		var d := _grid_dims()
		if d == Vector2i.ZERO:
			pass
		else:
			var same_cell := 0
			var not_swapped := 0
			for r in r1:
				if not r2.has(r):
					continue
				if MazeGenerator.toroidal_dist(r1[r], r2[r], d.x, d.y) <= 1:
					same_cell += 1
				if SpawnChooser.side_of(r2[r], d) == SpawnChooser.side_of(r1[r], d):
					not_swapped += 1
			_check(same_cell == 0, "相④ ★ 第 2 局每人的出生点都不与第 1 局同处(实得 %d 人重复)" % same_cell)
			_check(not_swapped == 0, "相④ ★ 换边:第 2 局每人都换到了另一侧(没换侧 %d 人)" % not_swapped)
			_check(msync_seen == CLIENT_COUNT and msync_min >= 2,
					"相④ ★ 换边后各端都重拉了 match_sync(六端最少应答次数 %d,应 ≥2)" % msync_min)
	else:
		_check(false, "相④ 换边读数不全(第 2 局出生点 %d/6)" % r2.size())

	# ── 相⑤ 补:K 键自杀端到端(3v3 里 A 册收尾批才接上;此前是静默丢弃)──
	_check(k2_ok >= 1, "相⑤ 补 ★ K 键自杀在 3v3 走通(倒地 → 2s 复活;实得 %d 端报告读数 / %d 端走通)"
			% [k2_seen, k2_ok])

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
			# ★ 观察窗内的快照间隔:六端一起看。服务端停发必然同时命中所有在线客户端;只有一个客户端超时,那是那个进程自己卡了一下(本机同时跑 8 个 Godot),而「服务器还在发」这一命题恰好由其余端的读数证明(它们的窗口与它同一段墙钟)。
			#   故:≥2 端超 1s ⇒ 红(服务器停了);恰好 1 端 ⇒ 记读数并说明;全 ≤1s ⇒ 绿。
			obs_gaps.append([tag, float(_tok(ll, "obsmax", "0").replace("ms", ""))])
		_check(obs == CLIENT_COUNT - 1,
				"相⑤ ★ 其余 %d 端都观察到 role %d 已被移出对局(仍持续收快照、服务器不终局)"
				% [CLIENT_COUNT - 1, esc_role])
		var gap_txt := ""
		for pair in obs_gaps:
			gap_txt += "%s=%.0fms " % [pair[0], float(pair[1])]
		_check(obs_gaps.is_empty() or gap_max(obs_gaps) <= 1000.0,
				"相⑤ ★ 观察窗内快照连续(被观察的 %d 端最大间隔: %s;单端超 1s 也判红 —— 可能是该客户端自身停顿,也可能是服务器对**该 peer** 的定向投递异常,探针无法区分)"
				% [obs_gaps.size(), gap_txt])



func _kill_children() -> void:
	# ① 按 PID 杀全部子进程(首选):六个客户端是从临时端口连出去的,不占 worker 端口,只按端口杀根本杀不到它们 —— 留下的残留进程会敲下一跑、并攥着自己的 --log-file 让下一跑的清理静默失败(reconnect_probe 的 _kill_children 记过这两条后果)。
	var killed := 0
	for pid in _child_pids:
		if pid > 0 and OS.is_process_running(pid):
			OS.kill(pid)
			killed += 1
	print("PROBE: 按 PID 收尾 %d/%d 个子进程" % [killed, _child_pids.size()])
	_child_pids.clear()
	if _worker_port > 0:
		ProcUtil.kill_udp_port(_worker_port)


func _worker_log_path() -> String:
	if _rm == null or _worker_port <= 0:
		return ""
	return str(_rm.get("_launcher").call("log_path", _worker_port))


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


func _clean() -> bool:
	for i in range(1, CLIENT_COUNT + 1):
		for tag in ["c%d" % i]:
			for suffix in ["result", "log", "godotlog"]:
				var p := "user://%s%s.%s" % [RESULT_PREFIX, tag, suffix]
				if not FileAccess.file_exists(p):
					continue
				var err := DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
				if err != OK:
					print("PROBE: 删不掉上一跑的 %s(错误 %d)—— 多半是上一跑的进程还活着;"
							% [p, err] + "残留文件会被当成本跑的读数下判决,故直接退出")
					return false
	var wdir := DirAccess.open("user://logs")
	if wdir != null:
		for fn in wdir.get_files():
			if not fn.begins_with("worker_"):
				continue
			var wport := int(fn.trim_prefix("worker_").get_basename())
			if wport < WORKER_PORT_OUT or wport >= WORKER_PORT_OUT + 150:
				continue
			var werr := DirAccess.remove_absolute(ProjectSettings.globalize_path("user://logs/" + fn))
			if werr != OK:
				print("PROBE: 删不掉上一跑的 worker 日志 %s(错误 %d)—— 残留会被当成本跑的就绪读数" % [fn, werr])
				return false
	return true


func _dump() -> String:
	var out := ""
	for i in range(1, CLIENT_COUNT + 1):
		var tag := "c%d" % i
		out += "  [%s 引擎日志]\n%s\n" % [tag, _tail(_godot_log_path(tag), 25)]
	if _worker_port > 0:
		out += "  [worker:%d 引擎日志]\n%s\n" % [_worker_port, _tail(_worker_log_path(), 25)]
	return out



func _head_line(text: String) -> String:
	var ls := text.split("\n")
	return ls[0] if ls.size() > 0 else ""


func _rec_line(text: String, key: String) -> String:
	for l in text.split("\n"):
		if l.begins_with("REC " + key):
			return l
	return ""


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
	_checks += 1
	if ok:
		print("  OK  %s" % msg)
	else:
		_failures.append(msg)
		print("  FAIL %s" % msg)



func _run_client() -> void:
	var w: Node = load("res://tests/harness/team_match_watcher.gd").new()
	w.set("who", _who)
	w.set("idx", _idx)
	w.set("lobby_port", LOBBY_PORT)
	get_tree().root.add_child.call_deferred(w)
	print("PROBE[%s]: 客户端就绪,等观察者连大厅 %d" % [_who, LOBBY_PORT])
