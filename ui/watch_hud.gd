class_name WatchHud
extends Control

# 个人钟·怀表 HUD(第一阶段):怀表表盘 + 指针 + 数字。
#   · 表盘:纯程序化像素绘制(冷灰阶色板:表壳/盘面/刻度),零美术素材(与瓦片/8bit 音效同风格)
#   · 红长针 = 短时限额(一圈 = 账户的 window;贷款额外圈数 = loan_max/window —— 单机 1/4 圈,PvP 1 整圈)
#   · 白短针 = 颗粒总量(一圈 = GRAIN_CAP)
#   · 右侧大数字 = 总余额(与主菜单标题同为 96px 像素字;扣减时 1 点 1 点快速滚动,
#     终值确定后 ≤0.2s 内播完);其右上小字 = 上限;表心小字 = 短时余额(贷款时深红负数)
# 位置:挂 hud,摆在血条/氧条**下方**(2026-09-26 用户指定)。
# 数据源:Level0.grain_account(静态;PvP/菜单为 null → 整体隐藏)。

const DIAL := 84.0                 # 表盘直径(像素)
const BIG_FONT := 96               # 大数字字号(与主菜单标题一致)
const SMALL_FONT := 32
const CAP_FONT := 16
const COLOR_RIM := Color8(20, 23, 28)        # 表壳外圈(最深)
const COLOR_CASE := Color8(58, 64, 72)       # 表壳(冷灰)
const COLOR_FACE := Color8(96, 103, 112)     # 盘面(冷灰浅)
const COLOR_TICK := Color8(70, 76, 84)       # 刻度
const COLOR_HAND_LONG := Color8(196, 62, 62)   # 红长针
const COLOR_HAND_SHORT := Color8(235, 238, 242)  # 白短针
const COLOR_TEXT := Color8(232, 236, 242)
const COLOR_TEXT_DIM := Color8(150, 158, 168)
const COLOR_LOAN := Color8(158, 40, 48)      # 贷款深红

var _dial_tex: ImageTexture = null
var _big: Label = null
var _cap: Label = null
var _center: Label = null
var _disp: float = 0.0             # 大数字的滚动显示值(逐点逼近真值)
var _anim_from: float = 0.0        # 本次滚动起点(余额变化瞬间捕获)
var _anim_target: float = 0.0
var _anim_t: float = 1.0           # 0→1;duration 固定 0.2s → "终值确定后 0.2 秒播完"
var _initialized := false
var _tremble_t := 0.0              # 吸收结晶时的颤抖(B5 用)
var _lock_flash_t := 0.0           # 贷款锁定红闪(B6 用)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_to_group("watch_hud")   # 结晶 FX 靠它找表心(屏幕空间目标)
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


## 98px 程序化像素表盘:方块拼圆(与瓦片同风格),冷灰三层次 + 12 刻度。
## 静态 + 无实例依赖:Beta 入口页的卡片图标直接复用这一份(B20)。
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
	# 12 刻度
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
	# 大数字滚动:余额一变就起一段**定长 0.2s 的插值动画**,显示层按整数逐点跳动,
	# 终值确定后 ≤0.2s 必到位(不用指数逼近——那只会"越走越慢"永不到位)。
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
	# 大数字配色:回溯=红、加速=紫、常态=白(用户 2026-09-26 指定)
	var col := COLOR_TEXT
	if TimeField.current != null:
		if TimeField.current.is_rewinding():
			col = Color8(210, 62, 62)
		elif TimeField.current.is_hasting():
			col = Color8(168, 96, 216)
	_big.add_theme_color_override("font_color", col)
	_cap.text = "上限 %d" % int(acc.cap)
	# 表心:短时余额(正=浅灰;贷款=深红负数)
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
	# 白短针:总量 / 上限(一圈)
	var a_short := -PI * 0.5 + TAU * clampf(acc.balance / maxf(acc.cap, 1.0), 0.0, 1.0)
	draw_line(c, c + Vector2(cos(a_short), sin(a_short)) * (DIAL * 0.30), COLOR_HAND_SHORT, 4.0)
	# 红长针:短时窗已用 + 贷款(一圈 = 账户 window;贷款最多再加 loan_max/window 圈 ——
	# 单机 LOAN_LIMIT/SHORT_WINDOW = 1/4 圈;PvP 贷款上限=短时额度 ⇒ 1 整圈)
	var win: float = acc.window if acc.window > 0.0 else TimeParams.SHORT_WINDOW
	var turns := (acc.short_used + acc.loan_used) / win
	var max_turns := 1.0 + (acc.loan_max / win)
	var a_long := -PI * 0.5 + TAU * clampf(turns, 0.0, max_turns)
	var long_col := COLOR_HAND_LONG
	if _lock_flash_t > 0.0 and fmod(_lock_flash_t, 0.16) > 0.08:
		long_col = Color8(255, 90, 90)   # 锁定红闪
	draw_line(c, c + Vector2(cos(a_long), sin(a_long)) * (DIAL * 0.42), long_col, 3.0)
	draw_circle(c, 3.0, COLOR_RIM)


## 吸收结晶时的颤抖(B5 调用)
func tremble() -> void:
	_tremble_t = 0.4


## 贷款锁定红闪(B6 调用)
func flash_locked() -> void:
	_lock_flash_t = 1.2

## 吸收结晶:入账 + 颤抖(结晶 FX 到达时调用;数值动画由 _process 自动追随)
func absorb(amount: int) -> void:
	if Level0.grain_account != null:
		Level0.grain_account.deposit(amount)
	tremble()
