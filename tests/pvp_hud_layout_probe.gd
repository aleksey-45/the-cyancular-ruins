extends Node

# 1v1 对局 HUD 布局探针(场景模式):钉「记分条在**正上方、居中**」这条用户明确要求过的摆放。
# 跑法:
#   "$GODOT" --headless --path . --quit-after 120 res://tests/pvp_hud_layout_probe.tscn
# 期望:每条 [hud] … 通过,末行 "PVP HUD LAYOUT PROBE: ALL-OK"。
#
# 为什么值得单开一条:记分条原先在**左下角**(anchor_top/bottom = 1.0)。它挪到顶部正中是一次
# 明确的版式决定,而 .tscn 里的锚点/偏移是那种"改别的 HUD 顺手覆盖掉、且没有任何报错"的东西
# —— 所以把"位置"本身变成断言,而不是只靠 diff 里那几行看得见。
#
# ⚠ 判据 grep 文本 "PVP HUD LAYOUT PROBE: ALL-OK"(不只看退出码)。

const HUD_SCENE := "res://ui/pvp_hud.tscn"
const TOP_BAND := 140.0    # "顶部"的判定带:记分条顶边必须落在这之内

var _failures: Array[String] = []


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("[hud]   ✓ %s" % msg)
	else:
		_failures.append(msg)
		print("[hud]   ✗ %s" % msg)


func _ready() -> void:
	var hud: CanvasLayer = (load(HUD_SCENE) as PackedScene).instantiate()
	add_child(hud)
	await get_tree().process_frame   # 等一次布局,锚点才换算成实际矩形
	await get_tree().process_frame

	# 用 find_child 而不是固定路径:记分条现在包在 ScoreWrap(PanelContainer,给底板按内容撑开)
	# 里 —— 它是一次版式重构,取节点的方式不该跟着路径一起脆。
	var label := hud.find_child("ScoreLabel", true, false) as Label
	if label == null:
		print("[hud]   ✗ 取不到 ScoreLabel(改名了?布局探针的判据要跟着改)")
		print("PVP HUD LAYOUT PROBE: FAIL")
		get_tree().quit(1)
		return

	var vp: Vector2 = get_viewport().get_visible_rect().size   # 本探针是 Node,没有 get_viewport_rect()
	var r := label.get_global_rect()
	var cx := r.position.x + r.size.x * 0.5
	print("[hud] 视口 %.0f×%.0f;记分条矩形 x=%.1f y=%.1f w=%.1f h=%.1f(水平中心 %.1f)" % [
			vp.x, vp.y, r.position.x, r.position.y, r.size.x, r.size.y, cx])

	_check(absf(cx - vp.x * 0.5) <= 2.0,
			"水平居中(中心 %.1f ≈ 视口中线 %.1f)" % [cx, vp.x * 0.5])
	_check(r.position.y >= 0.0 and r.position.y <= TOP_BAND,
			"在顶部判定带内(y=%.1f,要求 0~%.0f)" % [r.position.y, TOP_BAND])
	_check(label.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER,
			"文字自身也是居中(horizontal_alignment = CENTER)")
	_check(r.position.x < vp.x * 0.5 and r.position.x + r.size.x > vp.x * 0.5,
			"矩形**横跨**中线(不是只把左边贴在中间)")
	# 不该再回到左下角:底边必须远离屏幕底部
	_check(r.position.y + r.size.y < vp.y * 0.5,
			"不在下半屏(底边 %.1f < 半屏 %.1f)" % [r.position.y + r.size.y, vp.y * 0.5])

	if _failures.is_empty():
		print("PVP HUD LAYOUT PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("PVP HUD LAYOUT PROBE: FAIL %s" % str(_failures))
		get_tree().quit(1)
