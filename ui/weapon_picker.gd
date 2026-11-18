class_name WeaponPicker
extends ScrollContainer

signal selection_changed

var _ids := WeaponRegistry.all_ids()
var _checks: Array[CheckButton] = []

func _init(disabled: Array[int], columns: int, height: float) -> void:
	custom_minimum_size.y = height
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	follow_focus = true
	var list: Container
	if columns == 1:
		list = VBoxContainer.new()
		list.add_theme_constant_override("separation", 20)
	else:
		var grid := GridContainer.new()
		grid.columns = columns
		grid.add_theme_constant_override("h_separation", 20)
		grid.add_theme_constant_override("v_separation", 6)
		list = grid
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(list)
	for id: int in _ids:
		var check := WeaponIcons.make_weapon_check(id, disabled.has(id))
		if columns > 1:
			check.add_theme_constant_override("icon_max_width", 72)
		check.toggled.connect(func(_on: bool) -> void: selection_changed.emit())
		_checks.append(check)
		list.add_child(check)

func disabled_weapons() -> Array[int]:
	var disabled: Array[int] = []
	for i in _checks.size():
		if _checks[i].button_pressed:
			disabled.append(_ids[i])
	return disabled
