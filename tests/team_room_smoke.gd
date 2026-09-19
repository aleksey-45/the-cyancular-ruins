extends SceneTree

# 3v3 房间的**纯逻辑**冒烟(满员判据 / 最小空闲号 / 队满拒绝 / 互斥判定)
# + 一条**源码级接线断言**(⑥:team_join 里确实调了 team_next_role —— 见该节的盲区说明)。
# 跑法: "$GODOT" --headless --path . -s res://tests/team_room_smoke.gd
# 通过 = `TEAM ROOM SMOKE: ALL-OK` 退出 0。
#
# ═══ 为什么需要它 ═══
# ★ `-s` 阶段 autoload 不存在,故这里**只测不碰 autoload 的纯函数**:把判据收成
#   `LobbyRooms` 的静态函数,再由 RPC handler 调用(单一来源)。判据错了的表现是静默的:
#   "两队人数不等也能开"会让 3v3 变成 4v2。
# ★ 空载守卫:load 失败立刻 quit(1),否则抛错走不到 quit() → 进程永久挂起。
#   ★ 第二层:`-s` 下对 GDScript 对象调用**不存在**的函数是运行时报错 + 当前函数当场中止
#     (同样走不到 quit() → 同样挂起)。故先按名字点名确认判据都在,缺哪个就一行 FAIL 退 1。
#     红线阶段靠它给出干净的红,而不是"卡住到 timeout"。
#
# ★★ 本文件**不得出现 `LobbyRooms` 这个全局类名**(只能用 `load()` 拿到的脚本对象):
#   写全局类名 = 本脚本对它产生**静态依赖** → 编译本脚本时会连带编译 `lobby_rooms.gd`,
#   而那个文件在 `_enter_tree` 里引用了 autoload `NetBus` —— `-s` 阶段 autoload 未注册,
#   于是整条链编不过:`Identifier not found: NetBus` + `Failed to compile depended scripts`,
#   连本脚本自己的 `_initialize` 都进不去(实测:进程挂到 timeout)。`load()` 走的是动态路径,
#   随后 `reload()` 判编译结果 —— 与 `room_sweep_smoke` 加载 room_manager.gd 同一个手法。

func _initialize() -> void:
	var script = load("res://server/lobby_rooms.gd")
	# ★ load() **解析失败时不返回 null**(给回的是那个坏掉的脚本对象)→ 判据用 reload() 的错误码
	#   (「源码文本全对、但 GDScript 编不过」这一档只有 reload 照得出来)。
	if script == null or script.reload() != OK:
		print("TEAM ROOM SMOKE: FAIL(加载/编译 lobby_rooms.gd 失败)")
		quit(1)
		return
	# ★ 点名守卫的**能力边界**(别照抄到别处当通用手段):`Object.has_method()` 对**脚本资源**
	#   只报 ClassDB 方法与 `static func` —— 非 static 的成员函数/内部类方法它**看不见**。
	#   (仓内两处实测记载:`tests/ai_input_source_smoke.gd` 与 `tests/lib/scan_util.gd`。)
	#   故下面这三个目标**当前必须全是 static** 才对;哪天把某个判据改成非 static,这里会给出
	#   一条**误导性**的"未声明 X" FAIL(脚本其实声明了,只是 has_method 照不到)—— 那时改法
	#   是换判据(如文本断言),不是把判据删掉。
	for fn_name in ["team_ready", "team_can_join", "team_next_role"]:
		if not script.has_method(fn_name):
			print("TEAM ROOM SMOKE: FAIL(lobby_rooms.gd 未声明 %s)" % fn_name)
			quit(1)
			return
	var fails: Array[String] = []
	# ① 满员判据:两队各 3 人才算准备好
	var ready := {1: [1, 2, 3], 2: [5, 6, 7]}   # 队号 -> 该队 role 列表
	if not script.team_ready(ready):
		fails.append("两队各 3 人应当 ready")
	var lopsided := {1: [1, 2, 3, 4], 2: [5, 6]}
	if script.team_ready(lopsided):
		fails.append("★ 4v2 不得 ready(满 6 人才开)")
	var half := {1: [1, 2, 3]}
	if script.team_ready(half):
		fails.append("只有一队不得 ready")
	# ② 选边闸门:该队满 3 人 → 拒绝
	if script.team_can_join({1: [1, 2, 3], 2: []}, 1):
		fails.append("★ 1 队满 3 人后不得再加入")
	if not script.team_can_join({1: [1, 2, 3], 2: []}, 2):
		fails.append("2 队有空位应当允许")
	# ③ 最小空闲号:role 号**有空洞**时取最小未占用号(与 royale 同款:有人退不重排)。
	#    ★ 判据不是"人数 + 1" —— 那是"编号恒连续"的假设,有人退出留空洞时会撞上仍在房里的高号。
	if script.team_next_role([1, 2, 4]) != 3:
		fails.append("★ 最小空闲号错了:占用 [1,2,4] 应得 3(取 max+1 会得 5)")
	if script.team_next_role([]) != 1:
		fails.append("空房的首个 role 应当是 1")
	if script.team_next_role([2, 3, 4, 5, 6]) != 1:
		fails.append("★ 1 号退房留出空洞后应当能复用 1(最小空闲号,不是最大号 + 1)")
	# ④ 互斥判定:两张方向都要对 —— 房内命中、房外**不得**命中。
	#    只查一头会在反向出事:恒 true 会让**所有**玩家建 1v1/大乱斗房都被拒(全域误伤),
	#    恒 false 则互斥形同虚设(同一个 peer 同时挂在两张表里 → 双 go_match 互相覆盖)。
	# 实例与内嵌类都从**脚本对象**上去取(见文件头的静态依赖警告):
	#   内嵌类在 `get_script_constant_map()` 里(实测键含 Room/RoyaleRoom/TeamRoom)。
	var lrm = script.new()
	var team_room_cls = script.get_script_constant_map()["TeamRoom"]
	var tr = team_room_cls.new()
	tr.code = "0001"
	tr.players.append(7)
	tr.player_role[7] = 1
	lrm.team_rooms["0001"] = tr
	if lrm.team_room_of(7) != tr:
		fails.append("team_room_of(房内 peer) 应当命中该房")
	if not lrm._in_team_room(7):
		fails.append("_in_team_room(房内 peer) 应当为 true(反向互斥就靠它)")
	if lrm.team_room_of(8) != null:
		fails.append("★ team_room_of(房外 peer) 应当返回 null(否则全体玩家都被判成「已在 3v3 房」)")
	if lrm._in_team_room(8):
		fails.append("★ _in_team_room(房外 peer) 不得为 true(会误伤 1v1/大乱斗建房)")
	# ⑤ `_by_team` 的分组(判据的入参形状**只在这一处**构造 —— 它错了,`team_ready` 再对也没用)
	var tr2 = team_room_cls.new()
	tr2.team_of = {1: 1, 2: 2, 3: 1, 4: 2, 5: 1, 6: 2}
	if not lrm.team_room_ready(tr2):
		fails.append("3/3 分队的房应当 ready(team_room_ready 的分组错了?)")
	var tr3 = team_room_cls.new()
	tr3.team_of = {1: 1, 2: 2, 3: 1, 4: 2, 5: 1, 6: 1}
	if lrm.team_room_ready(tr3):
		fails.append("★ 4v2 的房不得 ready(team_room_ready 若只看人数就中招)")
	var tr4 = team_room_cls.new()
	tr4.team_of = {1: 1, 2: 2, 3: 1, 4: 2, 5: 1}   # 第 6 人还没选边 → 该 role 不在 team_of 里
	if lrm.team_room_ready(tr4):
		fails.append("★ 有 1 人未选边不得 ready(未选边的 role 不在 team_of 里,别把它算进任何一队)")
	lrm.free()
	# ⑥ team_join 里**那一行接线**本身 —— 判据函数测对了 ≠ 生产调的是它。
	# ★ 这是本文件形态自带的盲区:①~⑤ 全在测静态判据本身,而 handler 要 autoload、`-s` 里跑不动;
	#   于是把 `team_next_role(tr.player_role.values())` 换成内联的「人数 + 1」,上面五条**依旧全绿**,
	#   而 role 分配已经在"有人退过"的房里出错(撞上仍在房里的高号,同一个 role 双份占用)。
	#   故补一条便宜的**源码级**断言,用剥注释视图(注释里出现同形文本不算数)。
	var room_src := ScanUtil.read("res://server/lobby_rooms.gd")
	if room_src.is_empty():
		fails.append("读不到 server/lobby_rooms.gd(接线断言无从成立)")
	elif not ScanUtil.code_only(room_src).contains("team_next_role(tr.player_role.values())"):
		fails.append("★ team_join 未调 team_next_role(tr.player_role.values())—— 判据函数仍在,生产那一行被换成内联写法了")
	if fails.is_empty():
		print("TEAM ROOM SMOKE: ALL-OK")
		quit(0)
	else:
		print("TEAM ROOM SMOKE: FAIL")
		for f in fails:
			print("  - %s" % f)
		quit(1)
