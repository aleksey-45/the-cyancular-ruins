class_name TimeSymbolHud
extends Control

# 时间模式中心标志(第一阶段):回溯=浅色倒放符号「◁◁」,加速=紫色「▶▶」。
# 屏幕正中,轻微呼吸脉冲;两种模式各自显示,常态全隐。数据源 TimeField.current(单机)。

const SYMBOL_FONT := 64
const COLOR_REWIND := Color(0.86, 0.90, 0.95, 0.55)   # 浅色(回溯:像倒带的半透明符号)
const COLOR_HASTE := Color8(168, 96, 216)             # 紫色(加速)

var _rew: Label = null
var _has: Label = null
var _t := 0.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rew = _mk("◁ ◁", COLOR_REWIND)
	_has = _mk("▶ ▶", COLOR_HASTE)
	visible = false


func _mk(text: String, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", PixelFont.shared())
	l.add_theme_font_size_override("font_size", SYMBOL_FONT)
	l.add_theme_color_override("font_color", col)
	l.add_theme_constant_override("outline_size", 8)
	l.add_theme_color_override("font_outline_color", Color8(10, 12, 16, 200))
	l.set_anchors_preset(Control.PRESET_CENTER)
	l.grow_horizontal = Control.GROW_DIRECTION_BOTH
	l.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(l)
	return l


func _process(delta: float) -> void:
	var tf := TimeField.current
	if tf == null:
		visible = false
		return
	_t += delta
	var rew := tf.is_rewinding()
	var has := tf.is_hasting()
	visible = rew or has
	if _rew != null:
		_rew.visible = rew
		if rew:
			_rew.modulate.a = 0.75 + 0.25 * sin(_t * 9.0)   # 倒带式快闪
	if _has != null:
		_has.visible = has
		if has:
			_has.modulate.a = 0.8 + 0.2 * sin(_t * 5.0)
