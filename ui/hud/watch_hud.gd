class_name WatchHud
extends Control

# 白色短针显示时间颗粒余额，红色长针显示短期消耗。透支时表盘中央显示红色负数。
# 表盘纹理也用于 Beta 模式卡片。

const TIME_REWIND := Color(0.86, 0.90, 0.95, 0.55)
const TIME_HASTE := Color8(168, 96, 216)
const DIAL := preload("res://assets/textures/watch_dial.png")
const BIG_FONT := 96
const SHORT_HAND_LEN := 0.30
const LONG_HAND_LEN := 0.42
const SHORT_HAND_W := 4.0
const LONG_HAND_W := 3.0
const HUB_RADIUS := 3.0
const TREMBLE_SHAKE := 1.5
const TREMBLE_TIME := 0.4
const LOCK_FLASH_TIME := 1.2
const FLASH_BLINK := 0.16
const FOLLOW_RATE := 10.0           # 主读数每帧向实际余额逼近的速度

var _big: Label = null
var _cap: Label = null
var _center: Label = null
var _face: Dictionary

class State:
	var reading := -1.0
	var tremble := 0.0
	var flash := 0.0
	var rng := RandomNumberGenerator.new()
	var shake := Vector2.ZERO

	func advance(clock: MatchFrame.Clock, delta: float, now: float, solo: bool) -> Dictionary:
		reading = clock.balance if reading < 0.0 else lerpf(reading, clock.balance, minf(1.0, delta * FOLLOW_RATE))
		tremble = maxf(0.0, tremble - delta)
		flash = maxf(0.0, flash - delta)
		if delta > 0.0:
			shake = Vector2.ZERO if tremble == 0.0 else Vector2(rng.randf_range(-1, 1), rng.randf_range(-1, 1)) * (TREMBLE_SHAKE * tremble / TREMBLE_TIME)
		var symbol := ""
		var tint := UiDesign.C_TEXT
		var alpha := 1.0
		if clock.rewind:
			symbol = "◁ ◁"
			if solo:
				tint = TIME_REWIND
				alpha = 0.75 + 0.25 * sin(now * 9.0)
		elif solo and clock.haste:
			symbol = "▶ ▶"
			tint = TIME_HASTE
			alpha = 0.8 + 0.2 * sin(now * 5.0)
		return {"symbol": symbol, "symbol_color": tint, "symbol_alpha": alpha, "reading": roundi(reading), "cap": int(clock.cap), "allowance": clock.allowance,
			"borrowed": clock.borrowed, "color": UiDesign.C_DANGER if clock.rewind else UiDesign.C_GRACE if clock.haste else UiDesign.C_TEXT,
			"shake": shake, "short_hand": clampf(clock.balance / maxf(clock.cap, 1.0), 0.0, 1.0),
			"long_hand": clock.long_turns, "flash": flash > 0.0 and fmod(flash, FLASH_BLINK) > FLASH_BLINK * 0.5}

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = UiDesign.MENU_THEME
	# 表盘圆心也是时间颗粒飞行的目标。
	size = DIAL.get_size()
	_build()

func _build() -> void:
	_big = UiDesign.label("", BIG_FONT, UiDesign.C_TEXT)
	_outline(_big, BIG_FONT)
	_cap = _themed_label(&"SmallDim")
	_outline(_cap, UiDesign.T_BODY)
	_center = _themed_label(&"Dim")
	_center.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_center.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_center.grow_vertical = Control.GROW_DIRECTION_BOTH
	_outline(_center, UiDesign.T_H2)

	var readout := VBoxContainer.new()
	readout.name = "Readout"
	readout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	readout.add_theme_constant_override("separation", UiDesign.SP_3)
	readout.anchor_left = 1.0
	readout.anchor_right = 1.0
	readout.offset_left = UiDesign.SP_3
	readout.offset_top = -UiDesign.SP_4
	readout.offset_right = UiDesign.SP_3
	readout.offset_bottom = -UiDesign.SP_4
	readout.grow_horizontal = Control.GROW_DIRECTION_END
	readout.grow_vertical = Control.GROW_DIRECTION_END
	add_child(readout)
	readout.add_child(_big)
	readout.add_child(_cap)

	add_child(_center)
	_center.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_MINSIZE)

func _themed_label(variation: StringName) -> Label:
	var l := Label.new()
	l.theme_type_variation = variation
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

# 文字描边让读数在游戏画面上更清楚。
func _outline(l: Label, size: int) -> void:
	l.add_theme_constant_override("outline_size", maxi(size / 12, 4))
	l.add_theme_color_override("font_outline_color", UiDesign.C_BG)

func display(face: Dictionary) -> void:
	_face = face
	_big.text = str(face.reading)
	_big.add_theme_color_override("font_color", face.color)
	_cap.text = "上限 %d" % face.cap
	_center.text = str(face.allowance)
	if face.borrowed:
		_center.add_theme_color_override("font_color", UiDesign.C_DANGER)
	else:
		_center.remove_theme_color_override("font_color")
	queue_redraw()

func _draw() -> void:
	if _face.is_empty(): return
	draw_texture(DIAL, _face.shake)
	var center: Vector2 = DIAL.get_size() * 0.5 + _face.shake
	var short_hand := Vector2.UP.rotated(TAU * _face.short_hand) * DIAL.get_width() * SHORT_HAND_LEN
	var long_hand := Vector2.UP.rotated(TAU * _face.long_hand) * DIAL.get_width() * LONG_HAND_LEN
	draw_line(center, center + short_hand, UiDesign.C_WHITE, SHORT_HAND_W)
	draw_line(center, center + long_hand, UiDesign.C_DANGER.lightened(0.35) if _face.flash else UiDesign.C_DANGER, LONG_HAND_W)
	draw_circle(center, HUB_RADIUS, UiDesign.C_BG)
