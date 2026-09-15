class_name PixelFont
extends RefCounted

# 像素字体(Less Perfect DOS VGA)共享配置:多处 Label/绘制共用同一资源,只需 shared() 一次,
# 关闭抗锯齿/微调/子像素后所有引用同一 FontFile 的节点全局锐利(load 返回共享缓存实例)。

const FONT_PATH := "res://assets/fonts/less_perfect_dos_vga.ttf"

# ── 汉字回退字体链(2026-09-13 视觉评析)──
#
# less_perfect_dos_vga 是**纯拉丁**的 DOS 位图字体,没有 CJK 字形 —— 中文一律要回退。
# 麻烦在于 antialiasing / hinting / subpixel_positioning 是 **FontFile 自己的属性**,
# 系统回退字体是另一个资源、不吃这三项,于是同一行里汉字是抗锯齿软边、拉丁是硬边像素
# (「重狙 M82A1」「玩家: Anon」都这样),而且整机字体不同观感就不同。
#
# 现在改为**内置** GNU Unifont(assets/fonts/unifont-17.0.05.otf,SIL OFL 1.1,可商用,
# 授权文本见 assets/fonts/unifont-LICENSE.txt),并套同一组「关抗锯齿/微调/子像素」。
#
# 为什么是 Unifont:本项目排版硬约定「字号必须是 16 的倍数」(来自 8x16 的 DOS 位图拉丁,
# 只有整数倍设计像素才与设备像素对齐、边缘才硬),所以汉字字体也必须是 **16 像素网格**。
# 主流开源像素中文字体(方舟像素 Ark Pixel / 缝合像素 Fusion Pixel)只做到 12px —— 在
# 16/32 字号下是 1.33x / 2.67x 的非整数缩放,笔画会粗细不均;方舟像素的 16px 规格已被
# 作者废弃,其官方推荐的 16px 替代品正是 Unifont。代价是字形比手绘像素字朴素。
# 若日后拿到 16px 网格的像素中文字体,换掉 CJK_FONT_PATH 即可,其余不用动。
const CJK_FONT_PATH := "res://assets/fonts/unifont-17.0.05.otf"
# 兜底:Unifont 覆盖不到的生僻字/符号(它基本全覆盖,这层只是保险),再退到系统字体。
const CJK_BACKSTOP_NAMES := ["SimSun", "宋体", "Microsoft YaHei"]

static var _font: FontFile = null


static func shared() -> FontFile:
	if _font == null:
		var f := load(FONT_PATH) as FontFile
		if f != null:
			_sharpen(f)
			f.fallbacks = _cjk_chain()
		_font = f
	return _font


# 「关抗锯齿 / 关微调 / 关子像素」三件套:像素字体锐利的唯一配置,主字体与回退字体共用。
static func _sharpen(f: Font) -> void:
	f.antialiasing = TextServer.FONT_ANTIALIASING_NONE
	f.hinting = TextServer.HINTING_NONE
	f.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED


static func _cjk_chain() -> Array:
	var chain: Array = []
	var cjk := load(CJK_FONT_PATH) as FontFile
	if cjk != null:
		_sharpen(cjk)
		chain.append(cjk)
	var backstop := SystemFont.new()
	backstop.font_names = PackedStringArray(CJK_BACKSTOP_NAMES)
	_sharpen(backstop)
	chain.append(backstop)
	return chain
