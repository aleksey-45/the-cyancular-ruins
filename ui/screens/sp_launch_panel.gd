class_name SpLaunchPanel
extends PanelContainer

# 单人开局面板。选好的地图和禁用武器交给主菜单验证并开始关卡。

signal play_requested(path: String, disabled_weapons: Array[int])

const PANEL_PAD := Vector2(UiDesign.SP_9, UiDesign.SP_6)      # 水平和垂直内边距。
const PAGE_MIN_W := UiDesign.SP_10 * 7                        # 内容的最小宽度，面板还会加上两侧内边距。
const BLOCK_GAP := UiDesign.SP_6                              # 32:大块间距
const SECTION_GAP := UiDesign.SP_4                            # 16:分区标题条与其内容之间
const BUTTON_SIZE := Vector2(UiDesign.SP_10 * 5 + UiDesign.SP_5 - UiDesign.SP_1,
		UiDesign.SP_10 + UiDesign.SP_2)                      # 420 × 88(与 PvpHud 结算返回键同档)
const MAP_H := UiDesign.SP_10 * 3 + UiDesign.SP_9 - UiDesign.SP_1  # 300:地图网格滚动高度
const WEAPONS_H := UiDesign.SP_10 * 4                         # 320:武器开关滚动高度


var initial_map := ""
var disabled: Array[int] = []
var _map := MapPicker.new()
var _weapons: WeaponPicker
var _status: Label


func _ready() -> void:
	var body := UiDesign.skin_menu_panel(self, PANEL_PAD)
	var page := VBoxContainer.new()
	page.name = "Page"
	page.custom_minimum_size.x = PAGE_MIN_W
	page.add_theme_constant_override("separation", BLOCK_GAP)
	body.add_child(page)

	page.add_child(UiDesign.header_strip("—— 单人开局 ——", UiDesign.T_H1, true))

	_map.name = "MapPicker"
	page.add_child(_map)
	_map.setup(initial_map, MAP_H)

	var weapons_section := VBoxContainer.new()
	weapons_section.name = "WeaponsSection"
	weapons_section.add_theme_constant_override("separation", SECTION_GAP)
	page.add_child(weapons_section)
	weapons_section.add_child(UiDesign.header_strip("禁用武器(勾选 = 本局不可用)",
			UiDesign.T_H2))

	_weapons = WeaponPicker.new(disabled, 1, WEAPONS_H)
	_weapons.name = "WeaponPicker"
	weapons_section.add_child(_weapons)

	var actions := HBoxContainer.new()
	actions.name = "Actions"
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", BLOCK_GAP)
	page.add_child(actions)
	var go := UiDesign.ui_button("开始探索", UiDesign.T_H2, BUTTON_SIZE, "gold")
	go.name = "StartBtn"
	go.pressed.connect(_on_play)
	actions.add_child(go)
	var back := UiDesign.ui_button("返回", UiDesign.T_H2, BUTTON_SIZE, "quiet")
	back.name = "BackBtn"
	back.pressed.connect(_on_back)
	actions.add_child(back)

	_status = UiDesign.label("", UiDesign.T_H2, UiDesign.C_TEXT_DIM)
	_status.name = "Status"
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# 错误信息可能包含地图文件名，自动换行以免撑宽面板。
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.hide()
	page.add_child(_status)


func show_error(message: String) -> void:
	_status.text = message
	_status.show()


func _on_play() -> void:
	Sfx.play("ui")
	play_requested.emit(_map.selected, _weapons.disabled_weapons())


func _on_back() -> void:
	Sfx.play("ui")
	hide()
