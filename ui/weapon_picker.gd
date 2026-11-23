class_name WeaponPicker
extends ScrollContainer

# 武器选择器(设计系统 v2):单人开局与建房表单共用;勾选 = 本局禁用该武器。
#
# ── 皮(Theme 2.0)──────────────────────────────────────────────────────────────
#   · 根 = ScrollContainer:纵向滚动、横向关闭,滚动条走 Theme 的 Kit 皮肤。
#   · 每把武器 = CheckButton:UiDesign.ui_check()(Kit variation 的自绘胶囊开关 + 统一字体),
#     图标 = WeaponIcons.silhouette()(与 HUD 武器槽同一份剪影),文字 = WeaponRegistry.name_of()。
#   · 间距/图标宽全用 UiDesign token;不 new StyleBoxFlat、不写 Color 字面量、不设 position/size。
#
# ── 契约(与迁移前逐项等价,sp_launch_panel / lobby_create_panel 只依赖这些)──────────
#   · WeaponPicker.new(disabled: Array[int], columns: int, height: float)
#     disabled = 初始勾选的武器 id;columns = 1 单列、>1 网格列数;height = 滚动区高度。
#   · signal selection_changed —— 任一开关切换后发出(无参数,调用方自查 disabled_weapons())。
#   · disabled_weapons() -> Array[int] —— 顺序 = WeaponRegistry.all_ids()(8 武器的注册顺序/名称)。
#   · 「至少一把启用」的校验仍由使用方做(main_menu / mp_lobby 用 WeaponRegistry.enabled_ids);
#     本控件只提供只读的 enabled_weapons() / has_enabled() 辅助,不擅自改动用户勾选。
#   · 数据仍是 siri 的「禁用列表」语义:勾上 = 禁用,不勾 = 可用。

signal selection_changed

# 图标最大显示宽:72 = SP_9 + SP_2(两列时限制图标宽,避免图标把行高撑得过高)。
const ICON_MAX_W := UiDesign.SP_9 + UiDesign.SP_2
# 单列行距 / 多列网格列距 / 网格行距(8 的倍数档位,来自设计系统 token)。
const ROW_GAP := UiDesign.SP_5
const GRID_H_GAP := UiDesign.SP_5
const GRID_V_GAP := UiDesign.SP_2

var _ids := WeaponRegistry.all_ids()
var _checks: Array[CheckButton] = []


func _init(disabled: Array[int], columns: int, height: float) -> void:
	# 主题挂在根上:控件可能被加进没挂 menu_theme 的树(探针 / 载入流程),滚动条与子控件
	# 仍解析 v2;挂的是同一份资源,在已挂主题的树里无害(同 lobby_view / pause_menu 的做法)。
	theme = UiDesign.MENU_THEME
	custom_minimum_size.y = height
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	follow_focus = true
	get_v_scroll_bar().theme_type_variation = &"Kit"

	var list := _make_list(columns)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(list)
	for id: int in _ids:
		var check := _make_check(id, disabled.has(id), columns > 1)
		check.toggled.connect(func(_on: bool) -> void: selection_changed.emit())
		_checks.append(check)
		list.add_child(check)


## 单列用 VBox(行距)、多列用 Grid;两者都只吃 token 间距。
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


## 一把武器 = 图标 + 名称 + Kit 开关;compact(多列)时限制图标宽。初始化勾选不发信号。
static func _make_check(id: int, checked: bool, compact: bool) -> CheckButton:
	var check := UiDesign.ui_check()
	check.text = WeaponRegistry.name_of(id)
	check.icon = WeaponIcons.silhouette(id)
	check.button_pressed = checked
	if compact:
		check.add_theme_constant_override("icon_max_width", ICON_MAX_W)
	return check


## 当前禁用的武器 id(顺序 = WeaponRegistry.all_ids() 的 8 武器注册顺序)。
func disabled_weapons() -> Array[int]:
	var disabled: Array[int] = []
	for i in _checks.size():
		if _checks[i].button_pressed:
			disabled.append(_ids[i])
	return disabled


## 当前可用的武器 id(未禁用;顺序同 WeaponRegistry)。
func enabled_weapons() -> Array[int]:
	return WeaponRegistry.enabled_ids(disabled_weapons())


## 只读校验:至少一把武器可用。使用方仍可自行用 WeaponRegistry.enabled_ids() 判断并提示。
func has_enabled() -> bool:
	return not enabled_weapons().is_empty()
