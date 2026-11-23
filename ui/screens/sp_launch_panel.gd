class_name SpLaunchPanel
extends PanelContainer

# 单人开局面板(设计系统 v2):结构从 main 的 sp_launch_panel 填充逻辑迁移,内容仍由本文件建 ——
# 皮 = UiDesign.skin_menu_panel(凿刻边 + 内亮线,Theme 2.0),控件 = UiDesign 的 header_strip /
# menu_button / label。★ 对外契约不变:initial_map / disabled / play_requested / show_error,以及
# 「返回 = 隐藏面板、开始探索 = 发信号」的旧行为。
# ★ MapPicker / WeaponPicker 仍是 siri 旧组件(UI-5 范围),此处不改它们的逻辑,只把它们放进 v2 面板。

signal play_requested(path: String, disabled_weapons: Array[int])

const PANEL_MIN_W := UiDesign.SP_10 * 7      # 560px:内容驱动的最小宽度,不是绝对坐标
const BLOCK_GAP := UiDesign.SP_6             # 32px
const BUTTON_SIZE := Vector2(420, UiDesign.SP_10 + UiDesign.SP_2)

var initial_map := ""
var disabled: Array[int] = []
var _map := MapPicker.new()
var _weapons: WeaponPicker
var _status: Label


func _ready() -> void:
	UiDesign.skin_menu_panel(self, Vector2(UiDesign.SP_9, UiDesign.SP_6))
	var body := get_node("Body") as Container
	var vb := VBoxContainer.new()
	vb.custom_minimum_size.x = PANEL_MIN_W
	vb.add_theme_constant_override("separation", BLOCK_GAP)
	body.add_child(vb)

	vb.add_child(UiDesign.header_strip("—— 单人开局 ——", UiDesign.T_H1, true))

	vb.add_child(_map)
	_map.setup(initial_map, 2, 300.0)

	vb.add_child(UiDesign.header_strip("禁用武器(勾选 = 本局不可用)", UiDesign.T_H2))

	_weapons = WeaponPicker.new(disabled, 1, 320)
	vb.add_child(_weapons)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", BLOCK_GAP)
	vb.add_child(row)
	var go := UiDesign.menu_button("开始探索", UiDesign.T_H2, BUTTON_SIZE, "gold")
	row.add_child(go)
	go.pressed.connect(func() -> void:
		Sfx.play("ui")
		play_requested.emit(_map.selected, _weapons.disabled_weapons()))
	var back := UiDesign.menu_button("返回", UiDesign.T_H2, BUTTON_SIZE, "quiet")
	row.add_child(back)
	back.pressed.connect(func() -> void:
		Sfx.play("ui")
		hide())

	_status = UiDesign.label("", UiDesign.T_H2, UiDesign.C_TEXT_DIM)
	_status.hide()
	vb.add_child(_status)


func show_error(message: String) -> void:
	_status.text = message
	_status.show()
