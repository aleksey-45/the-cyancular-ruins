class_name WaitRoom
extends RefCounted


var page: MpLobby = null


func setup(p: MpLobby) -> void:
	page = p


func register(root: Node) -> void:
	page._wait_panel = root.get_node("%WaitPanel") as PanelContainer
	page._wait_panel.visible = false
	page._wait_title = root.get_node("%WaitTitle") as HeaderStripPanel
	page._wait_body = root.get_node("%WaitBody") as VBoxContainer
	page._wait_count = root.get_node("%WaitCount") as Label
	page._wait_pick_a = root.get_node("%WaitPickABtn") as Button
	page._wait_pick_b = root.get_node("%WaitPickBBtn") as Button
	page._wait_start = root.get_node("%WaitStartBtn") as Button
	page._wait_leave = root.get_node("%WaitLeaveBtn") as Button
	page._wait_pick_a.pressed.connect(page._on_wait_pick.bind(1))
	page._wait_pick_b.pressed.connect(page._on_wait_pick.bind(2))
	page._wait_start.pressed.connect(page._on_wait_start_pressed)
	page._wait_leave.pressed.connect(page._on_wait_leave_pressed)


# 亮起 / 重填等待室。★ 清空重填而不是就地改几行:名单人数、分队、按钮显隐在三个模式下都不同,就地改必然漏一处 —— 而漏了不报错,只是上一个模式的行留在屏上(叠成两批名单)。
func show(state: Dictionary, mode: String) -> void:
	page._wait_mode = mode
	page._create_dialog.set_visible(false)
	page._wait_panel.visible = true
	page._in_room = true
	page._create_btn.visible = false
	page._join_btn.visible = false
	page._rooms.hide_join_panel()
	page._rooms.set_list_visible(false)
	page._wait_title.title = _wait_title_text(state, mode)

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
		_fill_flat_roster(plist, my_role, host_role)
		var n := maxi(plist.size(), int(state.get("count", 1)))
		if n >= 2:
			page._wait_count.text = "已就绪 2 / 2" + (" — 点「开始游戏」" if is_host else " — 等待房主开始…")
		else:
			page._wait_count.text = "等待对手… %d / 2" % n
	elif mode == PvpSession.MODE_ROYALE:
		_fill_flat_roster(plist, my_role, host_role)
		page._wait_count.text = "%d / %d 人(至少 2 人可开局)" % [
				plist.size(), int(state.get("max_players", 4))]
	else:
		_fill_team_roster(state, plist, my_role, host_role)
		page._wait_count.text = _team_count_text(state, plist)

	var my_team := _team_of_role(state, my_role) if is_team else 0
	page._wait_pick_a.visible = is_team and my_team != 1
	page._wait_pick_b.visible = is_team and my_team != 2
	if is_pvp:
		page._wait_start.visible = is_host and maxi(plist.size(), int(state.get("count", 1))) >= 2
	elif mode == PvpSession.MODE_ROYALE:
		page._wait_start.visible = is_host
	else:
		page._wait_start.visible = is_host and _both_teams_ready(state)


func hide() -> void:
	page._wait_panel.visible = false
	page._in_room = false
	page._create_btn.visible = true
	page._join_btn.visible = true
	page._rooms.set_list_visible(true)


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


func _fill_team_roster(state: Dictionary, plist: Array, my_role: int, host_role: int) -> void:
	var buckets := {0: [], 1: [], 2: []}
	for p in plist:
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var t := int(p.get("team", 0))
		if not buckets.has(t):
			t = 0
		(buckets[t] as Array).append(p)
	var team_size := int(state.get("team_size", ModeDefs.TEAM_SIZE))
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


func _roster_row(n: int, p: Dictionary, my_role: int, host_role: int) -> Label:
	var role := int(p.get("role", 0))
	var l := UiFactory.label("%d. %s%s%s" % [n, str(p.get("name", "玩家")),
			"(我)" if role == my_role else "",
			"(房主)" if role == host_role else ""],
			32, UiFactory.C_ACCENT if role == my_role else UiFactory.C_TEXT)
	l.set_meta("roster_row", true)
	return l


func _team_of_role(state: Dictionary, role: int) -> int:
	for p in state.get("players", []):
		if typeof(p) == TYPE_DICTIONARY and int(p.get("role", 0)) == role:
			return int(p.get("team", 0))
	return 0


# 两队各有至少 1 人(= 对抗的开局闸门,与 `RoomTypes.team_ready` 同义)。★ 下限的唯一真相是
# `TeamRules.MIN_PER_TEAM`(别在这里写死 1 或 3):容量 / 下限各只有一处真值来源。
func _both_teams_ready(state: Dictionary) -> bool:
	var counts := {1: 0, 2: 0}
	for p in state.get("players", []):
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var t := int(p.get("team", 0))
		if counts.has(t):
			counts[t] += 1
	return counts[1] >= TeamRules.MIN_PER_TEAM and counts[2] >= TeamRules.MIN_PER_TEAM


func _team_count_text(state: Dictionary, plist: Array) -> String:
	var picked := 0
	for p in plist:
		if typeof(p) == TYPE_DICTIONARY and int(p.get("team", 0)) != 0:
			picked += 1
	# 只留玩家真正需要知道的一句话:两队各有 1 人即可开始;容量取 TEAM_ROLES / TEAM_SIZE 单一来源。
	return "%d / %d 人(已选边 %d 人;两队各 1 人即可开始,每队最多 %d 人)" % [
			plist.size(), (ModeDefs.TEAM_SIZE * ModeDefs.TEAM_COUNT), picked,
			int(state.get("team_size", ModeDefs.TEAM_SIZE))]


func pvp_wait_state(code: String, role: int, host_role: int, count: int) -> Dictionary:
	return {
		"code": code,
		"is_public": true,
		"players": [],
		"your_role": role,
		"host_role": host_role,
		"count": count,
	}
