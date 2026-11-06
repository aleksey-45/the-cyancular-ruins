class_name RoomList
extends RefCounted


# ★ 只有这三个版式常量留在代码里:房卡是运行时按载荷建的(_make_card),而它的宽必须与 .tscn 里 CardGrid 的 offset_left/right + h_separation 一致 —— 同一件事有两个来源,改一个就要改另一个,否则卡片与网格错位(而不报错)。
# ★ 其余版式常量(各行 / 各块的 y 与空档、按钮尺寸)已随迁移进 .tscn,代码里不再有副本。
const PAGE_MARGIN := 76.0
const CARD_COLUMNS := 4
const CARD_GAP := 24.0
const CARD_H := 520.0

# 模式色(与对局无关的一套,只在菜单系用)。
# ★★ 模式色定义在 ui/factory/ui_factory.gd(调色板单一来源是硬约束:颜色只在那里定义,不要再写 Color(...) 字面量)。这里只引用不写字面量,否则同一套颜色会被定义两遍、静默漂移。
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
	for mode in [PvpSession.MODE_PVP, PvpSession.MODE_ROYALE, PvpSession.MODE_TEAM]:
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
		var empty := UiFactory.label("暂无房间 —— 点「＋ 创建房间」开一局吧", 32, UiFactory.C_TEXT_DIM)
		page._grid.add_child(empty)
	page._status.text = "共 %d 个房间(显示 %d 个;未满优先,对局中的照列)" % [total, shown]


# 一张房卡 = 一颗 Button(卡本体就是可点区域)。
# ★ 子节点一律 mouse_filter = IGNORE:内容画在 Button 之上,但点击必须落到卡本体,否则点文字那一片就等于没点。
func _make_card(r: Dictionary) -> Button:
	var mode := str(r.get("mode", PvpSession.MODE_PVP))
	var code := str(r.get("code", ""))
	var in_match := bool(r.get("in_match", false))
	var mine := PvpSession.can_rejoin_to(code, mode)

	var btn := Button.new()
	_style_card(btn)
	btn.custom_minimum_size = Vector2(_card_width(), CARD_H)
	btn.size = Vector2(_card_width(), CARD_H)
	btn.set_meta("code", code)
	btn.set_meta("mode", mode)
	btn.text = ""

	var frame := PanelContainer.new()
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.offset_left = 1.0
	frame.offset_top = 1.0
	frame.offset_right = -1.0
	frame.offset_bottom = -1.0
	var fsb := StyleBoxFlat.new()
	fsb.bg_color = Color(0, 0, 0, 0)
	fsb.border_color = UiFactory.C_INNER
	fsb.set_border_width_all(1)
	fsb.set_corner_radius_all(0)
	fsb.content_margin_left = 26.0
	fsb.content_margin_right = 26.0
	fsb.content_margin_top = 20.0
	fsb.content_margin_bottom = 20.0
	frame.add_theme_stylebox_override("panel", fsb)
	btn.add_child(frame)

	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_theme_constant_override("separation", 12)
	frame.add_child(col)

	col.add_child(_card_header(mode, r))
	col.add_child(_card_body(r))

	btn.disabled = in_match and not mine
	if btn.disabled:
		btn.focus_mode = Control.FOCUS_NONE
		btn.modulate = Color(1, 1, 1, 0.55)
	else:
		btn.focus_mode = Control.FOCUS_ALL
		btn.pressed.connect(func() -> void:
			Sfx.play("ui")
			page._current_mode = mode
			if not page.try_rejoin_row(code, in_match, mode):
				page._join_code(code, mode))
	return btn


func _card_width() -> float:
	var usable := 1920.0 - PAGE_MARGIN * 2.0 - CARD_GAP * float(CARD_COLUMNS - 1)
	return floor(usable / float(CARD_COLUMNS))


func _card_header(mode: String, r: Dictionary) -> Control:
	var strip := PanelContainer.new()
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = UiFactory.C_HEADER
	sb.set_corner_radius_all(0)
	sb.border_width_left = 0
	sb.border_width_right = 0
	sb.border_width_top = 0
	sb.border_width_bottom = 1
	sb.border_color = UiFactory.C_BORDER
	sb.content_margin_left = 0.0
	sb.content_margin_right = 0.0
	sb.content_margin_top = 12.0
	sb.content_margin_bottom = 12.0
	strip.add_theme_stylebox_override("panel", sb)

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 16)
	strip.add_child(row)

	var name_l := UiFactory.label(str(MODE_LABEL[mode]), 32, MODE_COLOR[mode])
	name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(name_l)

	var in_match := bool(r.get("in_match", false))
	var is_public := bool(r.get("is_public", true))
	var mine := PvpSession.can_rejoin_to(str(r.get("code", "")), mode)
	var badge := "对局中" if in_match else ("私密 · 我的" if (not is_public and mine) else "等待中")
	var badge_col := UiFactory.C_TEXT_DIM if in_match \
			else (UiFactory.C_TEXT if not is_public else UiFactory.C_ACCENT)
	var badge_l := UiFactory.label(badge, 16, badge_col)
	badge_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(badge_l)
	return strip


func _style_card(b: Button) -> void:
	b.add_theme_stylebox_override("normal", _card_box(UiFactory.C_BORDER))
	b.add_theme_stylebox_override("hover", _card_box(UiFactory.C_ACCENT))
	b.add_theme_stylebox_override("pressed", _card_box(UiFactory.C_ACCENT))
	b.add_theme_stylebox_override("focus", _card_box(UiFactory.C_ACCENT))
	b.add_theme_stylebox_override("disabled", _card_box(UiFactory.C_BORDER))


func _card_box(border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = UiFactory.C_SURFACE
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(0)
	return sb


func _card_body(r: Dictionary) -> Control:
	var mode := str(r.get("mode", PvpSession.MODE_PVP))
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 10)

	box.add_child(UiFactory.label(str(r.get("code", "")), 48, UiFactory.C_TEXT))
	box.add_child(UiFactory.label(_card_subtitle(mode, r), 32, UiFactory.C_TEXT_DIM))

	var mid := HBoxContainer.new()
	mid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mid.add_theme_constant_override("separation", 20)
	mid.add_child(_card_map_thumb(mode, str(r.get("map", ""))))
	var meta := VBoxContainer.new()
	meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var maxp := int(r.get("max_players", 2))
	meta.add_child(UiFactory.label("人数 %d / %d" % [int(r.get("players", 0)), maxp], 32, UiFactory.C_TEXT_DIM))
	meta.add_child(UiFactory.label("房主 %s" % str(r.get("host", "玩家")), 32, UiFactory.C_TEXT_DIM))
	mid.add_child(meta)
	box.add_child(mid)

	box.add_child(_card_names(r.get("names", [])))
	return box


func _card_subtitle(mode: String, r: Dictionary) -> String:
	var pub := "公开" if bool(r.get("is_public", true)) else "私密"
	if mode == PvpSession.MODE_ROYALE:
		var mins := int(r.get("match_time", 0)) / 60
		return "%s · 限时 %d 分" % [pub, mins] if mins > 0 else pub
	if mode == PvpSession.MODE_TEAM:
		var tc: Dictionary = r.get("team_counts", {})
		return "%s · A%d / B%d / 未选%d" % [pub, int(tc.get("1", 0)), int(tc.get("2", 0)), int(tc.get("0", 0))]
	return "%s · 三局两胜" % pub


# 地图缩略图。★ 复用 MapCatalog 那套(选图面板已经在用它现画):不要另写一份画法 —— 两份必然漂,而漂了不报错,只是两张图长得不一样。map 为空时退化成模式色占位,而不是留一个空洞。
# ★ 框的皮不能用 UiFactory.panel_box():它有 28px 内容边距,会把 120×120 的缩略图/占位色块缩成中间一小块(视觉上像"图没加载完")。
func _card_map_thumb(mode: String, map_path: String) -> Control:
	var frame := PanelContainer.new()
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.custom_minimum_size = Vector2(120, 120)
	var sb := StyleBoxFlat.new()
	sb.bg_color = UiFactory.C_SURFACE
	sb.border_color = UiFactory.C_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(0)
	frame.add_theme_stylebox_override("panel", sb)
	if map_path != "" and MapCatalog.is_valid_map(map_path):
		var tex := TextureRect.new()
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tex.texture = MapCatalog.texture(map_path)
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		frame.add_child(tex)
	else:
		var fill := ColorRect.new()
		fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
		fill.color = MODE_COLOR[mode]
		fill.color.a = 0.25
		frame.add_child(fill)
	return frame


func _card_names(names_raw: Variant) -> Control:
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var names: Array = names_raw if names_raw is Array else []
	var shown := mini(names.size(), 3)
	for i in shown:
		var is_host := i == 0
		box.add_child(UiFactory.label("· %s%s" % [
				UiFactory.fit_name(str(names[i]), 14), "(房主)" if is_host else ""],
				32, UiFactory.C_TEXT_DIM))
	if names.size() > shown:
		box.add_child(UiFactory.label("…等 %d 人" % names.size(), 32, UiFactory.C_TEXT_DIM))
	return box


func set_list_visible(v: bool) -> void:
	page._grid.visible = v
	for b in _filter_btns.values():
		(b as Button).visible = v
