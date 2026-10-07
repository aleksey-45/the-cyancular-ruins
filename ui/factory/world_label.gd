extends Node2D

# 玩家头顶名称标识：世界空间 Node2D 节点，使用 draw_string 居中绘制并配有半透明暗色底板。
# 坐标由调用方每物理帧更新吸附于角色头顶，不随角色旋转变化。

const FONT_PATH := "res://assets/fonts/less_perfect_dos_vga.ttf"
const FONT_SIZE := 32
const WIDTH := 344.0
const ALPHA := 0.85
const PLATE_COLOR := UiFactory.C_PLATE
const PLATE_PAD := Vector2(6, 2)

var _text := ""
var _color := Color(1, 1, 1, 1)
var _font: FontFile = null


func _ready() -> void:
	_font = load(FONT_PATH) as FontFile
	if _font != null:
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
	var tw := _font.get_string_size(_text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x
	var asc := _font.get_ascent(FONT_SIZE)
	var desc := _font.get_descent(FONT_SIZE)
	draw_rect(Rect2(-tw * 0.5 - PLATE_PAD.x, -asc - PLATE_PAD.y,
			tw + PLATE_PAD.x * 2.0, asc + desc + PLATE_PAD.y * 2.0), PLATE_COLOR)
	draw_string(_font, Vector2(-WIDTH * 0.5, 0.0), _text,
			HORIZONTAL_ALIGNMENT_CENTER, WIDTH, FONT_SIZE, _color)
