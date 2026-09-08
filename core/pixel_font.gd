class_name PixelFont
extends RefCounted

# 像素字体(Less Perfect DOS VGA)共享配置:多处 Label/绘制共用同一资源,只需 shared() 一次,
# 关闭抗锯齿/微调/子像素后所有引用同一 FontFile 的节点全局锐利(load 返回共享缓存实例)。

const FONT_PATH := "res://assets/fonts/less_perfect_dos_vga.ttf"

static var _font: FontFile = null


static func shared() -> FontFile:
	if _font == null:
		var f := load(FONT_PATH) as FontFile
		if f != null:
			f.antialiasing = TextServer.FONT_ANTIALIASING_NONE
			f.hinting = TextServer.HINTING_NONE
			f.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
		_font = f
	return _font
