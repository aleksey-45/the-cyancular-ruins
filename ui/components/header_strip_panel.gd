class_name HeaderStripPanel
extends PanelContainer

# 菜单分区标题条(从 main 的 ui/components/header_strip_panel 迁移)。
# 样式全部来自 Theme 2.0 的 HeaderStrip / HeaderTitle variation,字号走 UiDesign.style_control ——
# 本文件不做任何 StyleBox / Color 字面量。

@export var title: String = "":
	set(v):
		title = v
		_apply_title()

@export var centered := false:
	set(v):
		centered = v
		_apply_align()

@export var title_size := UiDesign.T_H2:
	set(v):
		title_size = v
		_apply_size()

@onready var _label: Label = %Title


func _ready() -> void:
	_apply_title()
	_apply_align()
	_apply_size()


func apply(title_text: String, size: int, center: bool) -> void:
	title = title_text
	title_size = size
	centered = center


func _apply_title() -> void:
	if _label != null:
		_label.text = title


func _apply_align() -> void:
	if _label != null:
		_label.horizontal_alignment = (
				HORIZONTAL_ALIGNMENT_CENTER if centered else HORIZONTAL_ALIGNMENT_LEFT)


func _apply_size() -> void:
	if _label != null:
		UiDesign.style_control(_label, title_size)
