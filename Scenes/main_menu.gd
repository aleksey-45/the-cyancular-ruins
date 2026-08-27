extends Control
# 主菜单:单人 → Level0;多人 → 匹配场景。

func _ready() -> void:
	var title := Label.new()
	title.text = "The Cyancular Ruins"
	title.position = Vector2(60, 60)
	title.add_theme_font_size_override("font_size", 40)
	add_child(title)

	var single := Button.new()
	single.text = "单人"
	single.position = Vector2(60, 180)
	single.size = Vector2(200, 48)
	single.pressed.connect(func() -> void:
		Level0.pvp_mode = false  # 复位 PvP 标志,避免上次 PvP 残留
		get_tree().change_scene_to_file("res://Scenes/Level0.tscn"))
	add_child(single)

	var multi := Button.new()
	multi.text = "多人"
	multi.position = Vector2(60, 240)
	multi.size = Vector2(200, 48)
	multi.pressed.connect(func() -> void:
		PvpSession.reset()
		get_tree().change_scene_to_file("res://Scenes/matchmaking.tscn"))
	add_child(multi)
