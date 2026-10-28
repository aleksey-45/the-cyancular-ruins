extends Node

# 【一次性】Phase 0 迁移后的结构/契约复核：每个场景里 HeaderStripPanel 的数量、标题、字号、对齐，
# 以及 %WaitTitle 是否仍能解析成组件。用法：
#   "<GODOT>" --headless --path . --quit-after 600 res://audit_shots/p1_verify_phase0.tscn

const EXPECT := {
	"res://scenes/settings_menu.tscn": {"count": 6, "page_title": 48, "centered": 1},
	"res://scenes/info_menu.tscn": {"count": 4, "page_title": 48, "centered": 1},
	"res://scenes/beta_menu.tscn": {"count": 3, "page_title": 48, "centered": 3},
}

var _fails := 0


func _ready() -> void:
	await get_tree().process_frame
	for path in EXPECT:
		await _check_scene(path)
	await _check_lobby()
	await _check_main_panel()
	print("P1VERIFY: DONE fails=%d" % _fails)
	get_tree().quit(0 if _fails == 0 else 1)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _headers(n: Node) -> Array:
	var out: Array = []
	if n is HeaderStripPanel:
		out.append(n)
	for c in n.get_children():
		out.append_array(_headers(c))
	return out


func _check_scene(path: String) -> void:
	var ps: PackedScene = load(path)
	if ps == null:
		_fail("%s 读不到" % path)
		return
	var root := ps.instantiate()
	add_child(root)
	await _frames(3)
	var hs := _headers(root)
	var want: Dictionary = EXPECT[path]
	var centered := 0
	var ok := true
	for h in hs:
		if not (h is HeaderStripPanel):
			ok = false
		if h.centered:
			centered += 1
		if h.title.is_empty():
			ok = false
		if h.title_size % 16 != 0:
			ok = false
	if hs.size() != want["count"]:
		_fail("%s headers=%d 期望=%d" % [path, hs.size(), want["count"]])
		ok = false
	if centered != int(want["centered"]):
		_fail("%s centered=%d 期望=%d" % [path, centered, int(want["centered"])])
		ok = false
	if hs.size() > 0 and hs[0].title_size != want["page_title"]:
		_fail("%s 页首字号=%d 期望=%d" % [path, hs[0].title_size, want["page_title"]])
		ok = false
	if ok:
		print("P1VERIFY: OK %s headers=%d centered=%d" % [path, hs.size(), centered])
	remove_child(root)
	root.queue_free()
	await _frames(2)


func _check_lobby() -> void:
	PvpSession.server_address = "127.0.0.1"
	var ps: PackedScene = load("res://scenes/mp_lobby.tscn")
	var lobby := ps.instantiate()
	add_child(lobby)
	await _frames(4)
	var hs := _headers(lobby)
	var wt := lobby.get_node_or_null("%WaitTitle")
	if hs.size() != 5:
		_fail("mp_lobby headers=%d 期望=5(4 骨架 + MapPicker)" % hs.size())
	elif not (wt is HeaderStripPanel):
		_fail("%WaitTitle 类型=%s 期望 HeaderStripPanel" % str(wt))
	else:
		print("P1VERIFY: OK mp_lobby headers=5 %WaitTitle=HeaderStripPanel")
	NetBus.stop()
	remove_child(lobby)
	lobby.queue_free()
	await _frames(2)


func _check_main_panel() -> void:
	var ps: PackedScene = load("res://scenes/main_menu.tscn")
	var mm := ps.instantiate() as Control
	add_child(mm)
	await _frames(4)
	mm.call("_on_single_pressed")
	await _frames(4)
	var hs := _headers(mm)
	var centered := 0
	for h in hs:
		if h.centered:
			centered += 1
	if hs.size() != 3:
		_fail("main sp panel headers=%d 期望=3(标题带 + MapPicker + 禁用武器)" % hs.size())
	elif centered != 1:
		_fail("main sp panel centered=%d 期望=1" % centered)
	else:
		print("P1VERIFY: OK main sp panel headers=2 centered=1")
	remove_child(mm)
	mm.queue_free()
	await _frames(2)


func _fail(msg: String) -> void:
	print("P1VERIFY: FAIL " + msg)
	_fails += 1
