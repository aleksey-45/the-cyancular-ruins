class_name AfterImage
extends Node2D

# 时间加速移动残影特效（阶段一）：截取主角当前动画帧纹理生成半透明副本，红/蓝双色交替生成并在 0.26s 内淡出销毁。
# 加速效果作用于水平速度域，残影组件在表现层强化高速移动与时间加速的视觉冲击感。

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
