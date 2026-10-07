extends SceneTree

# 3v3 组队房间纯逻辑冒烟测试：
# 验证 3v3 房间的选边逻辑、队伍人数上限、最小空闲号分配以及模式互斥判定。
# 运行方式：
#   "$GODOT" --headless --path . -s res://tests/smoke/team_room_smoke.gd

func _initialize() -> void:
	var script = load("res://server/lobby/lobby_rooms.gd")
	# - load() 解析失败时不返回 null(给回的是那个坏掉的脚本对象) -> 判定条件用 reload() 的错误码
	#   (「源码文本全对、但 GDScript 编不过」这一档只有 reload 照得出来)。
	if script == null or script.reload() != OK:
		print("TEAM ROOM SMOKE: FAIL(加载/编译 lobby_rooms.gd 失败)")
		quit(1)
		return
	# - 明确提示防御性校验的能力边界(别照抄到别处当通用手段):`Object.has_method()` 对脚本资源
	#   只报 ClassDB 方法与 `static func` —— 非 static 的成员函数/内部类方法它看不见。
	#   (仓内两处实测记载:`tests/smoke/ai_input_source_smoke.gd` 与 `tests/lib/scan_util.gd`。)
	#   故下面这三个目标当前必须全是 static 才对;哪天把某个判定条件改成非 static,这里会给出
	#   一条误导性的"未声明 X" FAIL(脚本其实声明了,只是 has_method 无法覆盖检测)—— 那时改法
	#   是换判定条件(如文本断言),不是把判定条件删掉。
	for fn_name in ["team_ready", "team_can_join", "team_next_role"]:
		if not script.has_method(fn_name):
			print("TEAM ROOM SMOKE: FAIL(lobby_rooms.gd 未声明 %s)" % fn_name)
			quit(1)
			return
	var fails: Array[String] = []
	# ① 满员验收标准：两队各 3 人才算准备好
	var ready := {1: [1, 2, 3], 2: [5, 6, 7]}   # 队号 -> 该队 role 列表
	if not script.team_ready(ready):
		fails.append("两队各 3 人应当 ready")
	var lopsided := {1: [1, 2, 3, 4], 2: [5, 6]}
	if script.team_ready(lopsided):
		fails.append("★ 4v2 不得 ready(满 6 人才开)")
	var half := {1: [1, 2, 3]}
	if script.team_ready(half):
		fails.append("只有一队不得 ready")
	# ② 选边门控前置校验:该队满 3 人 -> 拒绝
	if script.team_can_join({1: [1, 2, 3], 2: []}, 1):
		fails.append("★ 1 队满 3 人后不得再加入")
	if not script.team_can_join({1: [1, 2, 3], 2: []}, 2):
		fails.append("2 队有空位应当允许")
	# ③ 最小空闲号:role 号有空洞时取最小未占用号(与 royale 相同处理逻辑:有人退不重排)。
	#    - 判定条件不是"人数 + 1" —— 那是"编号恒连续"的假设,有人退出留空洞时会撞上仍在房里的高号。
	if script.team_next_role([1, 2, 4]) != 3:
		fails.append("★ 最小空闲号错了:占用 [1,2,4] 应得 3(取 max+1 会得 5)")
	if script.team_next_role([]) != 1:
		fails.append("空房的首个 role 应当是 1")
	if script.team_next_role([2, 3, 4, 5, 6]) != 1:
		fails.append("★ 1 号退房留出空洞后应当能复用 1(最小空闲号,不是最大号 + 1)")
	# ④ 互斥判定:两张方向都要对 —— 房内命中、房外不得命中。
	#    只查一头会在反向出事:恒 true 会让所有玩家建 1v1/大乱斗房都被拒(全域误伤),
	#    恒 false 则互斥形同虚设(同一个 peer 同时挂在两张表里 -> 双 go_match 互相覆盖)。
	# 实例与内嵌类都从脚本对象上去取(见文件头的静态依赖警告):
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
	# ⑤ `_by_team` 的分组(判定条件的入参形状只在这一处构造 —— 它错了,`team_ready` 再对也没用)
	var tr2 = team_room_cls.new()
	tr2.team_of = {1: 1, 2: 2, 3: 1, 4: 2, 5: 1, 6: 2}
	if not lrm.team_room_ready(tr2):
		fails.append("3/3 分队的房应当 ready(team_room_ready 的分组错了?)")
	var tr3 = team_room_cls.new()
	tr3.team_of = {1: 1, 2: 2, 3: 1, 4: 2, 5: 1, 6: 1}
	if lrm.team_room_ready(tr3):
		fails.append("★ 4v2 的房不得 ready(team_room_ready 若只看人数就中招)")
	var tr4 = team_room_cls.new()
	tr4.team_of = {1: 1, 2: 2, 3: 1, 4: 2, 5: 1}   # 第 6 人还没选边 -> 该 role 不在 team_of 里
	if lrm.team_room_ready(tr4):
		fails.append("★ 有 1 人未选边不得 ready(未选边的 role 不在 team_of 里,别把它算进任何一队)")
	lrm.free()
	# ⑥ team_join 里那一行接线本身 —— 判定条件函数测对了 ≠ 生产调的是它。
	# - 这是本文件形态自带的盲区:①~⑤ 全在测静态判定条件本身,而 handler 要 autoload、`-s` 里跑不动;
	#   于是把 `team_next_role(tr.player_role.values())` 换成内联的「人数 + 1」,上面五条依旧全部断言通过,
	#   而 role 分配已经在"有人退过"的房里出错(撞上仍在房里的高号,同一个 role 双份占用)。
	#   故补一条便宜的源码级断言,用剥注释视图(注释里出现同形文本不算数)。
	var room_src := ScanUtil.read("res://server/lobby/lobby_rooms.gd")
	if room_src.is_empty():
		fails.append("读不到 server/lobby_rooms.gd(接线断言无从成立)")
	else:
		# - 2026-10-02 降精度:原钉整份文件含逐字 `team_next_role(tr.player_role.values())`
		#   —— 接收者/入参表达式换个等价写法就测试误报。改扫 team_join 的函数体、只要求它调了
		#   `team_next_role(`(问的是同一件事:那行接线还在)。要拦的变异:把接线换成内联的
		#   「人数 + 1」—— 判定条件函数仍在,但"有人退过房"的 role 分配会撞上仍在房里的高号。
		if not ScanUtil.func_body(ScanUtil.code_only(room_src), "team_join").contains("team_next_role("):
			fails.append("★ team_join 未调 team_next_role(...)—— 判据函数仍在,生产那一行被换成内联写法了(有人退过房的 role 分配会撞号)")
	# ⑦ 3v3 的形态源码断言(统一大厅之后口径改判:三页合一后不再是"3v3 页不摆那两块",
	#    而是"那两块在 3v3 下被按模式收起")。与上面 ⑥ 相同处理逻辑:页面脚本要 autoload,`-s` 里跑不动,
	#    只能读源文本。三条都是"听着无所谓、坏了不报错"的那类:
	#   ① 建房弹层的禁用武器行 / 等待室角色颜色行必须按模式收起:判定条件钉赋值那一行的形状
	#      (`<行键>.visible = not is_team`)。-  只看"函数体里出现过 `"weapons"`"是不够的 ——
	#      无条件设置可见性(`.visible = true`)同样含那个子串,而那时这条就证明不了
	#      "3v3 会隐藏它"(2026-10-03 评审核出:那是"防御性校验的声称比它实际强")。
	#      行键的勾选框写的是 `Settings.pvp_disabled_weapons`(1v1/大乱斗的设置项) -> 
	#      3v3 下没收起的话,勾一下会连带改掉另两个模式。
	#      - 上限照实登记:这是源码形状判定条件,不证明运行时真的收起;运行那一半由
	#      `lobby_create_form_probe` ⑤/⑥/⑩ 与 `lobby_wait_room_probe` ⑭ 的行为级断言保证。
	#   ② 等待室计数行的分母必须引 `LobbyRooms.TEAM_ROLES/TEAM_SIZE` —— 写死 6/3 时
	#      "房间容量只有一个真值来源"这句自称就不成立,TEAM_SIZE 一改这行就撒谎且不报错。
	#   ③ 名单行必须两个档位共用同一个行构造 `_roster_row(...)`(一处定义 + 两处调用)——
	#      未选边档原先一律 C_TEXT,自己还没选边时那行不亮(只有 `(我)` 标记)。
	var lobby_src := ScanUtil.read("res://scenes/mp_lobby.gd")
	if lobby_src.is_empty():
		fails.append("读不到 scenes/mp_lobby.gd(3v3 形态三条断言无从成立)")
	else:
		var lcode := ScanUtil.code_only(lobby_src)
		if not _hide_line_present(ScanUtil.func_body(lcode, "_apply_create_form"), '"weapons"'):
			fails.append("★ 建房弹层未按模式收起禁用武器行(`_apply_create_form` 里找不到 `<行键>.visible = not is_team` 那一行)—— 3v3 勾一下会连带改掉 1v1/大乱斗 的 Settings.pvp_disabled_weapons")
		if not _hide_line_present(ScanUtil.func_body(lcode, "_show_wait_room"), "_wait_hue"):
			fails.append("★ 等待室未按模式收起角色颜色行(`_show_wait_room` 里找不到 `_wait_hue.visible = not is_team` 那一行)—— 3v3 用队色,个人色相是无效输入")
		if not lcode.contains("LobbyRooms.TEAM_ROLES"):
			fails.append("★ 等待室计数行没引 LobbyRooms.TEAM_ROLES —— 写死 6 时 TEAM_SIZE 一改这行就撒谎")
		if lcode.contains('"%d / 6 人'):
			fails.append("★ 等待室计数行把容量 6 写死了(应引 LobbyRooms.TEAM_ROLES —— TEAM_SIZE 一改这行就撒谎)")
		var roster_hits := lcode.count("_roster_row(")
		if roster_hits < 3:
			fails.append("★ 名单行没走公共的 _roster_row(一处定义 + 两处调用,实际命中 %d 次)—— 未选边档的自己那行会不亮" % roster_hits)
	# ⑧ 悬空引用防御性校验:`_enter_match_scene` 指向的对局场景必须真的存在(B 册 Task 6 创建)。
	# - 为什么值一条:那个 `call_deferred("change_scene_to_file", …)` 是字符串路径,文件被删/
	#   改名/写错时什么都不报 —— 点了"开始"的六个客户端只会在换场那一刻静默停在原地(或更糟:
	#   报一条 change_scene 失败后留在等待室)。而这条死路要真凑齐 6 人开局才暴露异常,那时它长得
	#   像"功能坏了"而不是"路径写错了"。先例:`tests/probe/kh_l4_probe.gd` 对大乱斗入口那条
	#   `ResourceLoader.exists` 断言(同一条理由:数字符串会把"场景被删"读成绿)。
	# - 判定条件取场景路径而不是 `team_game` 字样(同 kh_l4 那条的说明):数"指向该场景的字符串"
	#   才等于数"入口个数",数字样会把注释/变量名一起命中。
	var entry := "res://scenes/" + "team" + "_game.tscn"
	if lobby_src.is_empty():
		fails.append("读不到 scenes/mp_lobby.gd(悬空引用守卫无从成立)")
	else:
		var hits := ScanUtil.code_only(lobby_src).count(entry)
		if hits != 1:
			fails.append("★ 3v3 大厅入口应**恰好 1 处**指向 %s(实际 %d 处)—— 入口漏加/被删/指回别处" % [entry, hits])
		if not ResourceLoader.exists(entry):
			fails.append("★ 3v3 对局场景 %s 不存在(悬空引用:大厅那个 call_deferred 换场会静默失败)" % entry)
		# - 顺带严格校验"指向的那个场景真的挂上了 team_game.gd"(反向:路径在但内容是空气 ——
		#   比如只建了个空 .tscn)。读它的 ext_resource 而不是 `load()`:`-s` 阶段不该为了断言
		#   把整个对局场景(含 Level0 那一整棵)拖进内存。
		var tscn := FileAccess.get_file_as_string(entry) if FileAccess.file_exists(entry) else ""
		if not tscn.contains("scenes/team_game.gd"):
			fails.append("★ %s 没有挂 scenes/team_game.gd(空场景 = 换场成功但一行脚本都不跑)" % entry)
	# ⑨ 3v3 客户端的两条"漏了不报错"的接线(B 册 Task 6;判定条件取源码,理由同 ⑥⑦ ——
	#   对局场景要 autoload + 真实网络链路,`-s` 里跑不动,真实网络链路那份归 Task 8)。
	#   - ① `_hud.set_my_team(...)`:唯一会把"我是哪一队"告诉 HUD 的地方。漏了不报错,
	#     后果是 `_my_team` 恒 0  ->  「本局胜利!」/「胜利!」一次都不会出现,赢的局报成输的
	#     (平局那一支不受影响 —— 它走 else)。-  行为面另由 `hud_declarative_probe` 的第二段严格校验
	#     (喂 `{winner: 我的队号}` 断言念「本局胜利!」+ 不写入时的反向对照);这里约束的是**生产
	#     到底调没调**,双向逻辑缺一不可:只钉 HUD 那一半,`team_game` 永不调用照样全部断言通过。
	#   - ② 撞车队:本地玩家的 `collision_layer/mask` 与副本幽灵体的层必须按队设
	#     (`TeamHost.TEAM_ENEMY_LAYER`)。全 1v1/大乱斗式的"全员互挡"在 3v3 是错的,
	#     而错了的表现是 C2 每帧回滚(不像崩溃那样显眼)。
	#   - ⑤ 结算页接线(B 册 Task 7 收的评审尾巴:Task 5/6 的两条调用此前零常驻覆盖)。
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
		elif not apply_body.contains("_team_of_role("):
			fails.append("★ team_game._apply_teams 的 set_my_team 入参没引 _team_of_role(...)(写死队号/拿 role 当队号都会在 role 与队号错开时报错胜负)")
		# - 判定条件收在函数体上而不是全文件 `contains`:全文件里"常量出现过"太容易满足 ——
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
			# 注意事项：判定条件必须是那一行赋值本身(`collision_layer = TeamHost.TEAM_ENEMY_LAYER`),
			#   不能是"常量在函数体里出现过" —— 生产里这个常量出现两次(2 队的身体层 + 1 队
			#   掩码里的"挡住队 B"位),所以"把 2 队的层写死成 16"(1 队那处仍留常量)、
			#   "删掉整个 2 队分支"、两种实现都能把"出现过"误判通过,而它们正是这句话明确提示的变异。
			#   钉整行赋值后:写死 16 -> 红;删掉 2 队分支 -> 红。
			if not coll_body.contains("collision_layer = TeamHost.TEAM_ENEMY_LAYER"):
				fails.append("★ _apply_team_collision 没给 2 队设 `collision_layer = TeamHost.TEAM_ENEMY_LAYER`(写死 16 / 删掉 2 队分支都在这儿红;只数'常量在体内出现过'守不住 —— 它在 1 队那一行也出现)")
			# - 两条一起要:`set_ghost_layer(` 单独一条不够 —— 写成 `set_ghost_layer(2)`
			#   (副本幽灵体恒在玩家层 = 队友副本也挡我)时它照样在,而那一行正是"按队设层"
			#   与"恒在玩家层"的全部差别(实测:只钉前一条时这条变异照样绿)。
			if not (coll_body.contains("set_ghost_layer(") and coll_body.contains("_ghost_layer_of(")):
				fails.append("★ _apply_team_collision 没给副本幽灵体按**队**配层(必须 set_ghost_layer(_ghost_layer_of(...));写成 set_ghost_layer(2) 就是队友副本也挡我 → C2 每帧回滚,不报错)")
		# 注意事项：`_ghost_layer_of` 的两支都要钉:它体内这个常量只出现一次,故"按队"那个
		#   分支被删(改成恒返 `TeamHost.TEAM_ENEMY_LAYER`)时"出现过"照样绿 —— 而那正是
		#   "队友副本也挡我 -> C2 每帧回滚"的实现。判定条件 = 按队判别 + 1 队那一支 + 常量,三样都要。
		var ghost_body := ScanUtil.func_body(tcode, "_ghost_layer_of")
		if ghost_body.is_empty():
			fails.append("★ team_game 里找不到 _ghost_layer_of 的函数体(副本按队配层断言无从成立)")
		elif not (ghost_body.contains("_team_of_role(") and ghost_body.contains("return 2")
				and ghost_body.contains("TeamHost.TEAM_ENEMY_LAYER")):
			fails.append("★ team_game 的 _ghost_layer_of 不是**按队两支**(必须:队号 1 → 层 2,否则 → TeamHost.TEAM_ENEMY_LAYER。恒返 TEAM_ENEMY_LAYER = 队友副本也挡我 → C2 每帧回滚,不报错)")
		# 注意事项：表外 / 队伍表未到时的落层必须与服务端"什么都不配"(保持 `_ready` 里那句层 2)
		#   对齐。旧实现把"未知"当成了队 2:客户端幽灵体层 16、服务端层 2  ->  队 2 的玩家
		#   在服务端会被挡住、在客户端不会  ->  C2 每帧分歧(不报错)。
		#   - 上面那一组"按队两支"区分不了这两种写法(旧的一行三元三样全含)——
		#     鉴别点在结构:新形状是 `match` + 两支 + match 之外的兜底保护 `return 2`,
		#     故 `return 2` 出现两次,而旧写法只有一次。
		if ghost_body.count("return 2") < 2:
			fails.append("★ _ghost_layer_of 丢了表外兜底:未知队号必须落到层 2(与服务端'什么都不配'对齐);旧写法把未知当队 2 ⇒ 两端层不一致 ⇒ C2 每帧分歧,不报错")
		if not ghost_body.contains("match"):
			fails.append("★ _ghost_layer_of 的形状不对:必须是 `match _team_of_role(...)` + 两支 + match **之外**的 `return 2`(GDScript 的 match 体内 `continue` 是 fall-through,兜底写进 match 会静默多跑一支)")
		# ③ 小地图两个提供器必须共用同一套遍历/过滤(`_minimap_entries()`),不能各写一份 `for`。
		#    `ui/minimap.gd` 是按下标对应颜色(`_other_dots[i].color = cols[i]`)——
		#    两个数组错位一格就是"队友点画成敌人色",不报错只误导人;而错位最容易发生在
		#    "某个副本已 queue_free、尚未从 `_replicas` 抹掉"那个窗口里(一处带防御性校验、另一处不带
		#    就当场错一格)。故判定依据为"两处都只从同一个共同遍历取数"。
		var others_body := ScanUtil.func_body(tcode, "_minimap_others")
		var colors_body := ScanUtil.func_body(tcode, "_minimap_colors")
		if not (others_body.contains("_minimap_entries()") and colors_body.contains("_minimap_entries()")):
			fails.append("★ 小地图两个提供器没共用 _minimap_entries()(各写一份 for = 过滤条件两份;某副本已 free 未摘时两数组错位一格 → 队友点画成敌人色,不报错)")
		# ④ 队色染到身体上必须是 modulate 比值(队色 / 本体主色),不能直接乘队色。
		#    - 直接乘是 brief 给的初版:蓝身体 `#639BFF` 乘上那版队色(橙,现已改口径为偏绿的青)
		#      实测是 `#636073` —— 一坨灰紫,"一眼看出谁是队友"直接落空
		#      (实测图 `.superpowers/sdd/_t6_tint2.png` 第②列)。
		#      比值则精确等于队色本身(实测逐字节相等),与头顶 ID / 小地图点位同源同一个常量。
		#    - 本档只钉机制(公式是比值);比值的分母(`BODY_BASE_COLOR` 那个数值)归 ⑩。
		var tint_code := ScanUtil.code_only(ScanUtil.read("res://scenes/pvp_match_client.gd"))
		var tint_body := ScanUtil.func_body(tint_code, "_apply_tint")
		if tint_body.is_empty():
			fails.append("读不到 pvp_match_client.gd 的 _apply_tint 函数体(队色染色机制断言无从成立)")
		elif not (tint_body.contains("color_override.r / BODY_BASE_COLOR.r")
				and tint_body.contains("color_override.b / BODY_BASE_COLOR.b")):
			fails.append("★ 队色染色被改回「直接乘队色」了(蓝身体乘橙 = 灰紫,队色认不出;必须是 队色/本体主色 的比值)")
		# ⑤ 结算页接线(B 册 Task 7)。挂载/离场本身收在基类(`PvpMatchClient._show_result`
		#   / `_leave_to_main_menu`),本文件只负责"调了"。两条都是"删了/写反了不报错"的那类:
		#   ① MATCH_OVER 块里必须调 `_show_result()` —— 删了不报错,只是结算页永不出现
		#      (玩家停在对局里,既没有结算页也没有回主菜单的路)。判定条件取"那个分支里有调用",
		#      而非检查“文件中是否出现” —— 后者若将调用移出分支或改为无条件执行，仍会产生假阳性通过。
		#   ② `_build_result_payload()` 组装解析载荷时 `_names` 与 `_teams` 的实参顺序不得写反。
		# 注意事项：这是本计划最安静的错法:`for_team(round, names, teams, my_team)` 的前三个
		#      实参都是 Dictionary,写反照样编译、所有常驻测试照样绿,只有榜渲染成
		#      乱码/空表。判定条件校验各位置上的具体内容（仅检查名字出现无法防护顺序颠倒的假阳性）。
		#   - 这正是"只扫基类那两条自动化测试探针"无法覆盖检测的那一半(它们管挂载/离场,不管谁来调)。
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
	# ⑩ `BODY_BASE_COLOR` 的数值时效性 —— 与 ⑨④ 的"机制"那一半互补(双向逻辑缺一不可)。
	# - ⑨④ 钉"公式是比值";本档钉那个比值的分母仍等于 `player.png` 的主色。换素材忘了
	#   公式计算保持正确但角色整体色调可能发生偏差。
	# - 复测方法与 pvp_match_client.gd 中注释一致：过滤 player.png 像素并统计高频主色 RGB。
	# - 渲染侧另有一份等价断言（hue_tint_probe），但该断言依赖窗口化视口渲染（无头模式下无法获取视口纹理）；
	#   因此本用例提供无头模式下的纯数值校验，两者形成互补覆盖。
	var pmc_script = load("res://scenes/pvp_match_client.gd")
	if pmc_script == null or pmc_script.reload() != OK:
		# 同 ⑥⑦⑧⑨ 的 load 手法:失败不抛错、给一行 FAIL(否则 `-s` 下走不到 quit() -> 挂到 timeout)
		fails.append("★ 加载/编译 scenes/pvp_match_client.gd 失败(本体主色的数值断言无从成立)")
	else:
		var pmc_consts: Dictionary = pmc_script.get_script_constant_map()
		if not pmc_consts.has("BODY_BASE_COLOR"):
			fails.append("★ scenes/pvp_match_client.gd 里没有常量 BODY_BASE_COLOR")
		else:
			var base_key := _rgb8(pmc_consts["BODY_BASE_COLOR"])
			# - 读原始 PNG 字节再解码,不用 `Image.load_from_file`(那条会打一条
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


# 颜色 -> 8bit 量纲的三元组(逐字节口径:比对"这个 RGB"而不是浮点色,免得被 eps 放走一格)。
# `Color` 的 8 位分量来回换算在 GDScript 里是精确的(`99.0/255.0` 与 `roundi(x*255.0)` 互逆),
# 故这里不需要容差;真需要容差的话说明素材已经被改过了,那正是本断言要报的事。
func _rgb8(c: Color) -> Vector3i:
	return Vector3i(roundi(c.r * 255.0), roundi(c.g * 255.0), roundi(c.b * 255.0))


# 某行的缩进宽度(制表符/空格都算一列)。
# - 入参必须是保留缩进的视图(`ScanUtil.code_view`),`code_only` 会 strip_edges  ->  恒 0。
func _indent_of(line: String) -> int:
	var n := 0
	while n < line.length() and (line[n] == "\t" or line[n] == " "):
		n += 1
	return n


# 某一行同时含「行键」与「`not is_team`」 ->  那一行的可见性由模式防御性校验决定(而不是无条件 `= true`)。
# 注意事项：判定条件落在同一行上是有意的("函数体里出现过 `<key>`"那种写法对无条件设置可见性
#    (`.visible = true`)照样为真 —— 那时这条就证明不了"3v3 会隐藏它",2026-10-03 评审核出)。
# - 残余上限:这是源码形状判定条件,不证明运行时真的收起;运行那一半由
#    `lobby_create_form_probe` ⑤/⑥/⑩ 与 `lobby_wait_room_probe` ⑭ 的行为级断言保证。
func _hide_line_present(body: String, key: String) -> bool:
	for line in body.split("\n"):
		if line.contains(key) and line.contains("not is_team"):
			return true
	return false


# 第 i 行所属块的正文:紧随其后、缩进严格更大的那些行(给"某分支里必须调 X"类断言用 ——
# 判定条件严格限定在特定分支内而非全局查找，避免将调用移出分支后产生假阳性通过）。
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
