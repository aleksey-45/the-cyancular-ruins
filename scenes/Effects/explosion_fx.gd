extends AnimatedSprite2D

# 爆炸动画:播放一次 "explode" 后自毁。伤害/击退逻辑在子弹侧(explodes → _explode)。
func _ready() -> void:
	rotation = deg_to_rad(randf_range(-10.0, 10.0))  # 每次爆炸随机 ±10° 朝向,避免千篇一律
	play("explode")
	animation_finished.connect(_on_anim_finished)

func _on_anim_finished() -> void:
	queue_free()
