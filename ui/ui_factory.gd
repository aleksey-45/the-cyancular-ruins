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
# 注:core/pixel_font.gd(PixelFont.shared)是同一份字体配置的另一个共享口,给世界空间
# 文本(world_label 等)用;本工厂是 UI 侧的入口,两者暂未合并(合并要动 core,超出本次范围)。

const FONT_PATH := "res://assets/fonts/less_perfect_dos_vga.ttf"

# 加载一次、全 UI 共享(load 本身返回共享缓存实例,这里再缓存一次省掉每控件的 load 开销)
static var _font: FontFile = null


# 像素字体:关抗锯齿 / 微调 / 子像素定位,整数倍字号下保持像素锐利。
static func pixel_font() -> FontFile:
	if _font == null:
		var f := load(FONT_PATH) as FontFile
		if f != null:
			f.antialiasing = TextServer.FONT_ANTIALIASING_NONE
			f.hinting = TextServer.HINTING_NONE
			f.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
		_font = f
	return _font


# 给任意 Control 套上像素字体 + 字号(size 必须是 16 的倍数,见文件头)
static func style_control(c: Control, size: int) -> void:
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


static func button(text: String, size: int) -> Button:
	var b := Button.new()
	b.text = text
	style_control(b, size)
	# 420×64:布局度量,故意不凑 16 的倍数(见文件头第 2 条)
	b.custom_minimum_size = Vector2(420, 64)
	# 点击音不在这里挂:调用方的 handler(close/go_menu)各自会响一声,而 ESC 走的也是同两条
	# 路径 —— 这里再挂一次就是同帧同调两个播放器("ui" 不在 Sfx.PITCH_VARIATION 里,音高也一样),
	# 是能听出来的双响。统一由状态转移出声(键盘与点击同源)。
	return b
