class_name WatchHud
extends Control

# 怀表时间 HUD 界面：怀表表盘 + 双指针 + 粒子余额数字。
#   · 表盘：纯程序化像素绘制（冷灰阶配色：表壳、盘面、刻度），与像素美术风格保持一致；
#   · 红色长指针：指示短期额度消耗与透支进度（一圈对应短期额度 window；透支额外圈数 = loan_max/window）；
#   · 白色短指针：指示粒子总余额与上限比例（一整圈对应 GRAIN_CAP）；
#   · 右侧大数字：显示当前总余额（96px 像素字，扣减时逐点平滑插值滚动，0.2s 内过渡完成）；右上角显示上限数值；
#     表盘中心显示短期可用额度（透支状态下显示深红负数）。
# 布局位置：挂载于 HUD 层，位于生命条/氧气条下方。
# 数据源：引用 Level0.grain_account（单人模式有效；未启用时整体隐藏）。

const DIAL := 84.0                 # 表盘直径（像素）
const BIG_FONT := 96               # 大数字字号（与主菜单标题一致）
const SMALL_FONT := 32
const CAP_FONT := 16
const COLOR_RIM := Color8(20, 23, 28)        # 表壳外圈（最深色）
const COLOR_CASE := Color8(58, 64, 72)       # 表壳（冷灰）
const COLOR_FACE := Color8(96, 103, 112)     # 盘面（浅冷灰）
const COLOR_TICK := Color8(70, 76, 84)       # 刻度颜色
const COLOR_HAND_LONG := Color8(196, 62, 62)   # 红色长指针
const COLOR_HAND_SHORT := Color8(235, 238, 242)  # 白色短指针
const COLOR_TEXT := Color8(232, 236, 242)
const COLOR_TEXT_DIM := Color8(150, 158, 168)
const COLOR_LOAN := Color8(158, 40, 48)      # 透支状态深红色

var _dial_tex: ImageTexture = null
var _big: Label = null
var _cap: Label = null
var _center: Label = null
var _disp: float = 0.0             # 大数字平滑插值显示值
var _anim_from: float = 0.0        # 插值动画起始值
var _anim_target: float = 0.0
var _anim_t: float = 1.0           # 插值进度（0→1，固定持续 0.2s）
var _initialized := false
var _tremble_t := 0.0              # 吸收结晶时的表盘震动倒计时
var _lock_flash_t := 0.0           # 透支锁定状态下的红闪警示倒计时


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_to_group("watch_hud")   # 结晶特效根据该节点组确定吸收目标位置
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


## 绘制程序化像素表盘：基于方块组合圆盘（冷灰三层阶梯色板与 12 个时钟刻度）。
## 静态无状态接口：Beta 模式入口卡片图标可直接复用此纹理。
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
	# 12 个时钟刻度
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
	# 余额数字滚动：数值变化时触发定长 0.2s 的平滑插值动画，按整数逐点过渡到位
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
	# 余额颜色联动：回溯显示红色、加速显示紫色、常规状态显示白色
	var col := COLOR_TEXT
	if TimeField.current != null:
		if TimeField.current.is_rewinding():
			col = Color8(210, 62, 62)
		elif TimeField.current.is_hasting():
			col = Color8(168, 96, 216)
	_big.add_theme_color_override("font_color", col)
	_cap.text = "上限 %d" % int(acc.cap)
	# 表盘中心：显示短期剩余可用额度（正常为浅灰正数，透支为深红负数）
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
	# 白色短指针：总余额 / 上限（指示一圈）
	var a_short := -PI * 0.5 + TAU * clampf(acc.balance / maxf(acc.cap, 1.0), 0.0, 1.0)
	draw_line(c, c + Vector2(cos(a_short), sin(a_short)) * (DIAL * 0.30), COLOR_HAND_SHORT, 4.0)
	# 红色长指针：短期已用额度 + 透支额度（一圈对应短期额度 window，透支额外占用相应比例圈数）
	var win: float = acc.window if acc.window > 0.0 else TimeParams.SHORT_WINDOW
	var turns := (acc.short_used + acc.loan_used) / win
	var max_turns := 1.0 + (acc.loan_max / win)
	var a_long := -PI * 0.5 + TAU * clampf(turns, 0.0, max_turns)
	var long_col := COLOR_HAND_LONG
	if _lock_flash_t > 0.0 and fmod(_lock_flash_t, 0.16) > 0.08:
		long_col = Color8(255, 90, 90)   # 锁定状态警示红闪
	draw_line(c, c + Vector2(cos(a_long), sin(a_long)) * (DIAL * 0.42), long_col, 3.0)
	draw_circle(c, 3.0, COLOR_RIM)


## 触发吸收结晶时的表盘微震效果
func tremble() -> void:
	_tremble_t = 0.4


## 触发透支锁定时的指针红闪警示效果
func flash_locked() -> void:
	_lock_flash_t = 1.2


## 吸收结晶：增加粒子余额并触发微震反馈
func absorb(amount: int) -> void:
	if Level0.grain_account != null:
		Level0.grain_account.deposit(amount)
	tremble()

