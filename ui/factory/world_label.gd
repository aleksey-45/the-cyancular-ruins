class_name WorldLabel
extends Node2D

const FONT_PATH := "res://assets/fonts/less_perfect_dos_vga.ttf"
const FONT_SIZE := 32
const WIDTH := 344.0
const ALPHA := 0.85
# 底板(黑 0.1)。★ 唯一源是 `UiFactory.C_PLATE` —— 本处是别名,不存字面量。
# 不乘文字 alpha:它是垫在字下面的静态底,不是文字的一部分。
const PLATE_COLOR := UiFactory.C_PLATE
const PLATE_PAD := Vector2(6, 2)

# ── 头顶挂件的锚点(单一来源:1v1 / 大乱斗 / 3v3 三个宿主都问这里,别在场景根上再各写一份)──
const HEAD_OFFSET := Vector2(0.0, -78.0)
const HP_BAR_OFFSET := Vector2(0.0, -116.0)

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


## 每帧把世界层挂件(node)贴到 target + offset。挂件刻意挂在世界层、不是玩家子节点:
## 倒地转体只转身体精灵,头顶的字要始终正立。挂件或目标已失效 = 本帧不动、不报错。
static func follow(node: Node2D, target: Node2D, offset: Vector2) -> void:
	if node == null or target == null:
		return
	if not is_instance_valid(node) or not is_instance_valid(target):
		return
	node.global_position = target.global_position + offset
