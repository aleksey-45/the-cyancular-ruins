extends Node2D
# 玩家头上 ID 文字:世界空间 Node2D,用 draw_string 居中画(压在黑色薄底板上)。
# 位置不由自身维护——pvp_client 每帧把它 global_position 贴到对应玩家头顶(不随倒地转体旋转)。
#
# ★ 底板 2026-09-15 按用户要求加上("所有模式下玩家名字加 0.1 黑底")。此前本文件**连描边都没有**
#   —— 旧注释写着「带黑描边」,但 _draw 里只有一行 draw_string(名不副实,本次一并改正)。
#   名字常压在浅灰蓝开阔区上,光靠 0.85 alpha 的亮色文字读不出来。

const FONT_PATH := "res://assets/fonts/less_perfect_dos_vga.ttf"
const FONT_SIZE := 32   # 16 的整数倍(像素字体锐利;全仓字号规范的最后一处违例)
const WIDTH := 344.0
const ALPHA := 0.85   # 文字透明度
# 底板:黑 0.1 —— 与单机 HUD 的 `PLATE_COLOR`、`pvp_hud.tscn` 的 `Plate` 同值(见 ui/hud.gd
# 该常量注释里的各档对比度实测)。**不乘文字 alpha**:它是垫在字下面的静态底,不是文字的一部分。
const PLATE_COLOR := Color(0, 0, 0, 0.1)
const PLATE_PAD := Vector2(6, 2)   # 底板比文字每边外扩多少(横向多留一点才衬得住字形)

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
	# 底板宽度按**实际文字**量,不能用 WIDTH(= 344 是居中排版用的行宽,拿它铺底会宽出一大截)。
	# 基线在 y=0:文字上沿 -ascent、下沿 +descent(draw_string 的 pos 是**基线**起点)。
	var tw := _font.get_string_size(_text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x
	var asc := _font.get_ascent(FONT_SIZE)
	var desc := _font.get_descent(FONT_SIZE)
	draw_rect(Rect2(-tw * 0.5 - PLATE_PAD.x, -asc - PLATE_PAD.y,
			tw + PLATE_PAD.x * 2.0, asc + desc + PLATE_PAD.y * 2.0), PLATE_COLOR)
	draw_string(_font, Vector2(-WIDTH * 0.5, 0.0), _text,
			HORIZONTAL_ALIGNMENT_CENTER, WIDTH, FONT_SIZE, _color)
