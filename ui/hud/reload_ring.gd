class_name ReloadRing
extends Node2D

# 换弹提示:角色**后侧**的圆环进度 + 环心倒计时(用户 2026-09-16「取消右下角的
# 装填中…和进度条,改成角色旁一个圆环消耗条,圆环中心是带一位小数的倒计时」)。
#
# ★ 世界空间节点(挂进世界),位置由持有方(玩家)每帧按朝向贴 —— 与 EnemyHpBar /
#   world_label / PickupPrompt 同款。★ 字号必须是 16 的倍数(项目硬约定)。
# ★ 倒计时由持有方算好传进来(它才知道 `reload_time`),本类只管画。

const RADIUS := 24.0   # 用户 2026-09-16:36 → 26 → 24(环宽保持 9)
# ★ 内径 = 2×(RADIUS - WIDTH/2) = 39px,而字号 32 的「0.5」约 48px 宽 —— **数字会溢出环外**。
#   这是用户看实图后**明确选择**的(问过三选一,他选"就让溢出"),不是没调好。别把它"修"回
#   小字号或大半径 —— 要动先问。
const WIDTH := 9.0
const FONT_SIZE := 32          # 16 的倍数
const C_BACK := Color(0.42, 0.45, 0.50, 0.22)   # 灰、很透
const C_ARC := Color(0.80, 0.84, 0.88, 0.78)    # 浅灰、半透明(用户 2026-09-16:改灰一点、透明一点)
const C_TEXT := Color(0.93, 0.95, 0.97, 0.92)

var _progress := 0.0
var _remain := 0.0


func _ready() -> void:
	z_index = 100


# progress: 0..1;remain: 剩余秒数(带一位小数显示)
func set_progress(progress: float, remain: float) -> void:
	var p := clampf(progress, 0.0, 1.0)
	var r := maxf(remain, 0.0)
	if is_equal_approx(p, _progress) and is_equal_approx(r, _remain):
		return
	_progress = p
	_remain = r
	queue_redraw()


func _draw() -> void:
	# 底环(整圈暗底)+ 进度弧(从正上方顺时针)
	draw_arc(Vector2.ZERO, RADIUS, 0.0, TAU, 48, C_BACK, WIDTH, true)
	if _progress > 0.0:
		draw_arc(Vector2.ZERO, RADIUS, -PI * 0.5, -PI * 0.5 + TAU * _progress,
				48, C_ARC, WIDTH, true)
	# 环心倒计时:一位小数
	var f := PixelFont.shared()
	var txt := "%.1f" % _remain
	var w := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x
	var baseline := (f.get_ascent(FONT_SIZE) - f.get_descent(FONT_SIZE)) * 0.5
	draw_string(f, Vector2(-w * 0.5, baseline), txt,
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, C_TEXT)
