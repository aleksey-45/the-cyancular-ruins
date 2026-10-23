class_name UiFactory
extends RefCounted

# UI 控件工厂:全项目菜单/HUD 控件的唯一入口;纯静态、无实例状态、不引 autoload,任何场景/工具可直接调用。
# ★ 字号必须是 16 的倍数(像素字体只在 16/32/48… 下与渲染缩放整数对齐,像素边缘才锐利),违反会被 style_control 当场 assert。
# ★ separation / custom_minimum_size 这类布局度量不要求 16 的倍数:16 对齐针对字形光栅化,不是间距/尺寸 —— 把 420×64 的
#   按钮改成 416×64、把 separation 22 改成 32 只会破坏版式节奏,所以 button() 里的默认尺寸保持原值,别顺手对齐。
# 字体配置的唯一来源是 core/pixel_font.gd 的 PixelFont.shared();本工厂只负责怎么用字体建控件。


static func pixel_font() -> FontFile:
	return PixelFont.shared()


# 给任意 Control 套上像素字体 + 字号(size 必须是 16 的倍数,见文件头)。
# ⚠ 只硬编码 font / font_size 两个 override 键(Label / Button / CheckButton / LineEdit 这类普通文本控件读它们):
#   RichTextLabel 读的是 normal_font / normal_font_size,传给它不报错但字体与字号都不生效 ⇒ 那种控件不要走本函数。
static func style_control(c: Control, size: int) -> void:
	assert(size % 16 == 0, "字号必须是 16 的倍数(本项目像素字体只在 16/32/48… 下像素锐利);收到 %d" % size)
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


# 昵称定宽成一列:按显示宽度(汉字/全角算 2 个半角单位)截断、超出补 …、不足用半角空格补满 ——
# 截断保证后面的列不被顶出面板,补满让各列在行与行之间纵向对齐;★ 单位宽度按字体算(32px 字号下半角 16px / 全角 32px),换字体要重算 max_units。
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


# ── 调色板(全项目 UI 配色的唯一来源:颜色只在这里定义,其余文件一律引用,不许再写 Color 字面量)──
const C_BG          := Color(0.039, 0.059, 0.094)   # 页面底 #0A0F18
const C_SURFACE     := Color(0.071, 0.086, 0.118)   # 面板底 #12161E(不透明)
const C_ROW         := Color(0.086, 0.094, 0.110)   # 列表行底 #16181C
const C_FIELD       := Color(0.106, 0.118, 0.141)   # 输入框底(比行底再亮一档,保证认得出是输入框)
const C_BTN_FILL    := Color(0.106, 0.125, 0.157)   # #1B2028
const C_BTN_FILL_HI := Color(0.137, 0.165, 0.204)   # 悬停
const C_BTN_FILL_DN := Color(0.063, 0.075, 0.098)   # 按下(比常态更暗 = 凹陷感)
# 描边亮度标定目标(实测,不是拍脑袋):对页面底 ≥3:1、对按钮填充 ≥3:1 —— 第一版 #3D4A5A 只到 2.13:1 / 1.82:1,偏暗故上调。
const C_BORDER      := Color(0.361, 0.439, 0.561)   # #5C708F ≈3.8:1 对页面底 / 3.3:1 对填充
const C_BORDER_DIM  := Color(0.250, 0.310, 0.400)   # 弱化项(次要动作/退出)≈2.3:1,刻意低于主按钮
const C_ACCENT      := Color(0.349, 0.851, 0.902)   # 强调青 #59D9E5
const C_DANGER      := Color(0.900, 0.400, 0.400)
const C_TEXT        := Color(0.878, 0.914, 0.949)
const C_TEXT_DIM    := Color(0.510, 0.573, 0.639)   # 占位符/说明文字
# ★★ C_WHITE 不是 C_TEXT(C_TEXT 略带蓝,单通道差 0.122):别把走默认色的调用点统一成 C_TEXT —— 深底上肉眼几乎看不出,但迁移的判据是逐像素(设置页键位表那 11 个动作名实测差 9220 个像素)。
const C_WHITE       := Color(1, 1, 1)
const C_WARN        := Color(0.950, 0.850, 0.550)   # 金色:只用于「低弹量/耗尽」语义

# ── 模式色:只在菜单系用(房卡标题带 / 筛选器),与对局内颜色无关;★ 3v3 刻意不用蓝 —— #639BFF 就是 C_TEAM_A,而队色在 3v3 里有玩法语义(一眼看出谁是队友);1v1 直接复用 C_ACCENT,不另立同值 token。
const C_MODE_TEAM   := Color(0.627, 0.549, 1.0)      # #A08CFF 紫
const C_MODE_ROYALE := Color(0.910, 0.639, 0.239)    # #E8A33D 琥珀

# ── 菜单系视觉(方向 B「遗迹青铜」):只给菜单屏用,对局内 HUD 一律不用它们,也不会因它们的加入而改变一个像素 ──
# ★★ 上面那批 token(C_ACCENT / C_TEXT / C_TEXT_DIM / C_DANGER / C_WARN / C_PLATE / C_SLOT_* / C_TEAM_* / C_GRACE / C_MODE_*)一个都不许改 ——
#   ui/hud/ 下的脚本读它们;C_SURFACE / C_BORDER 还被对局内重连横幅 status_banner.gd 的 panel_box(false) 读,C_BG / C_FIELD 只被菜单系读。冻结点以 HUD 为准。
# ★ 色值统一写 hex 字符串 Color(#RRGGBB)(对 8bit 精确),浮点反算会与探针 hex 期望差 1/255;⚠ 冻结守卫 menu_style_probe 已删(2026-10-09)⇒ 这批色值今天零自动化守卫。
const C_HEADER     := Color("#1B242C")   # 标题带底 / 按钮填充
const C_INNER      := Color("#1E2830")   # 面板内亮线(凿刻感的来源)
const C_EDGE       := Color("#46545F")   # 按钮描边
const C_GOLD       := Color("#E0A94F")   # 琥珀:分区标题 / 主行动按钮
const C_TEXT_MUTE  := Color("#6C7885")   # 比 C_TEXT_DIM 更弱一档(禁用)

# ★ 全透明。唯一理由:凿刻面板是两层 PanelContainer,内层只画 C_INNER 亮线、不画底(有底会盖掉外层 C_SURFACE),
#   而 StyleBoxFlat 的 bg_color 默认是不透明灰 ⇒ 不画底必须显式写成透明,且必须是一个具名 token(调色板纪律);⚠ 它不是 C_PLATE。
const C_TRANSPARENT := Color(0, 0, 0, 0)

# ── 断线「掉线中」语义色:只给某人掉线中、还在宽限期内、可能回来这一个语义用 —— 不复用 C_WARN(钉死「弹夹见底」)/ C_DANGER(「离开」,不可逆终态)/ C_TEXT_DIM(「复活中」)。
# ⚠ 对比度如实记、不声称达标:底板 ≈#6C8790 上本色 #B89EE6 只有 1.65:1(本项目标准文本色 C_TEXT 也只有 3.11:1);色值是审美值,以实图为准。
const C_GRACE       := Color(0.72, 0.62, 0.90)      # #B89EE6

# ── 底板色(唯一数值源):HUD 元素一律垫它(黑 0.1;用户看过实图后定的,别拿对比度理由调回去)──
# ★ 四个 .gd 落点是别名/引用(hud.gd / weapon_slots.gd / world_label.gd 的 PLATE_COLOR、royale_hud.gd 的 _plate_box),不含字面量;
#   ui/pvp_hud.tscn / ui/team_hud.tscn 的 bg_color 是结构上无法派生的副本(.tscn 引用不到 GDScript 的 const)⇒ 改色必须手工同步那两处 —— 钉住两者逐位相等的 ui_palette_single_source_smoke 已删(2026-10-09),今天零守卫。★ 例外:大乱斗排行榜 royale_hud._board_bg 单独是 0.25(用户点名排除);Mask / _mask 是全屏压暗罩,不是底板。
const C_PLATE       := Color(0, 0, 0, 0.1)

# ── 队伍色(3v3;用户定:队 1 = 蓝、队 2 = 青,与 1v1 的 P1/P2 同一套)。队色是能玩的必要条件(一眼看出谁是队友),不是审美 ──
# ★ 三个消费点同源(scenes/team_game.gd 的 _team_color:头顶 ID 文字色 / 小地图点位色 / 身体染色;身体那处走 PvpMatchClient._apply_tint 的第三参,换算成 modulate 比值让像素恰好等于本色)。
# ⚠ 原先写的「与底板对比 ≥3:1」实测不成立(队 A 1.39:1、队 B 2.96:1),不再声称达标;要提 ID 可读性该动 world_label.gd 的底板/描边,不是队色。
const C_TEAM_A := Color(99.0 / 255.0, 155.0 / 255.0, 1.0)     # 队 1:蓝 #639BFF
const C_TEAM_B := Color(128.0 / 255.0, 244.0 / 255.0, 1.0)    # 队 2:青 #80F4FF(H185 S50 V100)

# 延迟阈值配色的单一来源:两个对局 HUD(pvp_hud / royale_hud)的 _on_ping 都调它 —— 原先只有 1v1 按阈值上色,同一个数字在两种模式里长得不一样。
static func ping_color(ms: int) -> Color:
	if ms < 60:
		return Color(0.45, 0.9, 0.45)      # 绿:良好
	if ms < 100:
		return Color(1.0, 0.85, 0.25)      # 黄:可接受
	if ms < 150:
		return Color(1.0, 0.6, 0.15)       # 橙:偏高
	return Color(1.0, 0.3, 0.3)            # 红:高

# 武器槽位格子三态(未占淡灰 / 已占淡青 / 手持深青,三档统一 alpha 0.5);★ 底板是黑 0.1 压在浅灰蓝上 ≈#6C8790 = 浅底,故明度阶梯是未占最贴底板 → 手持最深最跳;真正的不变量是「三态两两可区分」+「手持格明度离底板最远」,色值是审美值、以实图为准。
const C_SLOT_EMPTY  := Color(0.510, 0.600, 0.624, 0.5)   # 未占据:淡灰(比底板亮一档 → 看得见但后退)
const C_SLOT_FILLED := Color(0.360, 0.620, 0.920, 0.5)   # 已占据:偏蓝的淡青
const C_SLOT_ACTIVE := Color(0.090, 0.300, 0.680, 0.5)   # 手持那把占的格:更深的蓝 → 最跳

const BTN_BORDER_W := 2


# 描边式按钮的底:暗填充 + 亮描边(直角)。★★ 这一处是共用的 —— menu_button() 与 style_button() 都走本函数,改内边距 = 同时放大那几屏(有意接受)。
# ★ 内容边距 40/20(两轮放大 14/6 → 30/14 → 40/20)⇒ 按钮最小高度 = 字号 + 40:32 号字低于 72px 会被容器顶高,绝对定位的调用方(scenes/mp_lobby/room_list.gd;2026-10-22 拆件前在 mp_lobby.gd)必须自己把行高抬到 72。
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


# 菜单系的面板底(方向 B 的凿刻感 = 外深线 + 内亮线:StyleBoxFlat 一条边只能一个颜色 ⇒ 两层嵌套 PanelContainer,内容加到 Body 里);不让 panel_box() 直接改成这样是因为对局内的重连横幅 status_banner.gd 在用 panel_box(false),改它会连带改到 HUD。
static func menu_panel(padding: Vector2 = Vector2(64, 46)) -> PanelContainer:
	var outer := PanelContainer.new()
	skin_menu_panel(outer, padding)
	return outer


# 把已经存在的 PanelContainer 就地套上菜单系凿刻皮(与 menu_panel() 同一实现,幂等:已有 Body 直接返回);就地套皮是给骨架写在 .tscn 里的那几屏用的 —— 颜色字面量不许进 .tscn,故皮只能在代码里套上去。
static func skin_menu_panel(outer: PanelContainer, padding: Vector2) -> void:
	if outer.get_node_or_null("Body") != null:
		return
	var osb := StyleBoxFlat.new()
	osb.bg_color = C_SURFACE
	osb.border_color = C_BORDER
	osb.set_border_width_all(1)
	osb.set_corner_radius_all(0)
	# ★★ 不设 content_margin(留默认 -1):StyleBox 回落 get_style_margin() = border width(1px),子节点被内缩 1px,内亮线才落在与外线不同的像素环上;⚠ 显式写 0.0 会让内层铺满外层矩形、两条线重合、画面上只剩一条。
	outer.add_theme_stylebox_override("panel", osb)

	var body := PanelContainer.new()
	body.name = "Body"   # ★ 名字是公开契约:调用方靠 get_node("Body") 拿内容容器
	var isb := StyleBoxFlat.new()
	isb.bg_color = Color(0, 0, 0, 0)   # ★ 内层只画线、不画底(否则把外层的底盖掉)
	isb.border_color = C_INNER
	isb.set_border_width_all(1)
	isb.set_corner_radius_all(0)
	isb.content_margin_left = padding.x
	isb.content_margin_right = padding.x
	isb.content_margin_top = padding.y
	isb.content_margin_bottom = padding.y
	body.add_theme_stylebox_override("panel", isb)
	# 把外层已有的子节点搬进 Body(就地套皮的调用方:骨架来自 .tscn);★ 必须先 remove_child 再 add_child —— 同帧直接 add 会因已有父节点而静默换父失败。
	for c in outer.get_children():
		outer.remove_child(c)
		body.add_child(c)
	outer.add_child(body)


# 菜单系的按钮(方向 B);分屏切换,不动 style_button 的 variant 分屏(它被结算页/暂停菜单等共用,改它的三档配色 = 一次改全部)。
# variant:primary 常态 / quiet 弱化(退出等)/ gold 主行动(创建房间 / 开始游戏)/ accent 主行动(常态描边就比 primary 更前,字色仍 C_TEXT);★ 默认 640×88,显式传小尺寸的调用点要自己传放大后的小尺寸。
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
		# ★ 弱化档字色用 C_TEXT_DIM 而不是更弱的 C_TEXT_MUTE:后者在按钮矩形里产生不了亮像素(平均亮度 0.472),而它与 style_button(quiet) 的既有观感逐字相同 ⇒ 弱化关系(C_TEXT 0.878 → 0.574)没变。
		fg = C_TEXT_DIM
	elif variant == "gold":
		edge = C_GOLD
		fg = C_GOLD
	elif variant == "accent":
		# 主行动档:常态描边就是 C_ACCENT(比 primary 的 C_EDGE 更前),字色仍用 C_TEXT —— 悬停时字才转青,这样更前由描边表达、文字对比度不受影响。
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


# 标题带:C_HEADER 横条 + 只有下边一条 C_BORDER 线 + 金色标题;四边都画就变成又一个面板,与 menu_panel() 的凿刻压边打架。
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
	# ★ 内边距 40/20;左内边距 40 → 0(用户:金色标题前面有空格、看上去没对齐)—— 盒子左边与正文同一列,右与上下不动。
	# ★ 改这里必须同步 tools/gen_menu_theme.gd 并重跑(HeaderStrip 变体是它的镜像;⚠ menu_theme_mirror_smoke 已删·2026-10-09 ⇒ 零守卫);★ 另有一处刻意不跟:scenes/mp_lobby/room_list.gd 的 _card_header 保持 20/12(住在一张自带内边距的卡里),那是版式不是漂移。
	sb.content_margin_left = 0.0
	sb.content_margin_right = 40.0
	sb.content_margin_top = 20.0
	sb.content_margin_bottom = 20.0
	p.add_theme_stylebox_override("panel", sb)
	p.add_child(label(text, size, C_GOLD))
	return p


# menu_filter_button 已删(全仓零调用):选中态由 scenes/mp_lobby.tscn 的内联 SubResource 承担;为何 Theme 里没有 Filter 变体见 tools/gen_menu_theme.gd 开头的覆盖上限注。


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


static func style_slider(s: Slider) -> void:
	var track := StyleBoxFlat.new()
	track.bg_color = C_BORDER_DIM
	track.set_corner_radius_all(0)
	track.content_margin_top = 4.0
	track.content_margin_bottom = 4.0
	s.add_theme_stylebox_override("slider", track)
	s.add_theme_stylebox_override("grabber_area", _row_sb(C_ACCENT, C_ACCENT))
	s.add_theme_stylebox_override("grabber_area_highlight", _row_sb(C_ACCENT, C_ACCENT))


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


# 把整组状态样式套到任意 Button/CheckButton 上;variant:primary 常态 / quiet 次要动作(退出等,常态就压暗,不跟主行动抢注意力)。
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


# ── 开关图形:Godot 默认主题的 CheckButton 开 = 一条浅灰药丸,关 = 一个小灰点、轨道不可见(状态一变连形状都变了);自绘一对图标,开/关都是完整胶囊轨道,只有颜色与滑块位置不同 ──
const SWITCH_W := 40
const SWITCH_H := 22
const SWITCH_TRACK_OFF := Color(0.180, 0.212, 0.259)   # 关:暗轨道(仍在暗底上看得见轮廓)

static var _sw_icons: Array = []


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
	var kr := SWITCH_H / 2.0 - 3.0
	var kx := float(SWITCH_W) - float(SWITCH_H) / 2.0 if on else float(SWITCH_H) / 2.0
	_capsule(img, int(kx - kr), 3, int(kx + kr), SWITCH_H - 3, kr, Color(1, 1, 1))
	return ImageTexture.create_from_image(img)


static func switch_icons() -> Array:
	if _sw_icons.is_empty():
		_sw_icons = [_make_switch(false), _make_switch(true)]
	return _sw_icons


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
	# ★ 默认 420×64 是旧式页面(暂停/设置/信息/Beta/结算页)的按钮列度量,故意不凑 16 的倍数(见文件头第 2 条);主菜单起走 menu_button()(默认 640×88),本函数的默认值没有跟着变。尺寸不合场景的调用方直接传 min_size。
	b.custom_minimum_size = min_size
	style_button(b, variant)
	# ★ 点击音不在这里挂:调用方的 handler(close/go_menu)各自会响一声,而 ESC 走同两条路径 ⇒ 这里再挂一次就是同帧同调两个播放器的双响;统一由状态转移出声。
	return b


# 递归给子树套像素字体;★ 跳过容器:容器的 font 不影响子控件(别把它们从跳过名单里去掉)。
static func apply_font_recursive(root: Node) -> void:
	if root is Control and not (root is PanelContainer or root is VBoxContainer or root is HBoxContainer 			or root is GridContainer or root is ScrollContainer):
		var pf: FontFile = pixel_font()
		if pf != null:
			(root as Control).add_theme_font_override("font", pf)
	for n in root.get_children():
		apply_font_recursive(n)


static func hue_preview_color(hue_deg: float) -> Color:
	return Color.from_hsv(fposmod(hue_deg, 360.0) / 360.0, 0.75, 1.0)


# 绝对定位的输入框(挂在 parent 下);size 由调用方给:各页面原值不同(240×36 / 250×40),属各自版式,不为统一而改。
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
