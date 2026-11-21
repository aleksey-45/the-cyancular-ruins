class_name WatchHud
extends Control

# 怀表显示时间颗粒余额和技能剩余可用额度。
# 白色短针转满一圈表示余额达到上限。红色长针显示已用的短期额度，超过一圈表示开始透支。
# 表盘中央通常显示剩余额度，透支后改用红色负数显示透支量。

const DIAL := preload("res://assets/textures/watch_dial.png")
const BIG_FONT := 96
const SMALL_FONT := 32
const CAP_FONT := 16
const COLOR_RIM := Color8(20, 23, 28)
const COLOR_HAND_LONG := Color8(196, 62, 62)
const COLOR_HAND_SHORT := Color8(235, 238, 242)
const COLOR_TEXT := Color8(232, 236, 242)
const COLOR_TEXT_DIM := Color8(150, 158, 168)
const COLOR_LOAN := Color8(158, 40, 48)

var _big: Label = null
var _cap: Label = null
var _center: Label = null
var _disp: float = 0.0             # 当前显示的余额，每帧逐步接近实际余额。
var _clock: MatchFrame.Clock
var _tremble_t := 0.0
var _lock_flash_t := 0.0
var _rng := RandomNumberGenerator.new()

func _init(clock: MatchFrame.Clock) -> void:
	_clock = clock

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var diameter := DIAL.get_width()
	_big = _mk_label(BIG_FONT, COLOR_TEXT, Vector2(diameter + 14, -16))
	_cap = _mk_label(CAP_FONT, COLOR_TEXT_DIM, Vector2(diameter + 14, BIG_FONT - 4))
	_center = _mk_label(SMALL_FONT, COLOR_TEXT_DIM, Vector2(0, 0))
	_center.size = Vector2(diameter, SMALL_FONT + 8)
	_center.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_center.position = Vector2(0, diameter * 0.5 - SMALL_FONT * 0.5 - 4)
	_disp = _clock.balance

func _mk_label(size: int, color: Color, pos: Vector2) -> Label:
	var l := Label.new()
	l.add_theme_font_override("font", PixelFont.FONT)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_constant_override("outline_size", maxi(size / 12, 4))
	l.add_theme_color_override("font_outline_color", Color8(14, 16, 20))
	l.position = pos
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(l)
	return l

func present(clock: MatchFrame.Clock, delta: float) -> void:
	_clock = clock
	_disp = lerpf(_disp, clock.balance, minf(1.0, delta * 10.0))
	_big.text = str(int(round(_disp)))
	var col := Color8(210, 62, 62) if clock.rewind else Color8(168, 96, 216) if clock.haste else COLOR_TEXT
	_big.add_theme_color_override("font_color", col)
	_cap.text = "上限 %d" % int(clock.cap)
	_center.text = str(clock.allowance)
	_center.add_theme_color_override("font_color", COLOR_LOAN if clock.borrowed else COLOR_TEXT_DIM)
	_tremble_t = maxf(_tremble_t - delta, 0.0)
	_lock_flash_t = maxf(_lock_flash_t - delta, 0.0)
	queue_redraw()

func _draw() -> void:
	var clock := _clock
	var shake := Vector2.ZERO
	if _tremble_t > 0.0:
		shake = Vector2(_rng.randf_range(-1.5, 1.5), _rng.randf_range(-1.5, 1.5)) * (_tremble_t / 0.4)
	draw_texture(DIAL, shake)
	var c := DIAL.get_size() * 0.5 + shake
	var a_short := -PI * 0.5 + TAU * clampf(clock.balance / maxf(clock.cap, 1.0), 0.0, 1.0)
	draw_line(c, c + Vector2(cos(a_short), sin(a_short)) * (DIAL.get_width() * 0.30), COLOR_HAND_SHORT, 4.0)
	var a_long := -PI * 0.5 + TAU * clock.long_turns
	var long_col := COLOR_HAND_LONG
	if _lock_flash_t > 0.0 and fmod(_lock_flash_t, 0.16) > 0.08:
		long_col = Color8(255, 90, 90)
	draw_line(c, c + Vector2(cos(a_long), sin(a_long)) * (DIAL.get_width() * 0.42), long_col, 3.0)
	draw_circle(c, 3.0, COLOR_RIM)


# 时间颗粒到账时让表盘短暂抖动。
func tremble() -> void:
	_tremble_t = 0.4


# 达到透支上限导致时间技能停用时，长针闪烁提示。
func flash_locked() -> void:
	_lock_flash_t = 1.2
