class_name AfterImage
extends Node2D

# 加速残影(第一阶段):复制主角当前帧贴图,红/蓝双色交替、短促淡出。
# 关键教训:move_and_slide() 用引擎自己的 delta,缩放 delta 不改变位移 —— 加速的"快"必须
# 落在速度域;残影则是让"快"被眼睛看见的表现层。

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
