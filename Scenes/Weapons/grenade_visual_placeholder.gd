extends Sprite2D
# 榴弹占位视觉:程序生成软圆,用户后画榴弹贴图时替换 texture/region。
func _ready() -> void:
	if texture == null:
		texture = Explosion.make_circle_texture(16)
