extends Node

# 【一次性】HeaderStripPanel 组件 vs UiFactory.header_strip() 的逐项读数对比。
# 用法:"<GODOT>" --headless --path . --quit-after 600 res://audit_shots/p1_strip_probe.tscn

const CASES := [
	["测试标题", 32, false],
	["测试标题", 32, true],
	["—— 设 置 ——", 48, true],
	["—— 已暂停 ——", 64, true],
]

var _fails := 0


func _ready() -> void:
	await get_tree().process_frame
	var theme: Theme = load("res://ui/theme/menu_theme.tres")
	if theme == null:
		print("P1STRIP: FAIL 读不到 menu_theme.tres")
		get_tree().quit(1)
		return
	var wrap := Control.new()
	wrap.theme = theme
	add_child(wrap)
	var scene: PackedScene = load("res://ui/components/header_strip_panel.tscn")
	if scene == null:
		print("P1STRIP: FAIL 读不到 header_strip_panel.tscn")
		get_tree().quit(1)
		return
	for case in CASES:
		var text: String = case[0]
		var size: int = case[1]
		var center: bool = case[2]
		var old := UiFactory.header_strip(text, size, center)
		wrap.add_child(old)
		var new := scene.instantiate() as HeaderStripPanel
		new.apply(text, size, center)
		wrap.add_child(new)
		await get_tree().process_frame
		await get_tree().process_frame
		_check(text, size, center, old, new)
		old.queue_free()
		new.queue_free()
		await get_tree().process_frame
	print("P1STRIP: DONE fails=%d cases=%d" % [_fails, CASES.size()])
	get_tree().quit(0 if _fails == 0 else 1)


func _label_of(n: Node) -> Label:
	if n is Label:
		return n
	for c in n.get_children():
		var r := _label_of(c)
		if r != null:
			return r
	return null


func _check(text: String, size: int, center: bool, old: Node, new: Node) -> void:
	var ol := _label_of(old)
	var nl := _label_of(new)
	var tag := "[%s size=%d centered=%s]" % [text, size, center]
	if ol == null or nl == null:
		print("P1STRIP: FAIL %s 拿不到 Label" % tag)
		_fails += 1
		return
	var old_ms: Vector2 = old.get_combined_minimum_size()
	var new_ms: Vector2 = new.get_combined_minimum_size()
	var checks := {
		"min_size": [old_ms, new_ms],
		"font_size": [ol.get_theme_font_size("font_size"), nl.get_theme_font_size("font_size")],
		"font_color": [ol.get_theme_color("font_color"), nl.get_theme_color("font_color")],
		"align": [ol.horizontal_alignment, nl.horizontal_alignment],
		"text": [ol.text, nl.text],
	}
	var bad: Array = []
	for k in checks:
		var pair: Array = checks[k]
		if pair[0] != pair[1]:
			bad.append("%s old=%s new=%s" % [k, str(pair[0]), str(pair[1])])
	if bad.is_empty():
		print("P1STRIP: OK %s min=%s" % [tag, str(new_ms)])
	else:
		print("P1STRIP: FAIL %s :: %s" % [tag, " | ".join(bad)])
		_fails += 1
