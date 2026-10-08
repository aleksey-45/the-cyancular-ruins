class_name PixelFont
extends RefCounted

# 像素字体 Less Perfect DOS VGA 全局共享配置。
# 统一管理主字体与 CJK 回退字体的抗锯齿、微调与子像素渲染属性，确保全局文字呈现硬边像素风格。

const FONT_PATH := "res://assets/fonts/less_perfect_dos_vga.ttf"

# ── 中文回退字体链 ──
# 主字体为拉丁字符点阵字体，中文字符通过回退字体链展示。
# 项目字号规范采用 16 的倍数，选用基于 16 像素网格的 GNU Unifont 作为主力 CJK 回退字体，
# 并统一关闭抗锯齿与微调，确保汉字与英文字符均对齐到设备像素。
# 如有生僻字符未能覆盖，保底回退至系统字体。
const CJK_FONT_PATH := "res://assets/fonts/unifont-17.0.05.otf"
# 保底回退系统字体列表
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


# 禁用抗锯齿、微调与子像素定位，保持像素字体清晰边缘
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
