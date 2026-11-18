extends RefCounted

# 右栏「地图事件」:计数摘要 + 已放置列表(默认收起、按 kind 分组、可单条删除/改敌人类型)+ 清空。
# 无 class_name(调用方 preload);root 只持有并转发。

var page: Control = null
var doc: EditorDoc = null
var tools = null
var info: Label = null
var list: VBoxContainer = null
var toggle: Button = null
var enemy_types: Array[String] = []
var expanded := false


func setup(p: Control, d: EditorDoc, t, info_label: Label, list_box: VBoxContainer,
		toggle_btn: Button) -> void:
	page = p
	doc = d
	tools = t
	info = info_label
	list = list_box
	toggle = toggle_btn
	if toggle != null:
		toggle.theme_type_variation = &"FlatButton"
		toggle.add_theme_color_override("font_color", UiFactory.C_TEXT_DIM)
		toggle.pressed.connect(toggle_list)


func set_enemy_types(types: Array[String]) -> void:
	enemy_types = types


## 摘要 + 重建列表(任何 meta 变化都走这里)。
func sync() -> void:
	if info == null or doc == null:
		return
	if doc.map.is_empty():
		info.text = ""
		rebuild()
		return
	var players: Array = doc.map.get("players", [])
	var respawns: Array = doc.map.get("respawns", [])
	info.text = "出生点 %d · 复活点 %d · 敌人 %d" % [
		players.size(), respawns.size(), (doc.map.get("enemies", []) as Array).size()]
	rebuild()


# 已放置 meta 列表:按 kind 分组(标题带计数),行 = 标签 + 敌人类型下拉 + 删除。
# 一张图 60+ 条时平铺同权文本会淹没右栏 ⇒ 默认收起 + 分组 + 压暗行。
func rebuild() -> void:
	if list == null:
		return
	for child in list.get_children():
		list.remove_child(child)
		child.queue_free()
	if doc == null or doc.map.is_empty():
		refresh_toggle()
		return
	var entries := doc.meta_entries()
	for g: Dictionary in [{"kind": "player", "title": "出生点"},
			{"kind": "respawn", "title": "复活点"}, {"kind": "enemy", "title": "敌人"}]:
		var kind_g := String(g["kind"])
		var rows: Array = []
		for ent: Dictionary in entries:
			if String(ent["kind"]) == kind_g:
				rows.append(ent)
		if rows.is_empty():
			continue
		var head := Label.new()
		head.theme_type_variation = &"Small"
		head.add_theme_color_override("font_color", UiFactory.C_TEXT)
		head.text = "%s · %d" % [String(g["title"]), rows.size()]
		head.custom_minimum_size = Vector2(0, 20)
		head.mouse_filter = Control.MOUSE_FILTER_IGNORE
		list.add_child(head)
		for row_ent: Dictionary in rows:
			list.add_child(meta_row(row_ent))
	refresh_toggle()


## 单条 meta 行:全部用 Small 字号/弱化色;删除按钮保持文本「删除」(探针按文本找)。
func meta_row(entry: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var kind := String(entry["kind"])
	var label := Label.new()
	label.theme_type_variation = &"Small"
	label.add_theme_color_override("font_color", UiFactory.C_TEXT_DIM)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.custom_minimum_size = Vector2(90, 0)
	label.clip_text = true
	var ix := int(entry["index"]) + 1
	match kind:
		"player":
			label.text = "P%d (%d,%d)" % [ix, int(entry["x"]), int(entry["y"])]
		"respawn":
			label.text = "R%d·侧%d (%d,%d)" % [ix, int(entry["side"]), int(entry["x"]), int(entry["y"])]
		_:
			# 类型已由行内下拉展示,标签只留「第几个 + 坐标」,不再重复 id(避免被 92px 下拉挤到截断)。
			label.text = "#%d (%d,%d)" % [ix, int(entry["x"]), int(entry["y"])]
	label.tooltip_text = label.text
	row.add_child(label)
	if kind == "enemy":
		var items: Array[String] = enemy_types.duplicate()
		var cur_type := String(entry.get("type", ""))
		if not items.has(cur_type):
			items.append(cur_type)
		var opt := OptionButton.new()
		for id: String in items:
			opt.add_item(id)
		opt.selected = items.find(cur_type)
		opt.theme_type_variation = &"Kit"
		opt.custom_minimum_size = Vector2(92, 24)
		opt.clip_text = true
		opt.size_flags_horizontal = Control.SIZE_SHRINK_END
		opt.tooltip_text = "敌人类型(可撤销)"
		opt.item_selected.connect(func(i: int) -> void:
			if i >= 0 and i < items.size():
				doc.set_meta_enemy_type(int(entry["index"]), items[i]))
		row.add_child(opt)
	var del := Button.new()
	del.text = "删除"
	del.tooltip_text = "删除这条 %s(可撤销)" % kind
	del.theme_type_variation = &"FlatButton"
	del.custom_minimum_size = Vector2(40, 24)
	del.add_theme_color_override("font_color", UiFactory.C_TEXT_DIM)
	del.pressed.connect(func() -> void:
		if doc.remove_meta_at(kind, int(entry["index"])):
			page.call("notify", "已删除一条 %s" % tools.meta_label_of(kind), false))
	row.add_child(del)
	return row


func toggle_list() -> void:
	expanded = not expanded
	if list != null:
		list.visible = expanded
	refresh_toggle()


func refresh_toggle() -> void:
	if toggle == null:
		return
	var n := 0
	if doc != null and not doc.map.is_empty():
		n = doc.meta_entries().size()
	toggle.text = "%s列表 (%d)" % ["收起" if expanded else "展开", n]
	toggle.visible = n > 0


func clear_all() -> void:
	page.call("notify", "已清空 meta(%d 条)" % doc.clear_meta("all"), false)
	sync()
