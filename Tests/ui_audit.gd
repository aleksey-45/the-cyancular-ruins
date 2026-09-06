extends Node

# UI 审计探针:实例化指定场景,遍历全部 Control,报告 ①越出 1920×1440 视口 ②与
# 其他顶层面板矩形相交 的控件。用法:
#   Godot_console --headless --path . res://Tests/ui_audit.tscn -- --scene=res://Scenes/royale_lobby.gd... 
# 支持场景:royale_lobby(大厅)/ royale_game(对局,无服务器快照时静态布局)

func _ready() -> void:
	var scene_path := ""
	var waitstate := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--scene="):
			scene_path = a.trim_prefix("--scene=")
		elif a == "--waitstate":
			waitstate = true
	var scene: Node = load(scene_path).instantiate()
	get_tree().root.add_child.call_deferred(scene)
	await get_tree().create_timer(2.0).timeout
	# 等待室状态:注入房间状态(模拟建房后)
	if waitstate and scene.has_method("_on_room_state"):
		var players: Array = []
		for i in range(3):
			players.append({"role": i + 1, "name": "玩家%d" % (i + 1)})
		scene._on_room_state({
			"code": "8888", "is_public": true, "invite_code": "", "max_players": 4,
			"host_role": 1, "players": players, "in_match": false,
		})
		await get_tree().create_timer(0.5).timeout
	# 对局排行榜:注入 8 人 round_state(RoyaleHud 建排行行)
	if scene.has_method("_hud") == false and "_hud" in scene:
		var hud: Node = scene.get("_hud")
		if hud != null and hud.has_method("_on_round_state"):
			var names := {}
			var scores := {}
			for i in range(8):
				names[i + 1] = "玩家%d" % (i + 1)
				scores[i + 1] = i
			hud._on_round_state({"state": 1, "scores": scores, "names": names,
					"alive": {}, "left": [], "timer": 100.0})
		await get_tree().create_timer(0.5).timeout
	print("UIA === 审计 ", scene_path, " ===")
	var rects: Array = []   # [name, Rect2]
	_walk(scene, rects)
	var vp := Rect2(Vector2.ZERO, Vector2(1920, 1440))
	for r in rects:
		var rect: Rect2 = r[1]
		if rect.position.x < -2 or rect.position.y < -2 \
				or rect.end.x > vp.size.x + 2 or rect.end.y > vp.size.y + 2:
			print("UIA 越界: %s  rect=%s" % [r[0], rect])
	# 顶层报告重叠(只看已知的几块大面板,避免子控件噪声)
	var keys := ["CreatePanel", "WaitPanel", "Board", "BoardBg", "Panel", "Status", "HudRoot"]
	for i in rects.size():
		for j in range(i + 1, rects.size()):
			for k in keys:
				if String(rects[i][0]).findn(k) >= 0 and String(rects[j][0]).findn(k) >= 0:
					continue
			# 报告任意两个"大面板级"矩形(面积>40000)相交
			if (rects[i][1] as Rect2).get_area() > 40000 and (rects[j][1] as Rect2).get_area() > 40000:
				var inter: Rect2 = (rects[i][1] as Rect2).intersection(rects[j][1] as Rect2)
				if inter.get_area() > 900:
					print("UIA 重叠: %s %s  ⇄  %s %s  交叠面积=%d" % [rects[i][0], rects[i][1],
							rects[j][0], rects[j][1], int(inter.get_area())])
	print("UIA DONE")
	get_tree().quit(0)

func _walk(n: Node, rects: Array) -> void:
	if n is Control:
		var c := n as Control
		if c.is_visible_in_tree() and c.size.x > 4 and c.size.y > 4:
			rects.append([c.name, Rect2(c.global_position, c.size)])
	for c in n.get_children():
		_walk(c, rects)
