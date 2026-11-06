extends AnimatedSprite2D

func _ready() -> void:
	rotation = deg_to_rad(randf_range(-10.0, 10.0))
	play("explode")
	animation_finished.connect(_on_anim_finished)

func _on_anim_finished() -> void:
	queue_free()
