class_name PixelFont
extends RefCounted


const FONT_PATH := "res://assets/fonts/less_perfect_dos_vga.ttf"

const CJK_FONT_PATH := "res://assets/fonts/unifont-17.0.05.otf"
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
