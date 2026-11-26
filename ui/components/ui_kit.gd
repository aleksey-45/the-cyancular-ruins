class_name UiKit
extends RefCounted

# 创建容器和通用控件，布局使用 UiDesign 的间距常量，样式来自主题类型变体。
# 控件布局与样式约定见 docs/construction/2026-11-23-ui-full-replacement-plan.md 的「实现约定」。

# ── 页面骨架 ────────────────────────────────────────────────────────────────

## 页面根:给 parent 挂一个 MarginContainer(SP_6)→ VBox(SP_5),返回 VBox 供页面填内容。
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


## 顶部工具条:给 parent 挂一个 Bar 面板 + Margin(SP_4) + HBox(SP_3),返回 HBox 供调用方加按钮。
static func toolbar(parent: Control) -> HBoxContainer:
	var barrier := MarginContainer.new()
	barrier.add_theme_constant_override("margin_left", UiDesign.SP_4)
	barrier.add_theme_constant_override("margin_right", UiDesign.SP_4)
	barrier.add_theme_constant_override("margin_top", UiDesign.SP_2)
	barrier.add_theme_constant_override("margin_bottom", UiDesign.SP_2)
	var row := HBoxContainer.new()
	row.name = "Toolbar"
	row.add_theme_constant_override("separation", UiDesign.SP_3)
	barrier.add_child(row)
	var panel := UiDesign.ui_panel("bar")
	panel.add_child(barrier)
	parent.add_child(panel)
	return row


## 底部状态条:Bar 面板 + HBox(SP_3),返回 HBox;文本用 UiDesign.ui_label(..., "dim")。
static func status_bar(parent: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "StatusBar"
	row.add_theme_constant_override("separation", UiDesign.SP_3)
	var barrier := MarginContainer.new()
	barrier.add_theme_constant_override("margin_left", UiDesign.SP_4)
	barrier.add_theme_constant_override("margin_right", UiDesign.SP_4)
	barrier.add_theme_constant_override("margin_top", UiDesign.SP_1)
	barrier.add_theme_constant_override("margin_bottom", UiDesign.SP_1)
	barrier.add_child(row)
	var panel := UiDesign.ui_panel("bar")
	panel.add_child(barrier)
	parent.add_child(panel)
	return row


## 卡片:Card 面板 + VBox(SP_3) + H2 标题;返回 body VBox 供调用方填内容。
static func card(parent: Control, title: String = "") -> VBoxContainer:
	var panel := UiDesign.ui_panel("card")
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
	var body := VBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", UiDesign.SP_2)
	vb.add_child(body)
	return body
