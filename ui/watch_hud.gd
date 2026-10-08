class_name WatchHud
extends Control

# 怀表 HUD 界面组件：包含程序化生成的表盘、双指针以及数值指示。
# - 表盘：纯程序化像素绘制，包含冷灰外壳、盘面与 12 刻度
# - 红长针：指示短期额度消耗与透支深度（一圈对应短期额度 window）
# - 白短针：指示当前颗粒总余额相对上限的比例
# - 右侧数字：当前时间颗粒总余额，伴随平滑滚动插值动画；右上角显示上限，表盘中央显示短期额度
# 位置位于玩家生命条与氧气条下方。数据源绑定 Level0.grain_account。

const DIAL := 84.0                 # 表盘直径（像素）
const BIG_FONT := 96               # 大数字字号
const SMALL_FONT := 32
const CAP_FONT := 16
const COLOR_RIM := Color8(20, 23, 28)        # 表壳外圈
const COLOR_CASE := Color8(58, 64, 72)       # 表壳冷灰色
const COLOR_FACE := Color8(96, 103, 112)     # 盘面底色
const COLOR_TICK := Color8(70, 76, 84)       # 刻度标记
const COLOR_HAND_LONG := Color8(196, 62, 62)   # 红色长针
const COLOR_HAND_SHORT := Color8(235, 238, 242)  # 白色短针
const COLOR_TEXT := Color8(232, 236, 242)
const COLOR_TEXT_DIM := Color8(150, 158, 168)
const COLOR_LOAN := Color8(158, 40, 48)      # 透支报警红

var _dial_tex: ImageTexture = null
var _big: Label = null
var _cap: Label = null
var _center: Label = null
var _disp: float = 0.0             # 大数字插值显示值
var _anim_from: float = 0.0
var _anim_target: float = 0.0
var _anim_t: float = 1.0           # 动画进度（固定 0.2 秒平滑过渡）
var _initialized := false
var _tremble_t := 0.0              # 吸收结晶颤抖计时
var _lock_flash_t := 0.0           # 透支锁定闪烁计时


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


# 程序化构建像素表盘纹理：绘制圆形外壳、浅灰盘面以及 12 刻度
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
	# 绘制 12 刻度
	for i in 12:
		var ang := -PI * 0.5 + TAU * float(i) / 12.0
		for t in range(3):
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
	# 余额数字变化时触发 0.2 秒定长平滑过渡动画
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
	# 余额数字颜色响应时间模式：回溯为红色，加速为紫色，常态为白色
	var col := COLOR_TEXT
	if TimeField.current != null:
		if TimeField.current.is_rewinding():
			col = Color8(210, 62, 62)
		elif TimeField.current.is_hasting():
			col = Color8(168, 96, 216)
	_big.add_theme_color_override("font_color", col)
	_cap.text = "上限 %d" % int(acc.cap)
	# 表盘中央显示短期额度剩余量，透支时显示红色负数
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
	# 白短针：指示当前总量相对上限的旋转角度
	var a_short := -PI * 0.5 + TAU * clampf(acc.balance / maxf(acc.cap, 1.0), 0.0, 1.0)
	draw_line(c, c + Vector2(cos(a_short), sin(a_short)) * (DIAL * 0.30), COLOR_HAND_SHORT, 4.0)
	# 红长针：指示短期窗口已消耗额度与透支进度
	var win: float = acc.window if acc.window > 0.0 else TimeParams.SHORT_WINDOW
	var turns := (acc.short_used + acc.loan_used) / win
	var max_turns := 1.0 + (acc.loan_max / win)
	var a_long := -PI * 0.5 + TAU * clampf(turns, 0.0, max_turns)
	var long_col := COLOR_HAND_LONG
	if _lock_flash_t > 0.0 and fmod(_lock_flash_t, 0.16) > 0.08:
		long_col = Color8(255, 90, 90)
	draw_line(c, c + Vector2(cos(a_long), sin(a_long)) * (DIAL * 0.42), long_col, 3.0)
	draw_circle(c, 3.0, COLOR_RIM)


# 吸收结晶触发颤抖动画
func tremble() -> void:
	_tremble_t = 0.4


# 透支达到上限触发锁定红闪警报
func flash_locked() -> void:
	_lock_flash_t = 1.2


# 吸收结晶颗粒存入账户并触发颤抖动画
func absorb(amount: int) -> void:
	if Level0.grain_account != null:
		Level0.grain_account.deposit(amount)
	tremble()
