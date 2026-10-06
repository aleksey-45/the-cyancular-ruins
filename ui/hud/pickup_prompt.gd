class_name PickupPrompt
extends Node2D

# 拾取提示:靠近武器时在**武器上方**浮现的"加粗小 F"(用户 2026-09-15 指定:
# 「有两层方框围着,背景是深青色」)。各模式共用同一个节点类,由各自的持有方每帧贴位。
#
# ★ 它是**世界空间**节点(挂进 `WorldViewport`),与 `EnemyHpBar` / `world_label` 同款 ——
#   不随玩家旋转/翻转,位置每帧由持有方算。尺寸因此是**世界单位**。
# ★ 字体走 `PixelFont.shared()`(与全项目同一套像素字体),字号 16 的倍数(项目硬约定)。
# ★ 它是**纯视觉**:判定仍由持有方用 `GroundWeaponField.nearest_within` 做,
#   两边必须用同一个 `exclude`(自己刚丢的那把不提示),否则会出现"提示了却捡不到"。

const BOX := Vector2(50.0, 50.0)   # 外框尺寸(世界单位)(用户 2026-09-16「放大一点」:34→50)
const INNER_INSET := 7.0           # 内框相对外框的内缩 → 形成"两层方框"
const BORDER := 3.0
const FONT_SIZE := 32              # 16 的倍数(项目硬约定)(放大一档:16→32)
const GAP_ABOVE := 64.0            # 浮在武器上方多高(世界单位)

const C_BG := Color(0.24, 0.42, 0.46, 0.72)      # 底(用户 2026-09-16「太黑了」→ 提亮压透)
const C_OUTER := Color(0.35, 0.85, 0.90, 1.0)    # 亮青外框
const C_INNER := Color(0.20, 0.55, 0.62, 1.0)    # 稍暗的内框
const C_TEXT := Color(0.92, 0.97, 1.0, 1.0)


func _ready() -> void:
	z_index = 100   # 压在武器/角色之上


func _draw() -> void:
	var half := BOX * 0.5
	var outer := Rect2(-half, BOX)
	draw_rect(outer, C_BG, true)          # 深青底
	_stroke(outer, C_OUTER)               # 外层框
	var ins := Vector2(INNER_INSET, INNER_INSET)
	_stroke(Rect2(-half + ins, BOX - ins * 2.0), C_INNER)   # 内层框

	# 加粗的 F:像素字体没有粗体,同一字符串按 (0,0)/(1,0)/(0,1)/(1,1) 画四遍凑出加粗。
	# ★ draw_string 的 y 是**基线**,不是顶边 —— 用字体度量把它居中:
	#   字形纵向占 [基线-ascent, 基线+descent],要让它以 0 为中心 → 基线 = (ascent-descent)/2。
	#   (先前写成 `half.y + 字号*0.35`,结果 F 有一半掉到框外 —— 实测取图才发现。)
	var f := PixelFont.shared()
	var w := f.get_string_size("F", HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x
	var baseline := (f.get_ascent(FONT_SIZE) - f.get_descent(FONT_SIZE)) * 0.5
	var pos := Vector2(-w * 0.5, baseline)
	for off in [Vector2.ZERO, Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)]:
		draw_string(f, pos + off, "F", HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, C_TEXT)


# 只描边不填充的矩形(四边各一条实心细条)
func _stroke(r: Rect2, c: Color) -> void:
	draw_rect(Rect2(r.position, Vector2(r.size.x, BORDER)), c, true)
	draw_rect(Rect2(r.position + Vector2(0.0, r.size.y - BORDER), Vector2(r.size.x, BORDER)), c, true)
	draw_rect(Rect2(r.position, Vector2(BORDER, r.size.y)), c, true)
	draw_rect(Rect2(r.position + Vector2(r.size.x - BORDER, 0.0), Vector2(BORDER, r.size.y)), c, true)
