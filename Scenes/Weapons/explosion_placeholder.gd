extends Node2D

# 爆炸特效:先用 Effects.png 全图(暂不切帧,用户后续自己切为 AnimatedSprite2D + SpriteFrames)。
# 不含伤害逻辑(伤害在子弹侧)。
const EFFECTS_TEXTURE := preload("res://AssetBundle/Sprites/Effects.png")

func _ready() -> void:
	var sprite := Sprite2D.new()
	sprite.texture = EFFECTS_TEXTURE
	sprite.z_index = 5
	add_child(sprite)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(sprite, "scale", Vector2(1.6, 1.6), 0.35).from(Vector2(0.4, 0.4))
	tw.tween_property(sprite, "modulate:a", 0.0, 0.35)
	tw.set_parallel(false)
	tw.tween_callback(queue_free)
