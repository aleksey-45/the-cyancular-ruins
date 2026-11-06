class_name WatchHud
extends Control


const DIAL := 84.0
const BIG_FONT := 96
const SMALL_FONT := 32
const CAP_FONT := 16
const COLOR_RIM := Color8(20, 23, 28)
const COLOR_CASE := Color8(58, 64, 72)
const COLOR_FACE := Color8(96, 103, 112)
const COLOR_TICK := Color8(70, 76, 84)
const COLOR_HAND_LONG := Color8(196, 62, 62)
const COLOR_HAND_SHORT := Color8(235, 238, 242)
const COLOR_TEXT := Color8(232, 236, 242)
const COLOR_TEXT_DIM := Color8(150, 158, 168)
const COLOR_LOAN := Color8(158, 40, 48)

var _dial_tex: ImageTexture = null
var _big: Label = null
var _cap: Label = null
var _center: Label = null
var _disp: float = 0.0
var _anim_from: float = 0.0
var _anim_target: float = 0.0
var _anim_t: float = 1.0
var _initialized := false
var _tremble_t := 0.0
var _lock_flash_t := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_to_group("watch_hud")
	_dial_tex = build_dial_texture()
	_big = _mk_label(BIG_FONT, COLOR_TEXT, Vector2(DIAL + 14, -16))
	_cap = _mk_label(CAP_FONT, COLOR_TEXT_DIM, Vector2(DIAL + 14, BIG_FONT - 4))
	_center = _mk_label(SMALL_FONT, COLOR_TEXT_DIM, Vector2(0, 0))
	_center.size = Vector2(DIAL, SMALL_FONT + 8)
	_center.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_center.position = Vector2(0, DIAL * 0.5 - SMALL_FONT * 0.5 - 4)
	var acc := Level0.grain_account
	if acc != null:
		_disp = acc.balance
	visible = acc != null


func _mk_label(size: int, color: Color, pos: Vector2) -> Label:
	var l := Label.new()
	l.add_theme_font_override("font", PixelFont.shared())
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_constant_override("outline_size", maxi(size / 12, 4))
	l.add_theme_color_override("font_outline_color", Color8(14, 16, 20))
	l.position = pos
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(l)
	return l


static func build_dial_texture() -> ImageTexture:
	var n := int(DIAL)
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var c := float(n) * 0.5
	var block := 2.0
	var r_out := c - 1.0
	var r_case := r_out - 5.0
	var r_face := r_case - 5.0
	for y in range(0, n, int(block)):
		for x in range(0, n, int(block)):
			var d := Vector2(float(x) + block * 0.5, float(y) + block * 0.5).distance_to(Vector2(c, c))
			var col := Color(0, 0, 0, 0)
			if d <= r_out:
				col = COLOR_RIM
			if d <= r_out - 2.0:
				col = COLOR_CASE
			if d <= r_case:
				col = COLOR_FACE
			if d <= r_face:
				col = COLOR_CASE
			if col.a > 0.0:
				for by in range(int(block)):
					for bx in range(int(block)):
						img.set_pixel(x + bx, y + by, col)
	for i in 12:
		var ang := -PI * 0.5 + TAU * float(i) / 12.0
		for t in 3:
			var px := int(c + cos(ang) * (r_face - 4.0 - float(t) * 2.0))
			var py := int(c + sin(ang) * (r_face - 4.0 - float(t) * 2.0))
			if px >= 0 and py >= 0 and px < n and py < n:
				img.set_pixel(px, py, COLOR_TICK)
	return ImageTexture.create_from_image(img)


func _process(delta: float) -> void:
	var acc := Level0.grain_account
	visible = acc != null
	if acc == null:
		return
	if not _initialized:
		_disp = acc.balance
		_anim_from = acc.balance
		_anim_target = acc.balance
		_anim_t = 1.0
		_initialized = true
	if not is_equal_approx(acc.balance, _anim_target):
		_anim_from = _disp
		_anim_target = acc.balance
		_anim_t = 0.0
	_anim_t = minf(_anim_t + delta / 0.2, 1.0)
	_disp = lerpf(_anim_from, _anim_target, _anim_t)
	_big.text = str(int(round(_disp)))
	var col := COLOR_TEXT
	if TimeField.current != null:
		if TimeField.current.is_rewinding():
			col = Color8(210, 62, 62)
		elif TimeField.current.is_hasting():
			col = Color8(168, 96, 216)
	_big.add_theme_color_override("font_color", col)
	_cap.text = "上限 %d" % int(acc.cap)
	if acc.loan_used > 0.5:
		_center.text = "-%d" % int(round(acc.loan_used))
		_center.add_theme_color_override("font_color", COLOR_LOAN)
	else:
		_center.text = "%d" % int(round(acc.window - acc.short_used))
		_center.add_theme_color_override("font_color", COLOR_TEXT_DIM)
	_tremble_t = maxf(_tremble_t - delta, 0.0)
	_lock_flash_t = maxf(_lock_flash_t - delta, 0.0)
	queue_redraw()


func _draw() -> void:
	var acc := Level0.grain_account
	if acc == null or _dial_tex == null:
		return
	var shake := Vector2.ZERO
	if _tremble_t > 0.0:
		shake = Vector2(randf_range(-1.5, 1.5), randf_range(-1.5, 1.5)) * (_tremble_t / 0.4)
	draw_texture(_dial_tex, shake)
	var c := Vector2(DIAL * 0.5, DIAL * 0.5) + shake
	var a_short := -PI * 0.5 + TAU * clampf(acc.balance / maxf(acc.cap, 1.0), 0.0, 1.0)
	draw_line(c, c + Vector2(cos(a_short), sin(a_short)) * (DIAL * 0.30), COLOR_HAND_SHORT, 4.0)
	var win: float = acc.window if acc.window > 0.0 else TimeParams.SHORT_WINDOW
	var turns := (acc.short_used + acc.loan_used) / win
	var max_turns := 1.0 + (acc.loan_max / win)
	var a_long := -PI * 0.5 + TAU * clampf(turns, 0.0, max_turns)
	var long_col := COLOR_HAND_LONG
	if _lock_flash_t > 0.0 and fmod(_lock_flash_t, 0.16) > 0.08:
		long_col = Color8(255, 90, 90)
	draw_line(c, c + Vector2(cos(a_long), sin(a_long)) * (DIAL * 0.42), long_col, 3.0)
	draw_circle(c, 3.0, COLOR_RIM)


func tremble() -> void:
	_tremble_t = 0.4


func flash_locked() -> void:
	_lock_flash_t = 1.2

