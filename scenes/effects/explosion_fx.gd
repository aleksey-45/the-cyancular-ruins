extends AnimatedSprite2D

# 爆炸视觉动画：播放单次 "explode" 爆炸动画后自动释放。爆炸伤害与击退判定由对应子弹逻辑处理。
func _ready() -> void:
	rotation = deg_to_rad(randf_range(-10.0, 10.0))  # 随机添加 ±10° 旋转角度，丰富爆炸视觉表现多样性
	play("explode")
	animation_finished.connect(_on_anim_finished)

func _on_anim_finished() -> void:
	queue_free()
