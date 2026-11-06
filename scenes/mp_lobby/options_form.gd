class_name OptionsForm
extends RefCounted


var rows := {}
var public_check: CheckButton = null
var invite_edit: LineEdit = null
var max_slider: HSlider = null
var time_slider: HSlider = null
var weapon_checks: Array[CheckButton] = []


func register(root: Node) -> void:
	rows = {
		"privacy": root.get_node("%PrivacyRow"), "max_players": root.get_node("%MaxPlayersRow"),
		"match_time": root.get_node("%MatchTimeRow"), "full_heal": root.get_node("%FullHealRow"),
		"weapons": root.get_node("%WeaponsBlock"), "map": root.get_node("%MapBlock"),
		"beta": root.get_node("%BetaBlock"),
	}

	public_check = root.get_node("%PublicCheck") as CheckButton
	invite_edit = root.get_node("%InviteEdit") as LineEdit
	public_check.button_pressed = true
	invite_edit.visible = false
	public_check.toggled.connect(func(on: bool) -> void:
		invite_edit.visible = not on)

	max_slider = root.get_node("%MaxPlayersSlider") as HSlider
	max_slider.value_changed.connect(func(v: float) -> void:
		(root.get_node("%MaxPlayersLabel") as Label).text = "%d 人" % int(v))

	time_slider = root.get_node("%MatchTimeSlider") as HSlider
	time_slider.value = Settings.royale_match_min
	(root.get_node("%MatchTimeLabel") as Label).text = "%d 分钟" % int(Settings.royale_match_min)
	time_slider.value_changed.connect(func(v: float) -> void:
		Settings.royale_match_min = v
		Settings.save()
		(root.get_node("%MatchTimeLabel") as Label).text = "%d 分钟" % int(v))

	var full_heal: CheckButton = root.get_node("%FullHealCheck") as CheckButton
	full_heal.button_pressed = Settings.pvp_round_full_heal
	full_heal.toggled.connect(func(on: bool) -> void:
		Settings.pvp_round_full_heal = on
		Settings.save())

	(rows["beta"] as Node).visible = PvpSession.beta_mode


func apply_rows(mode: String) -> void:
	var is_royale := mode == PvpSession.MODE_ROYALE
	var is_team := mode == PvpSession.MODE_TEAM
	var is_pvp := mode == PvpSession.MODE_PVP
	rows["max_players"].visible = is_royale
	rows["match_time"].visible = is_royale
	rows["full_heal"].visible = is_pvp
	rows["weapons"].visible = not is_team
	rows["privacy"].visible = not is_pvp



func is_public() -> bool:
	return public_check.button_pressed


func invite_code() -> String:
	return invite_edit.text.strip_edges()


func max_players() -> int:
	return int(max_slider.value)


func match_time() -> int:
	return int(time_slider.value) * 60


func checked_weapons() -> Array:
	var out: Array = []
	for cb in weapon_checks:
		if cb.button_pressed:
			out.append(int(cb.get_meta("type_id", 0)))
	return out


# LobbyPage._add_weapon_grid 的 on_cell 回调。★ 少收 type_id 那半,checked_weapons() 会永远返回 [0] 且不报错。
func on_weapon_cell(cell: Node, type_id: int) -> void:
	var cb: CheckButton = cell.get_meta("cb")
	cb.set_meta("type_id", type_id)
	weapon_checks.append(cb)
