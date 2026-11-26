class_name UiKit
extends RefCounted

# 创建容器和通用控件，布局使用 UiDesign 的间距常量，样式来自主题类型变体。

## 添加铺满父控件的边距容器，返回其中的页面内容容器。
static func page(parent: Control, margin: int = UiDesign.SP_6, gap: int = UiDesign.SP_5) -> VBoxContainer:
	var margin_box := MarginContainer.new()
	margin_box.name = "Page"
	margin_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin_box.add_theme_constant_override("margin_left", margin)
	margin_box.add_theme_constant_override("margin_right", margin)
	margin_box.add_theme_constant_override("margin_top", margin)
	margin_box.add_theme_constant_override("margin_bottom", margin)
	parent.add_child(margin_box)
	var vb := VBoxContainer.new()
	vb.name = "Body"
	vb.add_theme_constant_override("separation", gap)
	margin_box.add_child(vb)
	return vb


static func toolbar(parent: Control) -> HBoxContainer:
	return _bar(parent, "Toolbar", UiDesign.SP_2)

static func status_bar(parent: Control) -> HBoxContainer:
	return _bar(parent, "StatusBar", UiDesign.SP_1)

static func _bar(parent: Control, title: String, vertical_pad: int) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = title
	row.add_theme_constant_override("separation", UiDesign.SP_3)
	var barrier := MarginContainer.new()
	for side in ["left", "right"]:
		barrier.add_theme_constant_override("margin_" + side, UiDesign.SP_4)
	for side in ["top", "bottom"]:
		barrier.add_theme_constant_override("margin_" + side, vertical_pad)
	barrier.add_child(row)
	var panel := UiDesign.ui_panel("bar")
	panel.add_child(barrier)
	parent.add_child(panel)
	return row

class Card extends PanelContainer:
	var body := VBoxContainer.new()

static func card(parent: Control, title := "") -> Card:
	var panel := Card.new()
	panel.theme = UiDesign.MENU_THEME
	panel.theme_type_variation = &"Card"
	parent.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", UiDesign.SP_3)
	var barrier := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		barrier.add_theme_constant_override("margin_" + side, UiDesign.SP_4)
	barrier.add_child(vb)
	panel.add_child(barrier)
	if title != "":
		vb.add_child(UiDesign.ui_label(title, "h2"))
	var body := panel.body
	body.name = "Body"
	body.add_theme_constant_override("separation", UiDesign.SP_2)
	vb.add_child(body)
	return panel

static func label(parent: Control, text: String, color := UiDesign.C_TEXT) -> Label:
	var node := UiDesign.label(text, UiDesign.T_SMALL, color)
	parent.add_child(node)
	return node

static func button(parent: Control, text: String, action: Callable) -> Button:
	var node := Button.new()
	node.text = text
	node.theme_type_variation = &"ToolButton"
	node.pressed.connect(action)
	parent.add_child(node)
	return node

static func spin_row(parent: Control, text: String, minimum: int, maximum: int, value: int) -> SpinBox:
	var row := UiDesign.box(parent, UiDesign.SP_2, false)
	var caption := label(row, text)
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.value = value
	row.add_child(spin)
	return spin
