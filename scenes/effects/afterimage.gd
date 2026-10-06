class_name AfterImage
extends Node2D

# 加速移动残影特效：复制主角当前帧纹理，红/蓝双色交替生成并快速淡出。
# 配合速度域倍率提升，增强角色高速移动时的视觉冲击力与流畅度。

static func spawn(host: Node, animator: AnimatedSprite2D, tint: Color) -> void:
	if host == null or animator == null or animator.sprite_frames == null:
		return
	var tex := animator.sprite_frames.get_frame_texture(animator.animation, animator.frame)
	if tex == null:
		return
	var node := AfterImage.new()
	node.global_position = animator.global_position
	node.global_rotation = animator.global_rotation
	node.scale = animator.global_scale
	var spr := Sprite2D.new()
	spr.texture = tex
	spr.flip_h = animator.flip_h
	spr.flip_v = animator.flip_v
	spr.modulate = tint
	node.add_child(spr)
	host.add_child(node)
	var tw := node.create_tween()
	tw.tween_property(node, "modulate:a", 0.0, 0.26).from(1.0)
	tw.tween_callback(node.queue_free)
