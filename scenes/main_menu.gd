extends Control
# 主菜单:单人 → Level0;多人 → 匹配场景。布局在 main_menu.tscn,这里只留入口逻辑。

func _on_single_pressed() -> void:
	Level0.pvp_mode = false      # 复位 PvP 标志,避免上次 PvP 残留
	CombatComponent.pvp_arena = false   # 回单机恢复命中无敌帧
	get_tree().change_scene_to_file("res://scenes/Level0.tscn")


func _on_multi_pressed() -> void:
	PvpSession.reset()
	get_tree().change_scene_to_file("res://scenes/matchmaking.tscn")
