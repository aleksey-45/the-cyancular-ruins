extends Node

func _ready() -> void:
	await get_tree().process_frame
	# 1) 主菜单单人面板
	var mm := (load("res://scenes/main_menu.tscn") as PackedScene).instantiate()
	add_child(mm)
	await get_tree().create_timer(1.5).timeout
	mm.call("_on_single_pressed")
	await get_tree().create_timer(0.4).timeout
	print("P1DBG: ==== main sp panel ====")
	_dump(mm)
	remove_child(mm); mm.queue_free()
	await get_tree().process_frame
	# 2) 大厅建房弹层
	PvpSession.server_address = "127.0.0.1"
	var lobby := (load("res://scenes/mp_lobby.tscn") as PackedScene).instantiate()
	add_child(lobby)
	await get_tree().create_timer(0.8).timeout
	lobby.call("_open_create_dialog")
	await get_tree().create_timer(0.3).timeout
	print("P1DBG: ==== lobby create dialog ====")
	_dump(lobby)
	NetBus.stop()
	get_tree().quit(0)

func _dump(root: Node) -> void:
	for h in _find(root):
		var sb = h.get_theme_stylebox("panel")
		var lbl = h.get_node("%Title") if h.has_node("%Title") else h.get_child(0)
		print("P1DBG: title=%s rect=%s min=%s cm_l=%s fs=%s color=%s" % [
			h.title, str(h.get_rect()), str(h.get_combined_minimum_size()),
			("-" if sb == null else str(sb.content_margin_left)),
			str(lbl.get_theme_font_size("font_size")), str(lbl.get_theme_color("font_color"))])

func _find(n: Node) -> Array:
	var out: Array = []
	if n is HeaderStripPanel:
		out.append(n)
	for c in n.get_children():
		out.append_array(_find(c))
	return out
