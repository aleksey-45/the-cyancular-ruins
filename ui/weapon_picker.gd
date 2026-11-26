class_name WeaponPicker
extends ScrollContainer

# 单人开局和联机建房共用的武器选择控件。勾选的武器在本局禁用。

signal selection_changed

# 多列布局限制剪影宽度，避免宽图标撑高整行。
const ICON_MAX_W := UiDesign.SP_9 + UiDesign.SP_2
const ROW_GAP := UiDesign.SP_5
const GRID_H_GAP := UiDesign.SP_5
const GRID_V_GAP := UiDesign.SP_2

var _checks: Dictionary[int, CheckButton] = {}


func _init(disabled: Array[int], columns: int, height: float) -> void:
	theme = UiDesign.MENU_THEME
	custom_minimum_size.y = height
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	follow_focus = true
	get_v_scroll_bar().theme_type_variation = &"Kit"

	var list := _make_list(columns)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(list)
	for id: int in WeaponRegistry.enabled_ids():
		var check := UiDesign.ui_check()
		check.text = WeaponRegistry.name_of(id)
		check.icon = WeaponIcons.silhouette(id)
		check.button_pressed = disabled.has(id)
		if columns > 1:
			check.add_theme_constant_override("icon_max_width", ICON_MAX_W)
		check.toggled.connect(func(_on: bool) -> void: selection_changed.emit())
		_checks[id] = check
		list.add_child(check)


static func _make_list(columns: int) -> Container:
	if columns <= 1:
		var vbox := VBoxContainer.new()
		vbox.name = "List"
		vbox.add_theme_constant_override("separation", ROW_GAP)
		return vbox
	var grid := GridContainer.new()
	grid.name = "Grid"
	grid.columns = columns
	grid.add_theme_constant_override("h_separation", GRID_H_GAP)
	grid.add_theme_constant_override("v_separation", GRID_V_GAP)
	return grid


## 按武器注册顺序返回禁用的武器 ID。
func disabled_weapons() -> Array[int]:
	var disabled: Array[int] = []
	for id: int in _checks:
		if _checks[id].button_pressed:
			disabled.append(id)
	return disabled
