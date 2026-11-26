class_name WatchHud
extends Control

# 白色短针显示时间颗粒余额，红色长针显示短期消耗。透支时表盘中央显示红色负数。
# 表盘纹理也用于 Beta 模式卡片。

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
var _disp := 0.0                    # 当前显示余额,每帧逐步接近实际余额
var _clock: MatchFrame.Clock
var _tremble_t := 0.0
var _lock_flash_t := 0.0
var _rng := RandomNumberGenerator.new()

func _init(clock: MatchFrame.Clock) -> void:
	_clock = clock

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
	_disp = _clock.balance if _clock != null else 0.0

func _themed_label(variation: StringName) -> Label:
	var l := Label.new()
	l.theme_type_variation = variation
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

# 文字描边让读数在游戏画面上更清楚。
func _outline(l: Label, size: int) -> void:
	l.add_theme_constant_override("outline_size", maxi(size / 12, 4))
	l.add_theme_color_override("font_outline_color", UiDesign.C_BG)

func present(clock: MatchFrame.Clock, delta: float) -> void:
	if clock == null:
		return
	_clock = clock
	_disp = lerpf(_disp, clock.balance, minf(1.0, delta * FOLLOW_RATE))
	_big.text = str(int(round(_disp)))
	_big.add_theme_color_override("font_color", _readout_color(clock))
	_cap.text = "上限 %d" % int(clock.cap)
	_center.text = str(clock.allowance)
	if clock.borrowed:
		_center.add_theme_color_override("font_color", UiDesign.C_DANGER)
	else:
		_center.remove_theme_color_override("font_color")
	_tremble_t = maxf(_tremble_t - delta, 0.0)
	_lock_flash_t = maxf(_lock_flash_t - delta, 0.0)
	queue_redraw()

func _readout_color(clock: MatchFrame.Clock) -> Color:
	if clock.rewind:
		return UiDesign.C_DANGER
	if clock.haste:
		return UiDesign.C_GRACE
	return UiDesign.C_TEXT

func _draw() -> void:
	if _clock == null:
		return
	var shake := Vector2.ZERO
	if _tremble_t > 0.0:
		shake = Vector2(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0)) \
				* (TREMBLE_SHAKE * (_tremble_t / TREMBLE_TIME))
	draw_texture(DIAL, shake)
	var c := DIAL.get_size() * 0.5 + shake
	var a_short := -PI * 0.5 + TAU * clampf(_clock.balance / maxf(_clock.cap, 1.0), 0.0, 1.0)
	draw_line(c, c + Vector2(cos(a_short), sin(a_short)) * (DIAL.get_width() * SHORT_HAND_LEN),
			UiDesign.C_WHITE, SHORT_HAND_W)
	var a_long := -PI * 0.5 + TAU * _clock.long_turns
	var long_col := UiDesign.C_DANGER
	if _lock_flash_t > 0.0 and fmod(_lock_flash_t, FLASH_BLINK) > FLASH_BLINK * 0.5:
		long_col = UiDesign.C_DANGER.lightened(0.35)
	draw_line(c, c + Vector2(cos(a_long), sin(a_long)) * (DIAL.get_width() * LONG_HAND_LEN),
			long_col, LONG_HAND_W)
	draw_circle(c, HUB_RADIUS, UiDesign.C_BG)


# 时间颗粒到账时让表盘短暂抖动。
func tremble() -> void:
	_tremble_t = TREMBLE_TIME


# 达到透支上限并停用时间技能时，长针闪烁。
func flash_locked() -> void:
	_lock_flash_t = LOCK_FLASH_TIME
