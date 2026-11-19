extends RefCounted

# 试玩(编辑器 → 游戏)的三条差异:敌人静止、玩家空手、Esc 回编辑器。
# 试玩状态与场景切换在 host(Level0)上,这里只放操作;依赖注入,不反向找 Level0。

var _host: Node = null


func setup(host: Node) -> void:
	_host = host


# 敌人一生成就定格:停物理帧 + 停动画首帧(位置/碰撞箱原样保留,「鸟会不会挡路/贴图多大」仍看得见)。
func on_enemy_spawned(enemy: Node) -> void:
	if not is_instance_valid(enemy):
		return
	enemy.set_physics_process(false)
	var spr := enemy.find_child("AnimatedSprite2D", true, false) as AnimatedSprite2D
	if spr != null:
		spr.stop()
		spr.frame = 0


func build_playtest_banner() -> void:
	var layer := CanvasLayer.new()
	layer.name = "PlaytestBanner"
	layer.layer = 150
	_host.add_child(layer)
	var panel := PanelContainer.new()
	panel.name = "Banner"
	panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	# 让开顶部居中的 HUD 时钟:横幅下移一行,两段文字不叠。
	panel.offset_top = float(UiFactory.MARGIN + UiFactory.SP_7)
	UiFactory.hud_plate(panel, UiFactory.SP_4, UiFactory.SP_2, true, UiFactory.C_PLATE_DEEP)
	layer.add_child(panel)
	var label := Label.new()
	label.text = "试玩 · 敌人静止 / 空手 · Esc 返回编辑器"
	UiFactory.style_control(label, UiFactory.T_BODY)
	label.add_theme_color_override("font_color", UiFactory.C_TEXT)
	panel.add_child(label)


func leave_playtest() -> void:
	if not _host.playtest_mode:
		return
	_host.playtest_mode = false
	MazeGenerator.set_map_file(_host.playtest_restore_map)   # 不让临时图泄漏到之后的开局
	_host.safe_change_scene(_host.get_tree(), "res://scenes/editor/editor_root.tscn")
