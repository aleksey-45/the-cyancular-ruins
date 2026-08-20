extends Node2D

# 占位爆炸特效:软圆白贴图放大淡出自毁。不含伤害逻辑(伤害在子弹侧)。
# 用户手绘 FX_Explosion.png 六帧到货后,把本节点换成 AnimatedSprite2D + SpriteFrames,自毁逻辑保留。
func _ready() -> void:
	var sprite := Sprite2D.new()
	sprite.texture = Explosion.make_circle_texture(64)
	sprite.z_index = 5
	add_child(sprite)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(sprite, "scale", Vector2(1.6, 1.6), 0.35).from(Vector2(0.4, 0.4))
	tw.tween_property(sprite, "modulate:a", 0.0, 0.35)
	tw.set_parallel(false)
	tw.tween_callback(queue_free)
