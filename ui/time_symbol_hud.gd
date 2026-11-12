class_name TimeSymbolHud
extends Control

const COLOR_REWIND := Color(0.86, 0.90, 0.95, 0.55)
const COLOR_HASTE := Color8(168, 96, 216)

var _field: TimeField
var _symbol: Label
var _t := 0.0

func _init(field: TimeField) -> void:
	_field = field

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_symbol = UiFactory.label("◁ ◁", 64, COLOR_REWIND)
	_symbol.add_theme_constant_override("outline_size", 8)
	_symbol.add_theme_color_override("font_outline_color", Color8(10, 12, 16, 200))
	_symbol.set_anchors_preset(Control.PRESET_CENTER)
	_symbol.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_symbol.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(_symbol)
	hide()

func _process(delta: float) -> void:
	_t += delta
	var rewinding := _field.is_rewinding()
	visible = rewinding or _field.is_hasting()
	if not visible:
		return
	_symbol.text = "◁ ◁" if rewinding else "▶ ▶"
	_symbol.add_theme_color_override("font_color", COLOR_REWIND if rewinding else COLOR_HASTE)
	_symbol.modulate.a = 0.75 + 0.25 * sin(_t * 9.0) if rewinding else 0.8 + 0.2 * sin(_t * 5.0)
