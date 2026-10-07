class_name UiFactory
extends RefCounted

# 全局 UI 控件工厂：
# 统一管理菜单与 HUD 的主题样式、字体规格、基础控件构建与全局调色板。
# 字号统一遵循 16 的整数倍规格以保障像素字体渲染清晰锐利。

# 获取全局共享像素字体
static func pixel_font() -> FontFile:
	return PixelFont.shared()


# 为目标控件统一配置像素字体与字号
static func style_control(c: Control, size: int) -> void:
	assert(size % 16 == 0, "字号必须是 16 的倍数以保持像素对齐; 传入值为 %d" % size)
	c.add_theme_font_size_override("font_size", size)
	var pf: FontFile = pixel_font()
	if pf != null:
		c.add_theme_font_override("font", pf)


static func label(text: String, size: int, color: Color = C_WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	style_control(l, size)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


# 对昵称进行等宽约束截断与留白对齐
static func fit_name(s: String, max_units: int) -> String:
	var units := 0
	var out := ""
	for i in s.length():
		var w := 2 if s.unicode_at(i) > 0x2E80 else 1
		if units + w > max_units:
			out += "…"
			units += 1
			break
		units += w
		out += s[i]
	while units < max_units:
		out += " "
		units += 1
	return out


# ── 全局统一调色板 ──

const C_BG          := Color(0.039, 0.059, 0.094)   # 页面底色 #0A0F18
const C_SURFACE     := Color(0.071, 0.086, 0.118)   # 面板底色 #12161E
const C_ROW         := Color(0.086, 0.094, 0.110)   # 列表行底色 #16181C
const C_FIELD       := Color(0.106, 0.118, 0.141)   # 输入框底色
const C_BTN_FILL    := Color(0.106, 0.125, 0.157)   # 按钮常态填充
const C_BTN_FILL_HI := Color(0.137, 0.165, 0.204)   # 按钮悬停填充
const C_BTN_FILL_DN := Color(0.063, 0.075, 0.098)   # 按钮按下填充
const C_BORDER      := Color(0.361, 0.439, 0.561)   # 常规边框描边
const C_BORDER_DIM  := Color(0.250, 0.310, 0.400)   # 次要/弱化描边
const C_ACCENT      := Color(0.349, 0.851, 0.902)   # 强调青色
const C_DANGER      := Color(0.900, 0.400, 0.400)   # 警示红色
const C_TEXT        := Color(0.878, 0.914, 0.949)   # 正文主色
const C_TEXT_DIM    := Color(0.510, 0.573, 0.639)   # 占位符与次要说明文字
const C_WHITE       := Color(1, 1, 1)               # 纯白字色
const C_WARN        := Color(0.950, 0.850, 0.550)   # 弹药低量警告金色

# 玩法模式区分色
const C_MODE_TEAM   := Color(0.627, 0.549, 1.0)      # 团队模式标志色
const C_MODE_ROYALE := Color(0.910, 0.639, 0.239)    # 大乱斗模式标志色

# 菜单专属视觉配色
const C_HEADER     := Color("#1B242C")   # 标题带底色与按钮常规填充
const C_INNER      := Color("#1E2830")   # 面板内层高亮线
const C_EDGE       := Color("#46545F")   # 按钮默认外描边
const C_GOLD       := Color("#E0A94F")   # 琥珀金标题与主要交互描边
const C_TEXT_MUTE  := Color("#6C7885")   # 禁用文本暗色
const C_TRANSPARENT := Color(0, 0, 0, 0) # 完全透明

# 断线与宽限期提示色
const C_GRACE       := Color(0.72, 0.62, 0.90)

# HUD 通用底板半透明背景色
const C_PLATE       := Color(0, 0, 0, 0.1)

# 团队对抗队伍阵营色
const C_TEAM_A := Color(99.0 / 255.0, 155.0 / 255.0, 1.0)     # A 队基础蓝
const C_TEAM_B := Color(128.0 / 255.0, 244.0 / 255.0, 1.0)    # B 队青色


# 网络延迟 Ping 阈值颜色映射
# 统一供各模式 HUD 界面调用，保持网络质量视觉指示一致。
static func ping_color(ms: int) -> Color:
	if ms < 60:
		return Color(0.45, 0.9, 0.45)      # 绿色：延迟良好（<60ms）
	if ms < 100:
		return Color(1.0, 0.85, 0.25)      # 黄色：网络正常（60-100ms）
	if ms < 150:
		return Color(1.0, 0.6, 0.15)       # 橙色：延迟偏高（100-150ms）
	return Color(1.0, 0.3, 0.3)            # 红色：网络卡顿（>=150ms）


# 武器槽位格子的三态显示色彩：未占淡灰、已占淡青、手持深青。
#
# 底板采用 HUD 黑色半透明材质，叠在地图开阔区的浅灰蓝背景（#78969F）上。
# 在浅色底板上，明度越低越突出，因此三态明度阶梯配置为：
# 未占据（贴近底板明度，视觉后退）-> 已占据（中等明度）-> 手持选中（深色高反差，最醒目）。
# 核心约束保证三态两两可清晰区分，且手持选中格与底板明度差最大。
# 自动化测试会对各状态颜色值及对比度进行校验。
# 三档颜色统一采用 0.5 不透明度，确保半透明透光感一致。
const C_SLOT_EMPTY  := Color(0.510, 0.600, 0.624, 0.5)   # 未占据：淡灰，贴近底板明度
const C_SLOT_FILLED := Color(0.360, 0.620, 0.920, 0.5)   # 已占据：偏蓝的淡青色
const C_SLOT_ACTIVE := Color(0.090, 0.300, 0.680, 0.5)   # 手持当前武器：深蓝色，对比最醒目

# 按钮描边宽度（像素）。直角描边，维持像素美术风格。
const BTN_BORDER_W := 2


# 描边式按钮样式：暗色填充搭配亮色直角描边。
# 在像素风格界面中，明亮描边具有良好的边缘界定效果，且能自然融入暗色背景。
#
# 基础按钮样式由 menu_button 与 style_button 共用。
# 按钮默认内容边距设置为水平 40 像素、垂直 20 像素，按钮最小高度为字号加 40 像素。
# 绝对定位布局的界面容器需注意行高设置，避免相邻控件产生布局错位。
static func _btn_box(fill: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = border
	sb.set_border_width_all(BTN_BORDER_W)
	sb.set_corner_radius_all(0)
	sb.content_margin_left = 40.0
	sb.content_margin_right = 40.0
	sb.content_margin_top = 20.0
	sb.content_margin_bottom = 20.0
	return sb


# 基础面板样式：采用不透明背景，避免下层界面文字透光导致重影干扰。
static func panel_box(border: bool = true) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_SURFACE
	sb.set_corner_radius_all(0)
	if border:
		sb.border_color = C_BORDER
		sb.set_border_width_all(BTN_BORDER_W)
	sb.content_margin_left = 28.0
	sb.content_margin_right = 28.0
	sb.content_margin_top = 20.0
	sb.content_margin_bottom = 20.0
	return sb


# 菜单面板容器：创建双层边框的内凹浮雕质感面板（外层深色边缘，内层高亮边缘）。
#
# 该函数独立于基础 panel_box，以便在保持 HUD 现有样式的前提下，专门服务于菜单层。
# 底层使用两层嵌套的 PanelContainer 实现双色边框。子节点内容需添加至内部的 Body 容器中：
#   var p := UiFactory.menu_panel()
#   (p.get_node("Body") as Container).add_child(vbox)
static func menu_panel(padding: Vector2 = Vector2(64, 46)) -> PanelContainer:
	var outer := PanelContainer.new()
	skin_menu_panel(outer, padding)
	return outer


# 为既有的 PanelContainer 赋予菜单双层边框样式，并将原有子节点转移至新建的 Body 容器内。
# 功能逻辑与 menu_panel 保持一致，用于支持预设在场景文件中的面板结构动态套用主题。
# 本方法具有幂等性，检测到已存在 Body 容器时会直接返回，避免重复嵌套。
static func skin_menu_panel(outer: PanelContainer, padding: Vector2) -> void:
	if outer.get_node_or_null("Body") != null:
		return
	var osb := StyleBoxFlat.new()
	osb.bg_color = C_SURFACE
	osb.border_color = C_BORDER
	osb.set_border_width_all(1)
	osb.set_corner_radius_all(0)
	# 不设置 content_margin，此时 StyleBox 默认以边框宽度（1 像素）产生内缩偏移，
	# 确保内层亮线与外层深线位于不同像素环上，形成清晰的双线效果。
	outer.add_theme_stylebox_override("panel", osb)

	var body := PanelContainer.new()
	body.name = "Body"   # 标准容器节点名称，调用方通过 get_node("Body") 获取内容挂载点
	var isb := StyleBoxFlat.new()
	isb.bg_color = Color(0, 0, 0, 0)   # 内层背景完全透明，仅渲染高亮边框线
	isb.border_color = C_INNER
	isb.set_border_width_all(1)
	isb.set_corner_radius_all(0)
	isb.content_margin_left = padding.x
	isb.content_margin_right = padding.x
	isb.content_margin_top = padding.y
	isb.content_margin_bottom = padding.y
	body.add_theme_stylebox_override("panel", isb)
	# 将外层现有的子节点转移至 Body 内部，注意需先从父节点移除再添加
	for c in outer.get_children():
		outer.remove_child(c)
		body.add_child(c)
	outer.add_child(body)


# 菜单专用按钮：提供多种视觉变体。
# - primary：常规主按钮
# - quiet：次要按钮（如退出或取消），色彩适度弱化
# - gold：关键推荐动作（如开始游戏或创建房间），采用金色描边与文字
# - accent：主行动按钮，采用青色强调描边
static func menu_button(text: String, size: int, min_size: Vector2 = Vector2(640, 88),
		variant: String = "primary") -> Button:
	var b := Button.new()
	b.text = text
	style_control(b, size)
	b.custom_minimum_size = min_size
	var edge := C_EDGE
	var fg := C_TEXT
	if variant == "quiet":
		edge = C_BORDER_DIM
		# 次要按钮文字颜色选用 C_TEXT_DIM，兼顾弱化层级与亮度阈值判定
		fg = C_TEXT_DIM
	elif variant == "gold":
		edge = C_GOLD
		fg = C_GOLD
	elif variant == "accent":
		# 主行动按钮：常态边框采用强调色 C_ACCENT，悬停时文字变为强调色
		edge = C_ACCENT
		fg = C_TEXT
	b.add_theme_stylebox_override("normal", _btn_box(C_HEADER, edge))
	b.add_theme_stylebox_override("hover", _btn_box(C_BTN_FILL_HI, C_ACCENT))
	b.add_theme_stylebox_override("pressed", _btn_box(C_BTN_FILL_DN, C_ACCENT))
	b.add_theme_stylebox_override("focus", _btn_box(C_HEADER, C_ACCENT))
	b.add_theme_stylebox_override("disabled", _btn_box(C_HEADER, C_BORDER_DIM))
	b.add_theme_color_override("font_color", fg)
	b.add_theme_color_override("font_hover_color", C_ACCENT)
	b.add_theme_color_override("font_focus_color", fg)
	b.add_theme_color_override("font_pressed_color", C_ACCENT)
	b.add_theme_color_override("font_disabled_color", C_TEXT_MUTE)
	return b


# 标题条：深色背景横条，仅在底部带有单像素分界线，内置金色标题文本。
# 仅绘制底部分界线可避免界面形成过多封闭方框，与菜单面板的结构层次相契合。
static func header_strip(text: String, size: int = 32) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_HEADER
	sb.set_corner_radius_all(0)
	sb.border_width_left = 0
	sb.border_width_right = 0
	sb.border_width_top = 0
	sb.border_width_bottom = 1
	sb.border_color = C_BORDER
	# 左内边距设为 0，使标题文本与正文内容左对齐；右内边距 40，上下各 20 像素维持呼吸感
	sb.content_margin_left = 0.0
	sb.content_margin_right = 40.0
	sb.content_margin_top = 20.0
	sb.content_margin_bottom = 20.0
	p.add_theme_stylebox_override("panel", sb)
	p.add_child(label(text, size, C_GOLD))
	return p


# 列表行底板样式：略高于主背景明度，提供清晰的列表项视觉区隔。
static func row_box() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_ROW
	sb.set_corner_radius_all(0)
	sb.content_margin_left = 16.0
	sb.content_margin_right = 16.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	return sb


static func _row_sb(fill: Color, border: Color) -> StyleBoxFlat:
	var sb := row_box()
	sb.bg_color = fill
	sb.border_color = border
	sb.set_border_width_all(2)
	return sb


# 列表项整行交互按钮：常态无边框融入行底，悬停与按下时显示强调边框。
static func style_row_button(b: Button) -> void:
	b.add_theme_stylebox_override("normal", _row_sb(C_ROW, C_ROW))
	b.add_theme_stylebox_override("hover", _row_sb(C_BTN_FILL_HI, C_ACCENT))
	b.add_theme_stylebox_override("pressed", _row_sb(C_BTN_FILL_DN, C_ACCENT))
	b.add_theme_stylebox_override("focus", _row_sb(C_ROW, C_ROW))
	b.add_theme_stylebox_override("disabled", _row_sb(C_ROW, C_ROW))
	b.add_theme_color_override("font_color", C_TEXT)
	b.add_theme_color_override("font_hover_color", C_ACCENT)
	b.add_theme_color_override("font_pressed_color", C_ACCENT)
	b.add_theme_color_override("font_focus_color", C_TEXT)


# 滑动条样式配置：配置清晰可见的实心滑轨，已填充部分使用强调色高亮。
static func style_slider(s: Slider) -> void:
	var track := StyleBoxFlat.new()
	track.bg_color = C_BORDER_DIM
	track.set_corner_radius_all(0)
	track.content_margin_top = 4.0
	track.content_margin_bottom = 4.0
	s.add_theme_stylebox_override("slider", track)
	s.add_theme_stylebox_override("grabber_area", _row_sb(C_ACCENT, C_ACCENT))
	s.add_theme_stylebox_override("grabber_area_highlight", _row_sb(C_ACCENT, C_ACCENT))


# 输入框样式配置：统一配置背景底色、边框与占位符文本颜色。
static func style_line_edit(le: LineEdit) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_FIELD
	sb.border_color = C_BORDER_DIM
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(0)
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	le.add_theme_stylebox_override("normal", sb)
	var focus := sb.duplicate() as StyleBoxFlat
	focus.border_color = C_ACCENT
	le.add_theme_stylebox_override("focus", focus)
	le.add_theme_color_override("font_color", C_TEXT)
	le.add_theme_color_override("font_placeholder_color", C_TEXT_DIM)
	le.add_theme_color_override("caret_color", C_ACCENT)


# 通用按钮样式配置：统一设置常态、悬停、按下与禁用状态的背景及文字颜色。
# - primary：常规操作按钮，常态边框适度可见，悬停时高亮
# - quiet：次要操作按钮（如退出或取消），常态采用弱化暗边框
static func style_button(b: Button, variant: String = "primary") -> void:
	var dim := variant == "quiet"
	var base := C_BORDER_DIM if dim else C_BORDER
	b.add_theme_stylebox_override("normal", _btn_box(C_BTN_FILL, base))
	b.add_theme_stylebox_override("hover", _btn_box(C_BTN_FILL_HI, C_ACCENT))
	b.add_theme_stylebox_override("pressed", _btn_box(C_BTN_FILL_DN, C_ACCENT))
	b.add_theme_stylebox_override("focus", _btn_box(C_BTN_FILL, C_ACCENT))
	b.add_theme_stylebox_override("disabled", _btn_box(C_BTN_FILL, C_BORDER_DIM))
	var fg := C_TEXT_DIM if dim else C_TEXT
	b.add_theme_color_override("font_color", fg)
	b.add_theme_color_override("font_hover_color", C_ACCENT)
	b.add_theme_color_override("font_focus_color", fg)
	b.add_theme_color_override("font_pressed_color", C_ACCENT)
	b.add_theme_color_override("font_disabled_color", C_TEXT_DIM)


# 开关控件图形尺寸与颜色定义
# 自绘开关图标：开与关状态均保持完整的胶囊滑轨轮廓，仅改变填充色与滑块位置。
const SWITCH_W := 40
const SWITCH_H := 22
const SWITCH_TRACK_OFF := Color(0.180, 0.212, 0.259)   # 关闭状态下的暗色滑轨

static var _sw_icons: Array = []


# 在图像上绘制实心圆角胶囊形状（以半高为圆角半径）。
static func _capsule(img: Image, x0: int, y0: int, x1: int, y1: int, r: float, col: Color) -> void:
	for y in range(y0, y1):
		for x in range(x0, x1):
			var fx := float(x) + 0.5
			var fy := float(y) + 0.5
			var cx := clampf(fx, float(x0) + r, float(x1) - r)
			var cy := clampf(fy, float(y0) + r, float(y1) - r)
			var dx := fx - cx
			var dy := fy - cy
			if dx * dx + dy * dy <= r * r:
				img.set_pixel(x, y, col)


static func _make_switch(on: bool) -> ImageTexture:
	var img := Image.create(SWITCH_W, SWITCH_H, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	_capsule(img, 0, 0, SWITCH_W, SWITCH_H, SWITCH_H / 2.0,
			C_ACCENT if on else SWITCH_TRACK_OFF)
	# 滑块位置：开启靠右，关闭靠左
	var kr := SWITCH_H / 2.0 - 3.0
	var kx := float(SWITCH_W) - float(SWITCH_H) / 2.0 if on else float(SWITCH_H) / 2.0
	_capsule(img, int(kx - kr), 3, int(kx + kr), SWITCH_H - 3, kr, Color(1, 1, 1))
	return ImageTexture.create_from_image(img)


# 获取自绘开关纹理数组：[未选中纹理, 选中纹理]，全局单例复用
static func switch_icons() -> Array:
	if _sw_icons.is_empty():
		_sw_icons = [_make_switch(false), _make_switch(true)]
	return _sw_icons


# 复选框与开关样式配置：统一文字字号与自绘胶囊滑轨图标
static func style_check(cb: CheckButton, size: int) -> void:
	style_control(cb, size)
	cb.add_theme_color_override("font_color", C_TEXT)
	cb.add_theme_color_override("font_hover_color", C_ACCENT)
	cb.add_theme_color_override("font_pressed_color", C_ACCENT)
	cb.add_theme_color_override("font_focus_color", C_TEXT)
	var ic := switch_icons()
	cb.add_theme_icon_override("unchecked", ic[0])
	cb.add_theme_icon_override("checked", ic[1])


# 创建通用按钮：可指定文本、字号、最小尺寸及样式变体
static func button(text: String, size: int, min_size: Vector2 = Vector2(420, 64),
		variant: String = "primary") -> Button:
	var b := Button.new()
	b.text = text
	style_control(b, size)
	b.custom_minimum_size = min_size
	style_button(b, variant)
	return b

# 界面通用辅助方法

# 递归为控件节点树设置像素字体（跳过布局容器）
static func apply_font_recursive(root: Node) -> void:
	if root is Control and not (root is PanelContainer or root is VBoxContainer or root is HBoxContainer \
			or root is GridContainer or root is ScrollContainer):
		var pf: FontFile = pixel_font()
		if pf != null:
			(root as Control).add_theme_font_override("font", pf)
	for n in root.get_children():
		apply_font_recursive(n)


# 色相角度（0-360 度）转换为角色预览色彩
static func hue_preview_color(hue_deg: float) -> Color:
	return Color.from_hsv(fposmod(hue_deg, 360.0) / 360.0, 0.75, 1.0)


# 在指定父节点下创建绝对定位单行文本输入框
static func line_edit(parent: Node, pos: Vector2, size: Vector2, placeholder: String,
		initial: String) -> LineEdit:
	var le := LineEdit.new()
	le.position = pos
	le.size = size
	le.placeholder_text = placeholder
	le.text = initial
	style_control(le, 16)
	style_line_edit(le)
	parent.add_child(le)
	return le
