class_name UiKit
extends RefCounted

# 创建容器和通用控件，布局使用 UiDesign 的间距常量，样式来自主题类型变体。
# 控件布局与样式约定见 docs/construction/2026-11-23-ui-full-replacement-plan.md 的「实现约定」。

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


## 添加顶部工具栏，返回用于放置按钮的水平容器。
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


## 添加底部状态栏，返回用于放置状态文字等控件的水平容器。
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


## 添加带可选标题的卡片，返回其中的内容容器 Body。外层面板是 Body 的三级父节点。
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
