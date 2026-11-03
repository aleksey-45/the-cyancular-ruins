class_name PixelFont
extends RefCounted

# 像素字体(Less Perfect DOS VGA)共享配置:多处 Label/绘制共用同一资源,只需 shared() 一次,
# 关闭抗锯齿/微调/子像素后所有引用同一 FontFile 的节点全局锐利(load 返回共享缓存实例)。

const FONT_PATH := "res://assets/fonts/less_perfect_dos_vga.ttf"

# ── 汉字回退字体链(2026-09-13 视觉评析)──
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
