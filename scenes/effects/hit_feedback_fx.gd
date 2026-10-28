extends RefCounted

# 世界系命中反馈:目标身上的 X(两根 Line2D)+ 伤害数字;挂世界 viewport ⇒ 相机 / 环面 / 后处理自动一致。
# ★ 与屏幕中心的 CombatFeedback 正交:它回答"打中了",本辅助回答"打中的是哪一个点"。
# ★ 纯静态辅助、无 autoload;父节点为 null 静默返回,headless 服务器由调用方先判 CombatFeedback.current 不建节点。

const X_LIFE := 0.22      # X 存活(与屏幕中心 X 同感)
const DAMAGE_LIFE := 0.5  # 伤害数字上浮+淡出总时长
const DAMAGE_RISE := 26.0 # 上浮距离(px)
const X_SEG := 10.0       # X 每臂长度(px)

static func spawn_hit(parent: Node, at: Vector2, damage: int = -1) -> void:
	if parent == null:
		return
	var holder := Node2D.new()
	parent.add_child(holder)
	holder.global_position = at
	for d in [Vector2(1.0, 1.0), Vector2(1.0, -1.0)]:
		var seg: Vector2 = d
		var ln := Line2D.new()
		ln.width = 3.0
		ln.default_color = Color(1.0, 1.0, 1.0, 0.95)
		ln.add_point(-seg * X_SEG)
		ln.add_point(seg * X_SEG)
		holder.add_child(ln)
		var tw := ln.create_tween()
		tw.tween_interval(maxf(X_LIFE - 0.08, 0.0))
		tw.tween_property(ln, "modulate:a", 0.0, minf(X_LIFE, 0.08))
	var life := X_LIFE
	if damage >= 0:
		life = DAMAGE_LIFE
		var lbl := Label.new()
		lbl.text = str(damage)
		lbl.add_theme_font_size_override("font_size", 28)
		lbl.add_theme_color_override("font_color", Color(1.0, 1.0, 0.85, 1.0))
		lbl.add_theme_color_override("font_outline_color", Color(0.05, 0.05, 0.08, 1.0))
		lbl.add_theme_constant_override("outline_size", 6)
		lbl.position = Vector2(-14.0, -34.0)
		holder.add_child(lbl)
		var tw2 := lbl.create_tween()
		tw2.set_parallel(true)
		tw2.tween_property(lbl, "position:y", lbl.position.y - DAMAGE_RISE, DAMAGE_LIFE)
		tw2.tween_property(lbl, "modulate:a", 0.0, DAMAGE_LIFE)
	var tw3 := holder.create_tween()
	tw3.tween_interval(life)
	tw3.tween_callback(holder.queue_free)
