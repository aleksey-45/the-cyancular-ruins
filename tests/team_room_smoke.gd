extends SceneTree

# 3v3 房间的**纯逻辑**冒烟(满员判据 / 最小空闲号 / 队满拒绝 / 互斥判定)
# + **源码级**断言 ⑥~⑨(⑥:team_join 里确实调了 team_next_role;⑦:3v3 建房页不得摆回基类那两个
#   设置区块 / 计数行不得写死容量 / 名单行配色两档共用;⑧:大厅入口指向的对局场景真的存在且挂了
#   脚本;⑨:set_my_team 接线 / 分队碰撞层契约 / 小地图两提供器同源 / 队色是比值 —— 见各节的
#   盲区说明)+ **像素级**断言 ⑩(`BODY_BASE_COLOR` 仍等于 `player.png` 的不透明众数色)。
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
	var script = load("res://server/lobby/lobby_rooms.gd")
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
	var room_src := ScanUtil.read("res://server/lobby/lobby_rooms.gd")
	if room_src.is_empty():
		fails.append("读不到 server/lobby_rooms.gd(接线断言无从成立)")
	elif not ScanUtil.code_only(room_src).contains("team_next_role(tr.player_role.values())"):
		fails.append("★ team_join 未调 team_next_role(tr.player_role.values())—— 判据函数仍在,生产那一行被换成内联写法了")
	# ⑦ 3v3 建房页的三条源码断言(**B 册 Task 7** 收的评审尾巴;与上面 ⑥ 同款:页面脚本要
	#    autoload,`-s` 里跑不动,故只能读源文本)。三条都是"听着无所谓、坏了不报错"的那类:
	#   ① 建房面板**不得**摆基类的两个设置区块 —— 3v3 用队色(个人色相是无效输入)、禁用武器
	#      不在 3v3 规则表里;而那两个勾选框**写的是 `Settings.pvp_disabled_weapons`**(1v1/大乱斗
	#      的设置项)⇒ 在 3v3 页勾一下会**连带改掉另两个模式**。
	#   ② 等待室计数行的分母必须引 `LobbyRooms.TEAM_ROLES/TEAM_SIZE` —— 写死 6/3 时
	#      "房间容量只有一个真值来源"这句自称就不成立,TEAM_SIZE 一改这行就撒谎且不报错。
	#   ③ 名单行配色必须**两档共用** `_row_color(...)`(一处定义 + 两处调用)——
	#      未选边档原先一律 C_TEXT,自己还没选边时那行不亮(只有 `(我)` 标记)。
	var lobby_src := ScanUtil.read("res://scenes/team_lobby.gd")
	if lobby_src.is_empty():
		fails.append("读不到 scenes/team_lobby.gd(建房页三条断言无从成立)")
	else:
		var lcode := ScanUtil.code_only(lobby_src)
		for bad_call in ["_add_weapon_grid(", "_add_hue_row("]:
			if lcode.contains(bad_call):
				fails.append("★ 3v3 建房页又摆回了 %s —— 该区块在 3v3 不成立(色相被队色覆盖;禁用武器写 Settings.pvp_disabled_weapons,会连带改掉 1v1/大乱斗)" % bad_call)
		var row_color_hits := lcode.count("_row_color(")
		if row_color_hits < 3:
			fails.append("★ 名单行配色没走公共的 _row_color(一处定义 + 两处调用,实际命中 %d 次)—— 未选边档的自己那行会不亮" % row_color_hits)
		if lcode.contains('"%d / 6 人'):
			fails.append("★ 等待室计数行把容量 6 写死了(应引 LobbyRooms.TEAM_ROLES —— TEAM_SIZE 一改这行就撒谎)")
	# ⑧ **悬空引用守卫**:`_enter_match_scene` 指向的对局场景必须真的存在(B 册 Task 6 创建)。
	# ★ 为什么值一条:那个 `call_deferred("change_scene_to_file", …)` 是**字符串路径**,文件被删/
	#   改名/写错时**什么都不报** —— 点了"开始"的六个客户端只会在换场那一刻静默停在原地(或更糟:
	#   报一条 change_scene 失败后留在等待室)。而这条死路要**真凑齐 6 人开局**才现形,那时它长得
	#   像"功能坏了"而不是"路径写错了"。先例:`tests/kh_l4_probe.gd` 对大乱斗入口那条
	#   `ResourceLoader.exists` 断言(同一条理由:数字符串会把"场景被删"读成绿)。
	# ★ 判据取**场景路径**而不是 `team_game` 字样(同 kh_l4 那条的说明):数"指向该场景的字符串"
	#   才等于数"入口个数",数字样会把注释/变量名一起命中。
	var entry := "res://scenes/" + "team" + "_game.tscn"
	if lobby_src.is_empty():
		fails.append("读不到 scenes/team_lobby.gd(悬空引用守卫无从成立)")
	else:
		var hits := ScanUtil.code_only(lobby_src).count(entry)
		if hits != 1:
			fails.append("★ 3v3 大厅入口应**恰好 1 处**指向 %s(实际 %d 处)—— 入口漏加/被删/指回别处" % [entry, hits])
		if not ResourceLoader.exists(entry):
			fails.append("★ 3v3 对局场景 %s 不存在(悬空引用:大厅那个 call_deferred 换场会静默失败)" % entry)
		# ★ 顺带钉住"指向的那个场景**真的挂上了** team_game.gd"(反向:路径在但内容是空气 ——
		#   比如只建了个空 .tscn)。读它的 ext_resource 而不是 `load()`:`-s` 阶段不该为了断言
		#   把整个对局场景(含 Level0 那一整棵)拖进内存。
		var tscn := FileAccess.get_file_as_string(entry) if FileAccess.file_exists(entry) else ""
		if not tscn.contains("scenes/team_game.gd"):
			fails.append("★ %s 没有挂 scenes/team_game.gd(空场景 = 换场成功但一行脚本都不跑)" % entry)
	# ⑨ 3v3 客户端的**两条"漏了不报错"的接线**(B 册 Task 6;判据取源码,理由同 ⑥⑦ ——
	#   对局场景要 autoload + 真链路,`-s` 里跑不动,真链路那份归 Task 8)。
	#   ★ ① `_hud.set_my_team(...)`:**唯一**会把"我是哪一队"告诉 HUD 的地方。漏了不报错,
	#     后果是 `_my_team` 恒 0 ⇒ 「本局胜利!」/「胜利!」**一次都不会出现**,赢的局报成输的
	#     (平局那一支不受影响 —— 它走 else)。★ 行为面另由 `hud_declarative_probe` 的第二段钉住
	#     (喂 `{winner: 我的队号}` 断言念「本局胜利!」+ 不写入时的反向对照);这里钉的是**生产
	#     到底调没调**,两半缺一不可:只钉 HUD 那一半,`team_game` 永不调用照样全绿。
	#   ★ ② 撞车队:本地玩家的 `collision_layer/mask` 与副本幽灵体的层必须按**队**设
	#     (`TeamHost.TEAM_ENEMY_LAYER`)。全 1v1/大乱斗式的"全员互挡"在 3v3 是**错的**,
	#     而错了的表现是 C2 每帧回滚(不像崩溃那样显眼)。
	#   ★ ⑤ 结算页接线(B 册 Task 7 收的评审尾巴:Task 5/6 的两条调用此前**零常驻覆盖**)。
	var tg_src := ScanUtil.read("res://scenes/team_game.gd")
	if tg_src.is_empty():
		fails.append("读不到 scenes/team_game.gd(Task 6 的两条接线断言无从成立)")
	else:
		var tcode := ScanUtil.code_only(tg_src)
		var apply_body := ScanUtil.func_body(tcode, "_apply_teams")
		if apply_body.is_empty():
			fails.append("★ team_game 里找不到 _apply_teams 的函数体(接线断言无从成立)")
		elif not apply_body.contains("set_my_team("):
			fails.append("★ team_game._apply_teams 没调 _hud.set_my_team(队伍表到达后必须写入我队队号;漏了不报错,赢的局会被 HUD 报成输的)")
		elif not apply_body.contains("_team_of_role(PvpSession.role)"):
			fails.append("★ team_game._apply_teams 的 set_my_team 入参不是 _team_of_role(PvpSession.role)(写死队号/拿 role 当队号都会在 role 与队号错开时报错胜负)")
		# ★ 判据收在**函数体**上而不是全文件 `contains`:全文件里"常量出现过"太容易满足 ——
		#   把 1 队那一支换成"全员互挡"(`| 2`)、或把队 B 的层写死成 16,常量本体照旧在文件里,
		#   全文件断言一条都不会红。契约的四个要点(见 TeamHost._apply_team_layers 那张表):
		var coll_body := ScanUtil.func_body(tcode, "_apply_team_collision")
		if coll_body.is_empty():
			fails.append("★ team_game 里找不到 _apply_team_collision 的函数体(撞车队契约断言无从成立)")
		else:
			if not coll_body.contains("collision_layer = 2"):
				fails.append("★ _apply_team_collision 没给 1 队设身体层 2(契约表:1 队 layer=2 / mask=21)")
			if not coll_body.contains("& ~2"):
				fails.append("★ _apply_team_collision 没给 1 队**抹掉**玩家层位(写成 `|= 2` 就是全员互挡 = 队友也挡我;服务器那边抹了 → 每帧回滚)")
			# ★★ 判据必须是**那一行赋值本身**(`collision_layer = TeamHost.TEAM_ENEMY_LAYER`),
			#   不能是"常量在函数体里出现过" —— 生产里这个常量出现**两次**(2 队的身体层 + 1 队
			#   掩码里的"挡住队 B"位),所以"把 2 队的层写死成 16"(1 队那处仍留常量)、
			#   "删掉整个 2 队分支"、两种实现都能把"出现过"喂绿,而它们正是这句话点名的变异。
			#   钉整行赋值后:写死 16 → 红;删掉 2 队分支 → 红。
			if not coll_body.contains("collision_layer = TeamHost.TEAM_ENEMY_LAYER"):
				fails.append("★ _apply_team_collision 没给 2 队设 `collision_layer = TeamHost.TEAM_ENEMY_LAYER`(写死 16 / 删掉 2 队分支都在这儿红;只数'常量在体内出现过'守不住 —— 它在 1 队那一行也出现)")
			# ★ 两条一起要:`set_ghost_layer(` 单独一条**不够** —— 写成 `set_ghost_layer(2)`
			#   (副本幽灵体恒在玩家层 = 队友副本也挡我)时它照样在,而那一行正是"按**队**设层"
			#   与"恒在玩家层"的全部差别(实测:只钉前一条时这条变异**照样绿**)。
			if not (coll_body.contains("set_ghost_layer(") and coll_body.contains("_ghost_layer_of(")):
				fails.append("★ _apply_team_collision 没给副本幽灵体按**队**配层(必须 set_ghost_layer(_ghost_layer_of(...));写成 set_ghost_layer(2) 就是队友副本也挡我 → C2 每帧回滚,不报错)")
		# ★★ `_ghost_layer_of` 的两支**都要钉**:它体内这个常量只出现**一次**,故"按队"那个
		#   分支被删(改成恒返 `TeamHost.TEAM_ENEMY_LAYER`)时"出现过"照样绿 —— 而那正是
		#   "队友副本也挡我 → C2 每帧回滚"的实现。判据 = 按队判别 + 1 队那一支 + 常量,三样都要。
		var ghost_body := ScanUtil.func_body(tcode, "_ghost_layer_of")
		if ghost_body.is_empty():
			fails.append("★ team_game 里找不到 _ghost_layer_of 的函数体(副本按队配层断言无从成立)")
		elif not (ghost_body.contains("_team_of_role(") and ghost_body.contains("return 2")
				and ghost_body.contains("TeamHost.TEAM_ENEMY_LAYER")):
			fails.append("★ team_game 的 _ghost_layer_of 不是**按队两支**(必须:队号 1 → 层 2,否则 → TeamHost.TEAM_ENEMY_LAYER。恒返 TEAM_ENEMY_LAYER = 队友副本也挡我 → C2 每帧回滚,不报错)")
		# ★★ 表外 / 队伍表未到时的**落层**必须与服务端"什么都不配"(保持 `_ready` 里那句层 2)
		#   对齐。旧实现把"未知"当成了**队 2**:客户端幽灵体层 16、服务端层 2 ⇒ 队 2 的玩家
		#   在服务端**会**被挡住、在客户端**不会** ⇒ C2 每帧分歧(不报错)。
		#   ★ 上面那一组"按队两支"**区分不了**这两种写法(旧的一行三元三样全含)——
		#     鉴别点在**结构**:新形状是 `match` + 两支 + **match 之外**的兜底 `return 2`,
		#     故 `return 2` 出现**两次**,而旧写法只有一次。
		if ghost_body.count("return 2") < 2:
			fails.append("★ _ghost_layer_of 丢了表外兜底:未知队号必须落到层 2(与服务端'什么都不配'对齐);旧写法把未知当队 2 ⇒ 两端层不一致 ⇒ C2 每帧分歧,不报错")
		if not ghost_body.contains("match"):
			fails.append("★ _ghost_layer_of 的形状不对:必须是 `match _team_of_role(...)` + 两支 + match **之外**的 `return 2`(GDScript 的 match 体内 `continue` 是 fall-through,兜底写进 match 会静默多跑一支)")
		# ③ 小地图两个提供器必须**共用同一套遍历/过滤**(`_minimap_entries()`),不能各写一份 `for`。
		#    `ui/minimap.gd` 是**按下标**对应颜色(`_other_dots[i].color = cols[i]`)——
		#    两个数组错位一格就是"队友点画成敌人色",**不报错只误导人**;而错位最容易发生在
		#    "某个副本已 queue_free、尚未从 `_replicas` 抹掉"那个窗口里(一处带守卫、另一处不带
		#    就当场错一格)。故判据是"两处都只从同一个共同遍历取数"。
		var others_body := ScanUtil.func_body(tcode, "_minimap_others")
		var colors_body := ScanUtil.func_body(tcode, "_minimap_colors")
		if not (others_body.contains("_minimap_entries()") and colors_body.contains("_minimap_entries()")):
			fails.append("★ 小地图两个提供器没共用 _minimap_entries()(各写一份 for = 过滤条件两份;某副本已 free 未摘时两数组错位一格 → 队友点画成敌人色,不报错)")
		# ④ 队色染到**身体**上必须是 modulate **比值**(队色 / 本体主色),不能直接乘队色。
		#    ★ 直接乘是 brief 给的初版:蓝身体 `#639BFF` 乘上**那版队色**(橙,现已改口径为偏绿的青)
		#      实测是 `#636073` —— 一坨灰紫,"一眼看出谁是队友"直接落空
		#      (实测图 `.superpowers/sdd/_t6_tint2.png` 第②列)。
		#      比值则精确等于队色本身(实测逐字节相等),与头顶 ID / 小地图点位**同源同一个常量**。
		#    ★ 本档只钉**机制**(公式是比值);比值的**分母**(`BODY_BASE_COLOR` 那个数值)归 ⑩。
		var tint_code := ScanUtil.code_only(ScanUtil.read("res://scenes/pvp_match_client.gd"))
		var tint_body := ScanUtil.func_body(tint_code, "_apply_tint")
		if tint_body.is_empty():
			fails.append("读不到 pvp_match_client.gd 的 _apply_tint 函数体(队色染色机制断言无从成立)")
		elif not (tint_body.contains("color_override.r / BODY_BASE_COLOR.r")
				and tint_body.contains("color_override.b / BODY_BASE_COLOR.b")):
			fails.append("★ 队色染色被改回「直接乘队色」了(蓝身体乘橙 = 灰紫,队色认不出;必须是 队色/本体主色 的比值)")
		# ⑤ 结算页接线(B 册 Task 7)。挂载/离场本身**收在基类**(`PvpMatchClient._show_result`
		#   / `_leave_to_main_menu`),本文件只负责"调了"。两条都是"删了/写反了不报错"的那类:
		#   ① MATCH_OVER 块里必须调 `_show_result()` —— 删了不报错,只是**结算页永不出现**
		#      (玩家停在对局里,既没有结算页也没有回主菜单的路)。判据取"**那个分支里**有调用",
		#      不是"文件里出现过" —— 后者对"把调用挪出分支/挪成无条件"恒绿。
		#   ② `_build_result_payload()` 折载荷时 `_names` 与 `_teams` 的**实参顺序**不得写反。
		#      ★★ 这是本计划**最安静的错法**:`for_team(round, names, teams, my_team)` 的前三个
		#      实参**都是 Dictionary**,写反**照样编译、所有常驻测试照样绿**,只有榜渲染成
		#      乱码/空表。★ 判据取"**每个位置上是什么**"(「两个名字都出现过」对换位**恒绿**)。
		#   ★ 这正是"只扫基类那两条常驻守卫"照不到的那一半(它们管挂载/离场,不管谁来调)。
		var tcv := ScanUtil.code_view(tg_src)
		var cv_lines := tcv.split("\n")
		var i_mo := -1
		for k in range(cv_lines.size()):
			if cv_lines[k].contains("state == 3"):
				i_mo = k
				break
		if i_mo < 0:
			fails.append("★ team_game 里找不到 MATCH_OVER 分支(`state == 3`)—— 结算页接线断言无从成立")
		elif not _block_after(cv_lines, i_mo).contains("_show_result()"):
			fails.append("★ team_game 的 MATCH_OVER 块没调 _show_result()(退场路径被删了?玩家会停在对局里,没有结算页也没有回主菜单的路)")
		var payload_body2 := ScanUtil.func_body(tcode, "_build_result_payload")
		if payload_body2.is_empty():
			fails.append("★ team_game 里找不到 _build_result_payload 的函数体(结算页载荷断言无从成立)")
		else:
			var call_at := payload_body2.find("MatchResultPayload.for_team(")
			if call_at < 0:
				fails.append("★ team_game._build_result_payload 没调 MatchResultPayload.for_team(3v3 的结算页载荷没了)")
			else:
				var open := payload_body2.find("(", call_at)
				var close := ScanUtil.match_paren(payload_body2, open)
				if close < 0:
					fails.append("★ MatchResultPayload.for_team 的调用括号配不上(实参顺序断言无从成立)")
				else:
					var args := ScanUtil.split_args(payload_body2.substr(open + 1, close - open - 1))
					if args.size() < 4:
						fails.append("★ MatchResultPayload.for_team 的实参只有 %d 个(应 4 个:round_state / names / teams / my_team)" % args.size())
					else:
						if not args[1].contains("_names"):
							fails.append("★ for_team 第 2 个实参不是 _names(签名是 round_state, names, teams, my_team;★ 前三个都是 Dictionary ⇒ 写反照样编译、所有常驻测试照样绿,只有榜渲染成乱码/空表)")
						if not args[2].contains("_teams"):
							fails.append("★ for_team 第 3 个实参不是 _teams(同上:names 与 teams 写反是**静默**的)")
	# ⑩ `BODY_BASE_COLOR` 的**数值**时效性 —— 与 ⑨④ 的"机制"那一半互补(两半缺一不可)。
	# ★ ⑨④ 钉"公式是**比值**";本档钉那个比值的**分母**仍等于 `player.png` 的主色。换素材忘了
	#   重测 `BODY_BASE_COLOR` 时:公式照旧对、⑨④ 照旧绿,只有身体**整体偏色** —— 而六个人
	#   一起偏、仍然分得出谁是谁 ⇒ 这是本批最容易漏的一档(评审原话)。
	# ★ 复测办法与 `pvp_match_client.gd` 该常量注释里的那条**逐字同源**:按 alpha > 200 过滤
	#   `player.png` 的全部像素,取出现次数最多的那个 RGB。
	# ★ 渲染侧另有一份等价断言(`hue_tint_probe` 守卫 D,那里顺带还钉了 `C_TEAM_A` 同色)。
	#   那条**必须真渲染**(headless 下 `get_viewport().get_texture()` 返 null ⇒ 整条探针在
	#   截图那一步早退,守卫 D 根本跑不到),故本档不是它的复制品,而是它的 **headless 半边**:
	#   两种跑法各自够不到对方能跑的场景。
	var pmc_script = load("res://scenes/pvp_match_client.gd")
	if pmc_script == null or pmc_script.reload() != OK:
		# 同 ⑥⑦⑧⑨ 的 load 手法:失败不抛错、给一行 FAIL(否则 `-s` 下走不到 quit() → 挂到 timeout)
		fails.append("★ 加载/编译 scenes/pvp_match_client.gd 失败(本体主色的数值断言无从成立)")
	else:
		var pmc_consts: Dictionary = pmc_script.get_script_constant_map()
		if not pmc_consts.has("BODY_BASE_COLOR"):
			fails.append("★ scenes/pvp_match_client.gd 里没有常量 BODY_BASE_COLOR")
		else:
			var base_key := _rgb8(pmc_consts["BODY_BASE_COLOR"])
			# ★ 读**原始 PNG 字节**再解码,不用 `Image.load_from_file`(那条会打一条
			#   "Loaded resource as image file, this will not work on export" 的引擎 WARNING
			#   —— 本档要在 `-s`/headless 下干净地跑,警告会淹掉它自己的 FAIL 行)。
			var png_bytes := FileAccess.get_file_as_bytes("res://assets/textures/player.png")
			var png := Image.new()
			if png_bytes.is_empty() or png.load_png_from_buffer(png_bytes) != OK:
				fails.append("★ 读不出/解不开 assets/textures/player.png(本体主色的数值断言无从成立)")
			else:
				var hist: Dictionary = {}
				for y in range(png.get_height()):
					for x in range(png.get_width()):
						var px := png.get_pixel(x, y)
						if px.a > 200.0 / 255.0:
							var key := _rgb8(px)
							hist[key] = int(hist.get(key, 0)) + 1
				var mode_key := Vector3i(-1, -1, -1)
				var mode_n := 0
				for k in hist:
					if int(hist[k]) > mode_n:
						mode_n = int(hist[k])
						mode_key = k
				if mode_key.x < 0:
					fails.append("★ player.png 里没有一个不透明像素(本体主色的数值断言无从成立)")
				elif mode_key != base_key:
					fails.append(("★ player.png 的不透明众数色 #%02X%02X%02X ≠ BODY_BASE_COLOR #%02X%02X%02X"
							+ " —— 换素材后没重测本体主色,队色(比值 = 队色 / 主色)会**整体偏**而没人发现"
							+ "(仍分得出谁是谁,故最容易漏)")
							% [mode_key.x, mode_key.y, mode_key.z, base_key.x, base_key.y, base_key.z])
	if fails.is_empty():
		print("TEAM ROOM SMOKE: ALL-OK")
		quit(0)
	else:
		print("TEAM ROOM SMOKE: FAIL")
		for f in fails:
			print("  - %s" % f)
		quit(1)


# 颜色 → 8bit 量纲的三元组(**逐字节**口径:比对"这个 RGB"而不是浮点色,免得被 eps 放走一格)。
# `Color` 的 8 位分量来回换算在 GDScript 里是精确的(`99.0/255.0` 与 `roundi(x*255.0)` 互逆),
# 故这里不需要容差;真需要容差的话说明素材已经被改过了,那正是本断言要报的事。
func _rgb8(c: Color) -> Vector3i:
	return Vector3i(roundi(c.r * 255.0), roundi(c.g * 255.0), roundi(c.b * 255.0))


# 某行的缩进宽度(制表符/空格都算一列)。
# ⚠ 入参必须是**保留缩进**的视图(`ScanUtil.code_view`),`code_only` 会 strip_edges ⇒ 恒 0。
func _indent_of(line: String) -> int:
	var n := 0
	while n < line.length() and (line[n] == "\t" or line[n] == " "):
		n += 1
	return n


# 第 i 行**所属块**的正文:紧随其后、缩进严格更大的那些行(给"某分支里必须调 X"类断言用 ——
# 判据取"那个分支里",不是"文件里出现过";后者对"把调用挪出分支"恒绿)。
func _block_after(lines: PackedStringArray, i: int) -> String:
	if i < 0 or i >= lines.size():
		return ""
	var base := _indent_of(lines[i])
	var out: Array[String] = []
	for k in range(i + 1, lines.size()):
		if _indent_of(lines[k]) <= base:
			break
		out.append(lines[k])
	return "\n".join(out)
