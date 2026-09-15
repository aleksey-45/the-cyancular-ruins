class_name UiFactory
extends RefCounted

# UI 控件工厂(L4 起所有菜单/HUD 控件统一走这里)。
#
# 本来是 KH 菜单里散抄的「加载 ttf + 关抗锯齿 + add_theme_font_size_override」三件套,四份。
# 但字号与像素字体处理这块已经被本项目改过,不再是 KH 的代码 —— 它是我们的不变量,
# 散在四处就守不住(L4 还要写第 2/3/4 份),所以抽到共享静态类里。
#
# ⚠ 两条硬约定:
#   1. **字号必须是 16 的倍数**(16/32/48/64…)。本项目的像素字体(less_perfect_dos_vga)
#      只在 16 倍数下与渲染缩放整数对齐,像素边缘才锐利;非 16 倍数会糊。
#   2. **不要把 separation / custom_minimum_size 这类「布局」度量也强求 16 的倍数**。
#      需要 16 对齐的是字形光栅化,不是间距/尺寸 —— 把 420×64 的按钮改成 416×64、
#      把 separation 22 改成 32 只会破坏版式节奏,不会让字更清晰。
#      (所以 button() 里的 custom_minimum_size 保持原值,别"顺手对齐"。)
#
# 纯静态、无实例状态、不引 autoload:可被任何场景/工具直接调用。
# 注:字体配置的唯一来源是 core/pixel_font.gd 的 PixelFont.shared()(世界空间文本也用同一份);
# 本工厂只负责"怎么用字体建控件",不重复实现字体配置。


# 像素字体:关抗锯齿 / 微调 / 子像素定位,整数倍字号下保持像素锐利。
static func pixel_font() -> FontFile:
	# 字体配置的唯一来源是 core/pixel_font.gd 的 PixelFont.shared()
	# (它负责关抗锯齿/微调/子像素;load 返回共享实例,故全局一致)。
	# 本工厂只负责"怎么用字体建控件",不重复实现字体配置。
	return PixelFont.shared()


# 给任意 Control 套上像素字体 + 字号(size 必须是 16 的倍数,见文件头;违反会在 debug 下 assert)。
#
# ⚠ caveat:本函数硬编码 "font" / "font_size" 两个 theme override 键 —— 这是 Label / Button /
# CheckButton / LineEdit 这类「普通文本控件」读的键。**RichTextLabel 读的是
# normal_font / normal_font_size(以及 bold_font / bold_font_size)**,把 RichTextLabel 传给本函数
# 会静默失败(不报错,但字体与字号都不生效)。这正是 ui/combat_feedback.gd 至今仍
# 自己 load 字体、直接覆写 normal_font/normal_font_size 的原因 —— 那种控件不要走本函数。
static func style_control(c: Control, size: int) -> void:
	assert(size % 16 == 0, "字号必须是 16 的倍数(本项目像素字体只在 16/32/48… 下像素锐利);收到 %d" % size)
	c.add_theme_font_size_override("font_size", size)
	var pf: FontFile = pixel_font()
	if pf != null:
		c.add_theme_font_override("font", pf)


static func label(text: String, size: int, color: Color = Color.WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	style_control(l, size)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


# ── 调色板(全项目 UI 配色的唯一来源)──
#
# 2026-09-13 视觉评析:此前每个界面各自硬编码 Color(...),同一屏里能同时出现 6 种
# 互不相干的色(青/暗青/靛蓝/金/中性灰/纯红),且按钮填充只比底色亮 9 个色阶
# (实测对比度 1.05:1)—— 按钮作为「可点区域」根本看不见。
# 现在颜色只在这里定义,其余文件一律引用;两套明度阶梯:
#   填充 C_BTN_FILL(常态)/ C_BTN_FILL_HI(悬停)/ C_BTN_FILL_DOWN(按下)
#   描边 C_BORDER(常态)/ C_ACCENT(悬停/焦点)/ C_BORDER_DIM(弱化项)
const C_BG          := Color(0.039, 0.059, 0.094)   # 页面底 #0A0F18
const C_SURFACE     := Color(0.071, 0.086, 0.118)   # 面板底 #12161E(不透明)
const C_ROW         := Color(0.086, 0.094, 0.110)   # 列表行底 #16181C
const C_FIELD       := Color(0.106, 0.118, 0.141)   # 输入框底(比行底再亮一档,保证认得出是输入框)
const C_BTN_FILL    := Color(0.106, 0.125, 0.157)   # #1B2028
const C_BTN_FILL_HI := Color(0.137, 0.165, 0.204)   # 悬停
const C_BTN_FILL_DN := Color(0.063, 0.075, 0.098)   # 按下(比常态更暗 = 凹陷感)
# 描边亮度的标定目标(实测,不是拍脑袋):对**页面底** ≥3:1(按钮"看得见"),
# 对**按钮填充** ≥3:1(边框从填充上浮得出来)。
# 第一版取的 #3D4A5A 只到 2.13:1(对页面底)/1.82:1(对填充)—— 在截图里确实偏暗,故上调。
const C_BORDER      := Color(0.361, 0.439, 0.561)   # #5C708F ≈3.8:1 对页面底 / 3.3:1 对填充
const C_BORDER_DIM  := Color(0.250, 0.310, 0.400)   # 弱化项(次要动作/退出)≈2.3:1,刻意低于主按钮
const C_ACCENT      := Color(0.349, 0.851, 0.902)   # 强调青 #59D9E5
const C_DANGER      := Color(0.900, 0.400, 0.400)
const C_TEXT        := Color(0.878, 0.914, 0.949)
const C_TEXT_DIM    := Color(0.510, 0.573, 0.639)   # 占位符/说明文字
const C_WARN        := Color(0.950, 0.850, 0.550)   # 金色:**只**用于「低弹量/耗尽」语义

# 武器槽位格子的三态(2026-09-15,用户指定"未占淡灰 / 已占淡青 / 手持深青")。
#
# ★ **先看底板再配色**:格子的底板是 HUD 那块 `黑 0.1`,而它压在**地图开阔区的浅灰蓝**
#   (#78969F)上 → 实际底板 ≈ #6C8790,**是浅底不是深底**。浅底上"越暗越醒目",
#   所以三态的**明度阶梯**必须是:未占(贴近底板、后退)→ 已占(中)→ 手持(最深、最跳)。
#   (反过来配会出现"空格最抢眼、当前武器最不显眼"的倒挂 —— 这正是这一版改掉的东西。)
# ★ 真正的不变量是「三态两两可区分」+「手持格明度离底板最远」,色相只是表达手段。
#   kh_l3_visual_probe 双向钉住"该是什么色 / 不该是什么色"。
# ★ 色值是**审美值**,以实图为准(同 KILL_COLOR 的注释);调色时先按上面那两条不变量量。
# ★ 2026-09-15 按**浅底实图**(kh_l3_visual_probe 的 l3_slots_on_map)调过一次:
#   初版 EMPTY 的明度几乎正好等于底板 → 空格子**看不见** → 4×2 的格阵形状读不出来,
#   容量指示器等于失效。空格必须"看得见但后退",不能"看不见"。
# ★ 2026-09-15 二次调色(用户:「青色要蓝一点,透明一点」→「格子透明度全部改到 0.5」):
#   两档青从青绿(teal)挪到偏蓝;**三档统一 alpha = 0.5**。
#   三档底色本身的明度阶梯不变(未占最靠近底板 → 手持离底板最远),只是整体变透。
const C_SLOT_EMPTY  := Color(0.510, 0.600, 0.624, 0.5)   # 未占据:淡灰(比底板亮一档 → 看得见但后退)
const C_SLOT_FILLED := Color(0.360, 0.620, 0.920, 0.5)   # 已占据:偏蓝的淡青
const C_SLOT_ACTIVE := Color(0.090, 0.300, 0.680, 0.5)   # 手持那把占的格:更深的蓝 → 最跳

# 按钮描边宽度(px)。像素风:直角、整数边宽,不描圆角。
const BTN_BORDER_W := 2


# 描边式按钮的底:暗填充 + 亮描边(直角)。像素游戏里描边比「提亮填充」更省墨,
# 也更容易和已有的暗色界面相处 —— 只是把「按钮存在」这件事补上。
static func _btn_box(fill: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = border
	sb.set_border_width_all(BTN_BORDER_W)
	sb.set_corner_radius_all(0)
	sb.content_margin_left = 14.0
	sb.content_margin_right = 14.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	return sb


# 面板底:不透明(半透明面板会让下层菜单的文字透上来形成重影,见版本信息面板)。
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


# 列表行底(房间行等):比页面底亮一档,让「行」这个物体存在。
# (默认主题下房间行与页面底实测 1.01:1 —— 行边界不可见,列表像一排悬空文字。)
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


# 列表行按钮:整行可点。常态就是行底(无边框,行与行之间有分隔感),
# 悬停才浮出强调色描边 —— 行不再是一排悬空的文字。
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


# 滑条:默认主题的轨道细到几乎看不见(色相滑条整条不可见,只剩一个孤零零的滑钮,
# 看着像页面上的一个噪点)。给一条实心轨道 + 已填充段用强调色。
static func style_slider(s: Slider) -> void:
	var track := StyleBoxFlat.new()
	track.bg_color = C_BORDER_DIM
	track.set_corner_radius_all(0)
	track.content_margin_top = 4.0
	track.content_margin_bottom = 4.0
	s.add_theme_stylebox_override("slider", track)
	s.add_theme_stylebox_override("grabber_area", _row_sb(C_ACCENT, C_ACCENT))
	s.add_theme_stylebox_override("grabber_area_highlight", _row_sb(C_ACCENT, C_ACCENT))


# 输入框:默认主题的 LineEdit 底几乎与页面底同色(实测 1.01:1),看不出是输入框;
# 且占位符与真实输入同样亮,分不清「填了没填」。这里同时钉住底、边框、占位符色。
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


# 把整组状态样式套到任意 Button/CheckButton 上。variant:
#   "primary" 常态按钮(描边 #3D4A5A,悬停转青)
#   "quiet"   次要动作(退出等)—— 常态就压暗,不跟主行动抢注意力
static func style_button(b: Button, variant: String = "primary") -> void:
	var dim := variant == "quiet"
	var base := C_BORDER_DIM if dim else C_BORDER
	b.add_theme_stylebox_override("normal", _btn_box(C_BTN_FILL, base))
	b.add_theme_stylebox_override("hover", _btn_box(C_BTN_FILL_HI, C_ACCENT))
	b.add_theme_stylebox_override("pressed", _btn_box(C_BTN_FILL_DN, C_ACCENT))
	# focus 用同一块底:标题下那颗默认的焦点虚线框在像素风里是噪点。
	b.add_theme_stylebox_override("focus", _btn_box(C_BTN_FILL, C_ACCENT))
	b.add_theme_stylebox_override("disabled", _btn_box(C_BTN_FILL, C_BORDER_DIM))
	var fg := C_TEXT_DIM if dim else C_TEXT
	b.add_theme_color_override("font_color", fg)
	b.add_theme_color_override("font_hover_color", C_ACCENT)
	b.add_theme_color_override("font_focus_color", fg)
	b.add_theme_color_override("font_pressed_color", C_ACCENT)
	b.add_theme_color_override("font_disabled_color", C_TEXT_DIM)


# ── 开关图形 ──
#
# Godot 默认主题的 CheckButton:开 = 一条浅灰药丸,关 = **一个小灰点、轨道不可见**。
# 也就是说状态一变,控件的**形状**都变了 —— 用户看不出这里有个开关,更不知道怎么点它。
# 自绘一对图标,开/关都是完整的胶囊轨道,只有颜色与滑块位置不同。
const SWITCH_W := 40
const SWITCH_H := 22
const SWITCH_TRACK_OFF := Color(0.180, 0.212, 0.259)   # 关:暗轨道(仍在暗底上看得见轮廓)

static var _sw_icons: Array = []


# 在 img 上画一个圆角胶囊(r = 半高即胶囊)。纯 set_pixel,不依赖绘制 API。
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
	# 滑块:开在右、关在左(位置本身也表状态,不只靠颜色)
	var kr := SWITCH_H / 2.0 - 3.0
	var kx := float(SWITCH_W) - float(SWITCH_H) / 2.0 if on else float(SWITCH_H) / 2.0
	_capsule(img, int(kx - kr), 3, int(kx + kr), SWITCH_H - 3, kr, Color(1, 1, 1))
	return ImageTexture.create_from_image(img)


# [unchecked, checked] —— 懒建一次,全局共用同一对贴图。
static func switch_icons() -> Array:
	if _sw_icons.is_empty():
		_sw_icons = [_make_switch(false), _make_switch(true)]
	return _sw_icons


# 勾选框/开关:字体走本工厂,图形换自绘胶囊(见上)。
static func style_check(cb: CheckButton, size: int) -> void:
	style_control(cb, size)
	cb.add_theme_color_override("font_color", C_TEXT)
	cb.add_theme_color_override("font_hover_color", C_ACCENT)
	cb.add_theme_color_override("font_pressed_color", C_ACCENT)
	cb.add_theme_color_override("font_focus_color", C_TEXT)
	var ic := switch_icons()
	cb.add_theme_icon_override("unchecked", ic[0])
	cb.add_theme_icon_override("checked", ic[1])


static func button(text: String, size: int, min_size: Vector2 = Vector2(420, 64),
		variant: String = "primary") -> Button:
	var b := Button.new()
	b.text = text
	style_control(b, size)
	# 默认 420×64 是主菜单按钮列的布局度量,故意不凑 16 的倍数(见文件头第 2 条)。
	# 尺寸不合场景的调用方(设置菜单的键位格 200×40、返回键 280×48)直接传 min_size,
	# 不必再事后覆写 custom_minimum_size。
	b.custom_minimum_size = min_size
	style_button(b, variant)
	# 点击音不在这里挂:调用方的 handler(close/go_menu)各自会响一声,而 ESC 走的也是同两条
	# 路径 —— 这里再挂一次就是同帧同调两个播放器("ui" 不在 Sfx.PITCH_VARIATION 里,音高也一样),
	# 是能听出来的双响。统一由状态转移出声(键盘与点击同源)。
	return b

# ── 行式控件与杂项(2026-09-14 补齐:原先三个页面各手抄一份,注释都抄了三遍)──
# 两个"行"的口共用同一个形状:**定宽标签列 + 紧邻控件**。标签列宽由调用方给(label_w)——
# 各页面的数值**本就不同**(设置页 320 / 多人页 440),是各自的版式调参,不为统一而统一。

# 递归给子树套像素字体(跳过容器:容器的 font 不影响子控件)。
static func apply_font_recursive(root: Node) -> void:
	if root is Control and not (root is PanelContainer or root is VBoxContainer or root is HBoxContainer 			or root is GridContainer or root is ScrollContainer):
		var pf: FontFile = pixel_font()
		if pf != null:
			(root as Control).add_theme_font_override("font", pf)
	for n in root.get_children():
		apply_font_recursive(n)


# 色相(0-360°)→ 预览色。两个大厅页原先各一份(逐字相同):色相只作"角色色"提示用。
static func hue_preview_color(hue_deg: float) -> Color:
	return Color.from_hsv(fposmod(hue_deg, 360.0) / 360.0, 0.75, 1.0)


# 开关行 = **定宽标签列 + 紧邻开关**。为什么必须定宽:裸 CheckButton 被 VBox 拉到容器全宽,
# 标签与开关隔开几百像素,两者读成不相干的元素(2026-09-13 视觉评析)。定宽列同时让同一列的
# 多个开关纵向对齐。label_w 见上(各页面自己那组数值)。
static func check_row(text: String, initial: bool, label_w: float,
		on_toggle: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	var lab := label(text, 32, C_TEXT)
	lab.custom_minimum_size = Vector2(label_w, 0)
	lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lab)
	var cb := CheckButton.new()
	cb.button_pressed = initial
	cb.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	style_check(cb, 32)
	cb.toggled.connect(func(on: bool) -> void:
		Sfx.play("switch")
		on_toggle.call(on))
	row.add_child(cb)
	return row


# 滑条行 = **定宽标签列 + 铺满剩余宽度的滑条**(与 check_row 共用同一套版式节奏,
# 故两者的 label_w 应取同一个值 → 滑条与开关在同一页里纵向对齐成一列)。
static func slider_row(text: String, initial: float, label_w: float,
		on_change: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	var l := label(text, 32, C_TEXT)
	l.custom_minimum_size = Vector2(label_w, 0)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(l)
	var sl := HSlider.new()
	sl.min_value = 0.0
	sl.max_value = 1.0
	sl.step = 0.05
	sl.value = initial
	# 铺满剩余宽度(原先固定 360 宽,右侧空着、拖拽命中区也偏小)。
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.custom_minimum_size = Vector2(360, 28)
	style_slider(sl)
	sl.value_changed.connect(func(v: float) -> void: on_change.call(v))
	row.add_child(sl)
	return row


# 绝对定位的输入框(挂在 parent 下)。size 由调用方给:各页面原值不同(240×36 / 250×40),
# 属各自版式,不为统一而改。
static func line_edit(parent: Node, pos: Vector2, size: Vector2, placeholder: String,
		initial: String) -> LineEdit:
	var le := LineEdit.new()
	le.position = pos
	le.size = size
	le.placeholder_text = placeholder
	le.text = initial
	style_control(le, 16)   # 16 = 引擎默认主题字号,与 KH 原观感一致
	style_line_edit(le)
	parent.add_child(le)
	return le
