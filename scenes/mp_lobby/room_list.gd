class_name RoomList
extends RefCounted


# 房卡 = 可点 Button(卡本体就是可点区域;children 全 mouse_filter = IGNORE,点文字也算点卡)。
# ★ T3/M2(设计系统 v1):版式全部由容器 + token 决定,不再有 CARD_W/CARD_H/PAGE_MARGIN 这类
#   「与 .tscn 网格对齐」的常量,也没有手抬行高 72 —— 卡宽 = 列表容器给的宽度,卡高 = 内容最小高度。
#   样式全部来自 Theme variation(RowButton),本文件不 new StyleBoxFlat、不写 Color 字面量。

# 模式色(调色板单一来源 = ui/factory/ui_factory.gd;这里只引用不写字面量)。
const MODE_COLOR := {
	PvpSession.MODE_PVP: UiFactory.C_ACCENT,
	PvpSession.MODE_TEAM: UiFactory.C_MODE_TEAM,
	PvpSession.MODE_ROYALE: UiFactory.C_MODE_ROYALE,
}
const MODE_LABEL := {
	PvpSession.MODE_PVP: "1 v 1",
	PvpSession.MODE_TEAM: "对抗",
	PvpSession.MODE_ROYALE: "大 乱 斗",
}

var page: MpLobby = null

var _rooms_by_mode := {}
var _got := {"pvp": false, "royale": false, "team": false}
var _filter_btns := {}
var _join_panel: PanelContainer = null
var _join_code_edit: LineEdit = null
var _join_invite_edit: LineEdit = null


func setup(p: MpLobby) -> void:
	page = p


func register(root: Node) -> void:
	_filter_btns = {}
	for f in [["", root.get_node("%FilterAll")], [PvpSession.MODE_PVP, root.get_node("%FilterPvp")],
			[PvpSession.MODE_TEAM, root.get_node("%FilterTeam")], [PvpSession.MODE_ROYALE, root.get_node("%FilterRoyale")]]:
		var m: String = f[0]
		var b: Button = f[1]
		if MODE_LABEL.has(m):
			b.text = str(MODE_LABEL[m])
		b.button_pressed = (m == page._mode)
		b.pressed.connect(func() -> void: page._set_filter(m))
		_filter_btns[m] = b

	_join_panel = root.get_node("%JoinPanel") as PanelContainer
	_join_code_edit = root.get_node("%JoinCodeEdit") as LineEdit
	_join_invite_edit = root.get_node("%JoinInviteEdit") as LineEdit
	_join_panel.visible = false
	(root.get_node("%JoinOkBtn") as Button).pressed.connect(func() -> void:
		_join_panel.visible = false
		page._join_code(_join_code_edit.text.strip_edges(), page._mode, _join_invite_edit.text))
	(root.get_node("%JoinCancelBtn") as Button).pressed.connect(func() -> void: _join_panel.visible = false)


func set_filter_selected(mode: String) -> void:
	for m in _filter_btns:
		(_filter_btns[m] as Button).button_pressed = (m == mode)


func toggle_join_panel() -> void:
	_join_panel.visible = not _join_panel.visible


func hide_join_panel() -> void:
	_join_panel.visible = false


func ingest(mode: String, rooms: Array) -> bool:
	var tagged: Array = []
	for r in rooms:
		if typeof(r) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = (r as Dictionary).duplicate()
		d["mode"] = mode
		tagged.append(d)
	var prev: Variant = _rooms_by_mode.get(mode, null)
	var changed: bool = prev != tagged
	_rooms_by_mode[mode] = tagged
	_got[mode] = true
	return changed


func all_got() -> bool:
	return _got.values().all(func(v: bool) -> bool: return v)


func reset_got() -> void:
	_got = {"pvp": false, "royale": false, "team": false}


func clear_rooms() -> void:
	_rooms_by_mode.clear()


func redraw() -> void:
	for c in page._grid.get_children():
		page._grid.remove_child(c)
		c.queue_free()
	var shown := 0
	var total := 0
	for mode: String in [PvpSession.MODE_PVP, PvpSession.MODE_ROYALE, PvpSession.MODE_TEAM]:
		var rows: Array = _rooms_by_mode.get(mode, []).duplicate()
		rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var a_full := int(a.get("players", 0)) >= int(a.get("max_players", 2))
			var b_full := int(b.get("players", 0)) >= int(b.get("max_players", 2))
			return not a_full and b_full)
		for r in rows:
			total += 1
			if page._mode != "" and mode != page._mode:
				continue
			page._grid.add_child(_make_card(r))
			shown += 1
	if shown == 0:
		var empty := UiFactory.ui_label("暂无房间 —— 点「＋ 创建房间」开一局吧", "dim")
		page._grid.add_child(empty)
	page._status.text = "共 %d 个房间(显示 %d 个;未满优先,对局中的照列)" % [total, shown]
	# 卡高 = 内容最小高度;它在 off-tree 时算不准(Theme variation 的字体度量要入树后才解析),
	# 所以入树后延迟一帧再按内容回填 custom_minimum_size —— 不再有手抬 72/520 的行高。
	_sync_card_sizes.call_deferred()


func _sync_card_sizes() -> void:
	for c in page._grid.get_children():
		if not (c is Button):
			continue
		var btn := c as Button
		if btn.get_child_count() == 0:
			continue
		var pad := btn.get_child(0) as Control
		if pad == null:
			continue
		var content_min := pad.get_combined_minimum_size()
		btn.custom_minimum_size = Vector2(0, maxi(int(content_min.y),
				UiFactory.SP_9 + UiFactory.SP_8))


# ── 房卡(容器化;高度/宽度都由内容决定)────────────────────────────────

func _make_card(r: Dictionary) -> Button:
	var mode := str(r.get("mode", PvpSession.MODE_PVP))
	var code := str(r.get("code", ""))
	var in_match := bool(r.get("in_match", false))
	var mine := PvpSession.can_rejoin_to(code, mode)

	var btn := Button.new()
	UiFactory.style_row_button(btn)          # RowButton variation:底色/描边/字号都来自 Theme
	btn.text = ""
	btn.set_meta("code", code)               # 回局 watcher 靠 meta("code") 找卡(勿删)
	btn.set_meta("mode", mode)
	btn.custom_minimum_size = Vector2(0, UiFactory.SP_9 + UiFactory.SP_8)   # 内容驱动下限(≈112px)

	var pad := MarginContainer.new()
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		pad.add_theme_constant_override("margin_" + side, UiFactory.SP_4)
	for side in ["top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, UiFactory.SP_3)
	btn.add_child(pad)

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", UiFactory.SP_4)
	pad.add_child(row)
	row.add_child(_map_thumb(mode, str(r.get("map", ""))))
	row.add_child(_info_column(mode, r))

	btn.disabled = in_match and not mine
	if btn.disabled:
		btn.focus_mode = Control.FOCUS_NONE
		btn.modulate.a = 0.55
	else:
		btn.focus_mode = Control.FOCUS_ALL
		btn.pressed.connect(func() -> void:
			Sfx.play("ui")
			page._current_mode = mode
			if not page.try_rejoin_row(code, in_match, mode):
				page._join_code(code, mode))
	return btn


func _map_thumb(mode: String, map_path: String) -> Control:
	var frame := PanelContainer.new()
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_theme_stylebox_override("panel", UiFactory.row_box())
	var side := UiFactory.SP_9 * 2 - UiFactory.SP_2      # ≈120px 缩略图框(内容驱动)
	frame.custom_minimum_size = Vector2(side, side)
	frame.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if map_path != "" and MapCatalog.is_valid_map(map_path):
		var tex := TextureRect.new()
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tex.texture = MapCatalog.texture(map_path)
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		frame.add_child(tex)
	else:
		var fill := ColorRect.new()
		fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
		fill.color = MODE_COLOR[mode]
		fill.color.a = 0.25
		frame.add_child(fill)
	return frame


func _info_column(mode: String, r: Dictionary) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", UiFactory.SP_2)

	var head := HBoxContainer.new()
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_theme_constant_override("separation", UiFactory.SP_3)
	var name_l := UiFactory.ui_label(str(MODE_LABEL[mode]), "h2")
	name_l.add_theme_color_override("font_color", MODE_COLOR[mode])
	name_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	head.add_child(name_l)
	head.add_child(_badge(mode, r))
	var spacer := Control.new()
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(spacer)
	col.add_child(head)

	col.add_child(UiFactory.ui_label(str(r.get("code", "")), "h1"))
	col.add_child(UiFactory.ui_label(_card_subtitle(mode, r), "dim"))

	var meta := HBoxContainer.new()
	meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	meta.add_theme_constant_override("separation", UiFactory.SP_4)
	meta.add_child(UiFactory.ui_label("人数 %d / %d" % [
			int(r.get("players", 0)), int(r.get("max_players", 2))], "dim"))
	meta.add_child(UiFactory.ui_label("房主 %s" % str(r.get("host", "玩家")), "dim"))
	col.add_child(meta)

	col.add_child(_names(r.get("names", [])))
	return col


func _badge(mode: String, r: Dictionary) -> Label:
	var in_match := bool(r.get("in_match", false))
	var is_public := bool(r.get("is_public", true))
	var mine := PvpSession.can_rejoin_to(str(r.get("code", "")), mode)
	var text := "对局中" if in_match else ("私密 · 我的" if (not is_public and mine) else "等待中")
	var color := UiFactory.C_TEXT_DIM if in_match \
			else (UiFactory.C_TEXT if not is_public else UiFactory.C_ACCENT)
	var l := UiFactory.ui_label(text, "dim")
	l.add_theme_color_override("font_color", color)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


func _card_subtitle(mode: String, r: Dictionary) -> String:
	var pub := "公开" if bool(r.get("is_public", true)) else "私密"
	if mode == PvpSession.MODE_ROYALE:
		var mins := int(r.get("match_time", 0)) / 60
		return "%s · 限时 %d 分" % [pub, mins] if mins > 0 else pub
	if mode == PvpSession.MODE_TEAM:
		var tc: Dictionary = r.get("team_counts", {})
		return "%s · A%d / B%d / 未选%d" % [pub, int(tc.get("1", 0)), int(tc.get("2", 0)), int(tc.get("0", 0))]
	return "%s · 三局两胜" % pub


func _names(names_raw: Variant) -> Control:
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 0)
	var names: Array = names_raw if names_raw is Array else []
	var shown := mini(names.size(), 3)
	for i in shown:
		var is_host := i == 0
		box.add_child(UiFactory.ui_label("· %s%s" % [
				UiFactory.fit_name(str(names[i]), 14), "(房主)" if is_host else ""], "dim"))
	if names.size() > shown:
		box.add_child(UiFactory.ui_label("…等 %d 人" % names.size(), "dim"))
	return box


func set_list_visible(v: bool) -> void:
	page._grid.visible = v
	for b in _filter_btns.values():
		(b as Button).visible = v
	# 进房后把「房间列表」标题与「筛选」卡一起收起(容器化后留一张空标题卡会像漏了一块);
	# ★ ListCol 本身保持可见 —— 它是左右两栏里的弹性左栏,整列隐藏会让右栏弹到屏幕左边。
	for path: String in ["%ListTitle", "%FilterCard"]:
		var node := page.get_node_or_null(path) as Control
		if node != null:
			node.visible = v
