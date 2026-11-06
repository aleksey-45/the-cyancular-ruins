class_name CreatePanel
extends RefCounted


var page: MpLobby = null
var form: OptionsForm = null
var panel: PanelContainer = null
var mask: ColorRect = null
var mode_btns := {}


func setup(p: MpLobby, f: OptionsForm) -> void:
	page = p
	form = f


func register(root: Node) -> void:
	# ★ 压暗罩铺满整页 + mouse_filter = STOP(拦下背后的点击 = 点弹层外不会误触房卡)在骨架里;它的颜色是调色板纪律的已知例外(全屏遮罩不属于 C_PLATE 那条「HUD 底板 0.1」家族,见 docs/eng/ui.md):Color(0,0,0,0.55) 与 ui/screens/ma。
	mask = root.get_node("%CreateMask") as ColorRect
	mask.visible = false
	panel = root.get_node("%CreatePanel") as PanelContainer
	panel.visible = false
	(root.get_node("%CreateCloseBtn") as Button).pressed.connect(func() -> void: set_visible(false))
	(root.get_node("%CreateCancelBtn") as Button).pressed.connect(func() -> void: set_visible(false))
	(root.get_node("%CreateOkBtn") as Button).pressed.connect(page._on_create_pressed)

	# 三颗模式分段按钮(ButtonGroup 互斥;模式色在骨架里)。★ 必须登记进 mode_btns:_apply_create_form 靠它把当前项置灰。
	# ★ 按钮文案 = RoomList.MODE_LABEL(模式名的唯一真相;骨架里的默认 text 只是占位) —— 与筛选按钮同一份。
	mode_btns = {PvpSession.MODE_PVP: root.get_node("%CreateModePvp"),
			PvpSession.MODE_TEAM: root.get_node("%CreateModeTeam"), PvpSession.MODE_ROYALE: root.get_node("%CreateModeRoyale")}
	for m: String in [PvpSession.MODE_PVP, PvpSession.MODE_TEAM, PvpSession.MODE_ROYALE]:
		if RoomList.MODE_LABEL.has(m):
			(mode_btns[m] as Button).text = str(RoomList.MODE_LABEL[m])
		(mode_btns[m] as Button).pressed.connect(func() -> void: apply(m))

	page._add_weapon_grid(root.get_node("%WeaponsBlock"), 20, form.on_weapon_cell)
	page._add_map_picker(root.get_node("%MapBlock") as VBoxContainer)
	page._add_time_params(root.get_node("%BetaBlock") as VBoxContainer)


func open() -> void:
	apply(page._mode if page._mode != "" else PvpSession.MODE_PVP)
	set_visible(true)


func set_visible(v: bool) -> void:
	panel.visible = v
	mask.visible = v


func is_open() -> bool:
	return panel.visible


func apply(mode: String) -> void:
	page._create_mode = mode
	form.apply_rows(mode)
	for m in mode_btns:
		var b: Button = mode_btns[m]
		b.disabled = false
		b.button_pressed = m == mode


func build_payload(mode: String) -> Dictionary:
	var d := {
		"is_public": form.is_public(),
		"invite_code": form.invite_code(),
		"map": Settings.mp_map_path,
	}
	if mode == PvpSession.MODE_ROYALE:
		d["max_players"] = form.max_players()
		d["match_time"] = form.match_time()
		d["round_full_heal"] = false
		d["disabled_weapons"] = form.checked_weapons()
	elif mode == PvpSession.MODE_PVP:
		d["disabled_weapons"] = form.checked_weapons()
	return d


func player_options(mode: String, snapshot: Dictionary) -> Dictionary:
	return ModeOptions.build(mode, snapshot)
