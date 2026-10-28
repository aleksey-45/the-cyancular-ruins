extends RefCounted

# 伤害数字(世界系):命中时在目标身上飘一个数字;挂世界 viewport ⇒ 相机 / 环面 / 后处理自动一致。
# ★ 命中 X **不在这里**:X 由屏幕中心的 CombatFeedback.hit_marker() 画(用户裁定,别再把 X 搬到目标上)。
# ★ 纯静态辅助、无 autoload;parent 为 null 静默返回,headless 服务器由调用方先判 CombatFeedback.current。

const DAMAGE_LIFE := 0.5
const DAMAGE_RISE := 26.0


static func spawn_damage(parent: Node, at: Vector2, damage: int) -> void:
	if parent == null or damage < 0:
		return
	var holder := Node2D.new()
	parent.add_child(holder)
	holder.global_position = at
	var lbl := Label.new()
	lbl.text = str(damage)
	lbl.add_theme_font_size_override("font_size", 28)
	lbl.add_theme_color_override("font_color", Color(1.0, 1.0, 0.85, 1.0))
	lbl.add_theme_color_override("font_outline_color", Color(0.05, 0.05, 0.08, 1.0))
	lbl.add_theme_constant_override("outline_size", 6)
	lbl.position = Vector2(-14.0, -34.0)
	holder.add_child(lbl)
	var tw := lbl.create_tween()
	tw.tween_property(lbl, "position:y", lbl.position.y - DAMAGE_RISE, DAMAGE_LIFE)
	tw.parallel().tween_property(lbl, "modulate:a", 0.0, DAMAGE_LIFE)
	tw.tween_callback(holder.queue_free)
