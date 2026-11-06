class_name HeaderStripPanel
extends PanelContainer


@export var title: String = "":
	set(v):
		title = v
		_apply_title()

@export var centered := false:
	set(v):
		centered = v
		_apply_align()

@export var title_size := 32:
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
		UiFactory.style_control(_label, title_size)
