class_name WaitRoom
extends RefCounted

# 大厅页的「等待室」面板(2026-10-22 Task 10 纯搬移自 scenes/mp_lobby.gd):选边 / 开始按钮 / 满员文案 / 房主判断 / 名单行 / 角色颜色行。
# 三个模式共用一个面板(骨架里那一个,启动即建、默认隐藏),每次 show() 清空重填。
# ★ 节点路径(%语义名)、信号、文案逐字未动:标题里的「—— {模式名}房间 {code} ——」、人数行、分队标题、按钮文案都是玩家可见的对齐点。
# ★★ 节点句柄仍住在页上(page._wait_*):tests/harness/team_match_watcher.gd 用 lobby.get("_wait_body" / "_wait_count" / "_wait_pick_a" / "_wait_start") 读名单与按钮,
#    句柄搬进本文件它们会静默拿到 null("名单没画"与"探针拿不到节点"在输出上长得一样)。故本文件只搬行为,不搬句柄。

var page: MpLobby = null


func setup(p: MpLobby) -> void:
	page = p


# 接骨架 + 信号。★ 选边按钮用 bind(队号) 而不是两条匿名 lambda:绑定实参能被 Callable.get_bound_arguments() 读出来 —— 两颗按钮的文案只差一个 A/B 字,对调之后行为是错的且没有任何运行时信号。
# 零守卫:读绑实参的那条断言随 lobby_* 探针一起删了(2026-10-09)。
func register(root: Node) -> void:
	page._wait_panel = root.get_node("%WaitPanel") as PanelContainer
	page._wait_panel.visible = false
	page._wait_title = root.get_node("%WaitTitle") as Label
	page._wait_body = root.get_node("%WaitBody") as VBoxContainer
	page._wait_count = root.get_node("%WaitCount") as Label
	page._wait_hue = root.get_node("%WaitHueRow") as Control
	page._wait_pick_a = root.get_node("%WaitPickABtn") as Button
	page._wait_pick_b = root.get_node("%WaitPickBBtn") as Button
	page._wait_start = root.get_node("%WaitStartBtn") as Button
	page._wait_leave = root.get_node("%WaitLeaveBtn") as Button
	page._wait_pick_a.pressed.connect(page._on_wait_pick.bind(1))
	page._wait_pick_b.pressed.connect(page._on_wait_pick.bind(2))
	page._wait_start.pressed.connect(page._on_wait_start_pressed)
	page._wait_leave.pressed.connect(page._on_wait_leave_pressed)

	# 角色颜色行(仅 1v1 / 大乱斗可见;3v3 用队色 ⇒ show() 整行收起)。★ 它住等待室而不是创建弹层:创建弹层一进等待室就收起,放那儿等于房主建完房改不了、加入者全程没见过。
	# ★★ 行本身是静态骨架(标签 + 滑条 + 预览色块),这里只灌值 + 接写回 —— 与设置页那两个音量滑条同款(值由脚本灌、信号由脚本接)。
	var hue_slider: HSlider = root.get_node("%WaitHueSlider") as HSlider
	var hue_chip: ColorRect = root.get_node("%WaitHueChip") as ColorRect
	hue_slider.value = Settings.pvp_color_hue
	hue_chip.color = UiFactory.hue_preview_color(Settings.pvp_color_hue)
	hue_slider.value_changed.connect(func(v: float) -> void:
		Settings.pvp_color_hue = v
		Settings.save()
		hue_chip.color = UiFactory.hue_preview_color(v))


# 亮起 / 重填等待室。★ 清空重填而不是就地改几行:名单人数、分队、按钮显隐在三个模式下都不同,就地改必然漏一处 —— 而漏了不报错,只是上一个模式的行留在屏上(叠成两批名单)。
func show(state: Dictionary, mode: String) -> void:
	page._wait_mode = mode
	page._create_dialog.set_visible(false)
	page._wait_panel.visible = true
	# 进房 = 收起两颗入口按钮 + 关掉可能开着的加入弹层(见页的 _create_btn 上方那段:闸门拦不住直接绑定的弹层,层级会翻过来)。与 hide() 成对;三颗都启动即建(骨架 / _build_ui 登记)⇒ 没有 null 可判。
	page._in_room = true
	page._create_btn.visible = false
	page._join_btn.visible = false
	page._rooms.hide_join_panel()
	page._wait_title.text = _wait_title_text(state, mode)

	# ★ 必须 remove_child 再 queue_free:只 queue_free 的话旧行要到帧末才没,同帧重填会两批名单叠着(与列表侧 redraw 同款纪律)。
	for c in page._wait_body.get_children():
		page._wait_body.remove_child(c)
		c.queue_free()

	var my_role := int(state.get("your_role", 0))
	var host_role := int(state.get("host_role", 0))
	var is_host := host_role == my_role
	var plist: Array = state.get("players", [])
	var is_pvp := mode == PvpSession.MODE_PVP
	var is_team := mode == PvpSession.MODE_TEAM

	if is_pvp:
		page._wait_count.text = "等待对手… 1 / 2"
	elif mode == PvpSession.MODE_ROYALE:
		_fill_flat_roster(plist, my_role, host_role)
		page._wait_count.text = "%d / %d 人(至少 2 人可开局)" % [
				plist.size(), int(state.get("max_players", 4))]
	else:
		_fill_team_roster(state, plist, my_role, host_role)
		page._wait_count.text = _team_count_text(state, plist)

	# 角色颜色行:3v3 用队色、个人色相在本模式是无效输入 ⇒ 整行收起。
	page._wait_hue.visible = not is_team
	# 选边按钮(仅 3v3)。★ 自己那支的按钮置灰:既少一次无意义的上行,也让「已在该队时再点该队」那条幂等 wart(服务器回"该队已满"、状态不变)不可达。
	var my_team := _team_of_role(state, my_role) if is_team else 0
	page._wait_pick_a.visible = is_team and my_team != 1
	page._wait_pick_b.visible = is_team and my_team != 2
	# 「开始游戏」:1v1 没有这颗按钮(两人凑齐自动开局);3v3 还要求两队各满。
	if is_pvp:
		page._wait_start.visible = false
	elif mode == PvpSession.MODE_ROYALE:
		page._wait_start.visible = is_host
	else:
		page._wait_start.visible = is_host and _both_teams_full(
				state, int(state.get("team_size", LobbyRooms.TEAM_SIZE)))


# 收起等待室。★ 唯一调用点是页的 _on_return_to_lobby()。不恢复创建弹层 —— 玩家要建房会自己再点「＋ 创建房间」。★★ 两颗入口按钮在这里恢复,与 show() 的收起成对。
func hide() -> void:
	page._wait_panel.visible = false
	page._in_room = false
	page._create_btn.visible = true
	page._join_btn.visible = true


# 标题:—— {模式名}房间 {code} ——。★ 邀请码只在私密时印:公开房的载荷里 invite_code 可能是空串、也可能带着房主随手填的值 —— 印出来会让玩家以为"这房要码"。
func _wait_title_text(state: Dictionary, mode: String) -> String:
	var code := str(state.get("code", ""))
	var invite := ""
	if not bool(state.get("is_public", true)):
		invite = "  邀请码 %s" % str(state.get("invite_code", ""))
	return "—— %s房间 %s ——%s" % [str(RoomList.MODE_LABEL.get(mode, mode)), code, invite]


func _fill_flat_roster(plist: Array, my_role: int, host_role: int) -> void:
	var shown := 0
	for p in plist:
		if typeof(p) != TYPE_DICTIONARY:
			continue
		shown += 1
		page._wait_body.add_child(_roster_row(shown, p, my_role, host_role))


# 名单行(3v3:两队 + 未选边三档)。★ 两队标题恒出(哪怕 0 人):"这局有 A、B 两队"是规则、不是当前人数;缺了空队的标题,新来的玩家看不出该往哪边站。
func _fill_team_roster(state: Dictionary, plist: Array, my_role: int, host_role: int) -> void:
	var buckets := {0: [], 1: [], 2: []}
	for p in plist:
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var t := int(p.get("team", 0))
		if not buckets.has(t):
			t = 0   # 未知队号归"未选边"(客户端侧口径,与服务端"先拦后分"同向)
		(buckets[t] as Array).append(p)
	var team_size := int(state.get("team_size", LobbyRooms.TEAM_SIZE))
	var shown := 0
	for t in [1, 2]:
		var tag := "A 队" if t == 1 else "B 队"
		page._wait_body.add_child(UiFactory.label("—— %s(%d/%d) ——" % [
				tag, (buckets[t] as Array).size(), team_size], 32, UiFactory.C_ACCENT))
		for p in buckets[t]:
			shown += 1
			page._wait_body.add_child(_roster_row(shown, p, my_role, host_role))
	if not (buckets[0] as Array).is_empty():
		page._wait_body.add_child(UiFactory.label("—— 未选边 ——", 32, UiFactory.C_TEXT_DIM))
		for p in buckets[0]:
			shown += 1
			page._wait_body.add_child(_roster_row(shown, p, my_role, host_role))


# 一行名单。★ 编号印行序(n)而不是 role —— role 是「最小空闲号」分配、有人退出后不重排,印 role 会出现 1、3(两个旧页都在这里踩过)。
# ★★ set_meta("roster_row", true) 本是探针数名单行的唯一据点 —— 零守卫:那个探针已删(2026-10-09),今天没有读者;标题 / 人数行 / 分队标题全是 Label,靠遍历猜极易假绿。
func _roster_row(n: int, p: Dictionary, my_role: int, host_role: int) -> Label:
	var role := int(p.get("role", 0))
	var l := UiFactory.label("%d. %s%s%s" % [n, str(p.get("name", "玩家")),
			"(我)" if role == my_role else "",
			"(房主)" if role == host_role else ""],
			32, UiFactory.C_ACCENT if role == my_role else UiFactory.C_TEXT)
	l.set_meta("roster_row", true)
	return l


# 我在这个房间里在哪一队。★ 判据来自服务器按 peer 单独下发的 your_role:按昵称在名单里反查时,两人同名会命中先出现的那个 → 高亮错行、_host 判错 → 真房主看不到开局按钮。
func _team_of_role(state: Dictionary, role: int) -> int:
	for p in state.get("players", []):
		if typeof(p) == TYPE_DICTIONARY and int(p.get("role", 0)) == role:
			return int(p.get("team", 0))
	return 0


# 两队各满(= 3v3 的开局闸门,与 LobbyRooms.team_ready 同义)。★ 分母引 team_size 而不是写 "3":容量只有一个真值来源,写死的话 TEAM_SIZE 一改这行就撒谎且不报错。
func _both_teams_full(state: Dictionary, size: int) -> bool:
	var counts := {1: 0, 2: 0}
	for p in state.get("players", []):
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var t := int(p.get("team", 0))
		if counts.has(t):
			counts[t] += 1
	return counts[1] == size and counts[2] == size


func _team_count_text(state: Dictionary, plist: Array) -> String:
	var picked := 0
	for p in plist:
		if typeof(p) == TYPE_DICTIONARY and int(p.get("team", 0)) != 0:
			picked += 1
	return "%d / %d 人(已选边 %d 人;两队各 %d 人才可开局)" % [
			plist.size(), LobbyRooms.TEAM_ROLES, picked,
			int(state.get("team_size", LobbyRooms.TEAM_SIZE))]


# 1v1 的等待室载荷:1v1 没有 room_state 这条下行载荷(room_created 只给房号、room_joined 只给 role),故在本侧拼一份最小形状,与大乱斗 / 3v3 共用同一个 show() —— 而不是给 1v1 单开一条渲染路径。
func pvp_wait_state(code: String, role: int) -> Dictionary:
	return {
		"code": code,
		"is_public": true,   # 1v1 没有私密房这条路径
		"players": [],       # 1v1 不画名单(设计 §3.5:`等待对手… 1 / 2`)
		"your_role": role,
		"host_role": role,
	}
