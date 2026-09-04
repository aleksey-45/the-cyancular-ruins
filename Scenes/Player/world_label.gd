extends Node2D
# 玩家头上 ID 文字:世界空间 Node2D,用 draw_string 居中画(带黑描边)。
# 位置不由自身维护——pvp_client 每帧把它 global_position 贴到对应玩家头顶(不随倒地转体旋转)。

const FONT_PATH := "res://assets/fonts/less_perfect_dos_vga.ttf"
const FONT_SIZE := 24
const WIDTH := 260.0
const ALPHA := 0.85   # 文字透明度

var _text := ""
var _color := Color(1, 1, 1, 1)
var _font: FontFile = null

func _ready() -> void:
	_font = load(FONT_PATH) as FontFile
	if _font != null:
		# 像素字体:关反锯齿/微调/子像素,字形保持硬边像素
		_font.antialiasing = TextServer.FONT_ANTIALIASING_NONE
		_font.hinting = TextServer.HINTING_NONE
		_font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED

func set_label(t: String, c: Color) -> void:
	_text = t
	_color = Color(c.r, c.g, c.b, ALPHA)
	queue_redraw()

func _draw() -> void:
	if _text.is_empty() or _font == null:
		return
	draw_string(_font, Vector2(-WIDTH * 0.5, 0.0), _text,
			HORIZONTAL_ALIGNMENT_CENTER, WIDTH, FONT_SIZE, _color)
