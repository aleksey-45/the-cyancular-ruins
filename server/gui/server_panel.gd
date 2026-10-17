extends CanvasLayer

# 服务端控制台:大厅进程内的只读运维面板(唯一的写操作是「关闭房间」,见后续 task)。
# ★ 层号:本进程里没有别的 UI ⇒ 取一个即可;别照抄对局内 HUD 的 128~150(那是给地图上的 HUD 排的)。
# ★ 数据只经两条路进来:ServerStatus.build(纯判据,-s 可测)+ LobbySnapshot.collect(适配层,零判据)。
#   面板自己不判业务(人数口径 / state / 房龄都在 ServerStatus 里)—— 否则就是第二份真相。
# ★ 版式数字全部来自 spec §5;改之前先读那节(尤其「横向零余量」那条)。

const LAYER := 100

const THEME_MENU := preload("res://ui/theme/menu_theme.tres")
const BUILD_INFO := preload("res://core/config/build_info.gd")

# 版面账(spec §5.1):1920x1440 逻辑空间,margin 76 ⇒ 1768x1288;中段 = 左 1080 + 40 + 右 648。
const PAGE_MARGIN := 76
const SEP := 24
const PAD := Vector2(32, 20)
const LEFT_W := 1080
const RIGHT_W := 648
const MID_GAP := 40

# 房间表:行高/间隔/可见行数上限(MAXIMIZE_FIRST 靠 custom_maximum_size 限高)。
const ROW_H := 60
const ROW_GAP := 8
const ROOM_ROWS_MAX := 6
const MAP_UNITS := 15

const COL_TITLES := ["房号", "模式", "人数", "状态", "端口", "房龄", "地图"]
const COL_WIDTHS := [104, 152, 88, 168, 104, 104, 0]

const REFRESH_SEC := 0.5

# ★ 三态的颜色语义(spec §5.6):等待中退后、对局中金、worker 已退出红。
const STATE_TEXT := {"waiting": "等待中", "in_match": "对局中", "stale": "worker 已退出"}

var _rm: RoomManager = null
var _lan_ip := ""
var _started_at := 0.0
var _acc := 0.0

var _overview: Label = null
var _footnote: Label = null
var _rooms_meta: Label = null
var _rows_col: VBoxContainer = null
var _rows: Dictionary = {}      # code -> {panel: PanelContainer, cells: Array[Label]}
var _codes: Array = []
var _empty_label: Label = null


# 面板唯一入口:由 server_main.gd 注入。★ 在 _ready 之后调用(add_child 已触发过 _ready)。
func setup(room_manager: RoomManager, lan_ip_text: String) -> void:
	_rm = room_manager
	_lan_ip = lan_ip_text
	_update_footnote()
	_refresh()


func _ready() -> void:
	layer = LAYER
	_started_at = Time.get_unix_time_from_system()
	var root := Control.new()
	root.theme = THEME_MENU
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	var bg := ColorRect.new()
	bg.color = UiFactory.C_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, PAGE_MARGIN)
	root.add_child(margin)

	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", SEP)
	margin.add_child(page)
	page.add_child(_build_header())
	page.add_child(_build_overview())
	page.add_child(_build_middle())
	_audit_if_requested()


# ── 标题带:身份(版本 / pid / 端口) ─────────────────────────────────────────

func _build_header() -> Control:
	var strip := UiFactory.header_strip("服 务 器 控 制 台")
	# ★ header_strip 的**左内边距是刻意的 0**(菜单页里让金色标题与正文同列),搬到本页就顶格了。
	#   这里只在本页把左右内边距覆盖成 PAD.x,与下面各面板的文字列对齐 —— 不动工厂。
	var sb := (strip.get_theme_stylebox("panel") as StyleBoxFlat).duplicate() as StyleBoxFlat
	sb.content_margin_left = PAD.x
	sb.content_margin_right = PAD.x
	strip.add_theme_stylebox_override("panel", sb)

	var title := strip.get_child(0)
	strip.remove_child(title)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 24)
	strip.add_child(row)
	row.add_child(title)
	row.add_child(_spacer())
	row.add_child(UiFactory.label(BUILD_INFO.display(), 32, UiFactory.C_TEXT_DIM))
	row.add_child(UiFactory.label("pid %d" % OS.get_process_id(), 32, UiFactory.C_TEXT_DIM))
	row.add_child(UiFactory.label("%d ●" % NetBus.DEFAULT_PORT, 32, UiFactory.C_ACCENT))
	return strip


# ── 概览条:同一件事只在这一处说(spec §5.2) ────────────────────────────────

func _build_overview() -> Control:
	var panel := UiFactory.menu_panel(Vector2(PAD.x, 14))
	var body := panel.get_node("Body") as PanelContainer
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	body.add_child(col)

	_overview = UiFactory.label("", 32, UiFactory.C_TEXT)
	col.add_child(_overview)

	# ★ 脚注 16 号:它是**脚注**(机器读数/一次性须知),不是表头也不是数据。
	#   判断依据是「读者要不要用它做决定」,不是大小好看。
	_footnote = UiFactory.label("", 16, UiFactory.C_TEXT_MUTE)
	col.add_child(_footnote)
	return panel


# ── 中段:左房间表 / 右(所选房间 + 名单,后续 task) ──────────────────────────

func _build_middle() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", MID_GAP)
	var left := _build_rooms_block()
	left.custom_minimum_size.x = LEFT_W
	row.add_child(left)
	var right := VBoxContainer.new()
	right.name = "RightColumn"
	right.add_theme_constant_override("separation", 16)
	right.custom_minimum_size.x = RIGHT_W
	row.add_child(right)
	return row


func _build_rooms_block() -> PanelContainer:
	var panel := UiFactory.menu_panel(PAD)
	var body := panel.get_node("Body") as PanelContainer
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	body.add_child(col)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 16)
	# ★ 分区标题要与**表格列文字**对齐:row_box 有 16px 左内边距 ⇒ 标题跟着缩 16(见 mock 的内缩审计)。
	head.add_child(_inset_left(UiFactory.label("房 间", 32, UiFactory.C_GOLD), 16))
	head.add_child(_spacer())
	_rooms_meta = UiFactory.label("", 32, UiFactory.C_TEXT_DIM)
	head.add_child(_rooms_meta)
	col.add_child(head)

	col.add_child(_build_rooms_header())

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# ★ MAXIMIZE_FIRST:房间少则收缩、超过 ROOM_ROWS_MAX 行才滚(原生行为,不必手写高度上限)。
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_MAXIMIZE_FIRST
	scroll.custom_maximum_size.y = ROOM_ROWS_MAX * ROW_H + (ROOM_ROWS_MAX - 1) * ROW_GAP
	_style_vbar(scroll.get_v_scroll_bar())
	_rows_col = VBoxContainer.new()
	_rows_col.add_theme_constant_override("separation", ROW_GAP)
	_rows_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rows_col)
	col.add_child(scroll)
	return panel


func _build_rooms_header() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 0)
	for i in COL_TITLES.size():
		row.add_child(_cell(str(COL_TITLES[i]), int(COL_WIDTHS[i]), 32, UiFactory.C_TEXT_DIM))
	# ★ 数据行的 row_box 有 16px 左右内边距,列头没有 ⇒ 不补这 16 会整列错位。
	return _inset(row, 16)


# ── 刷新 ────────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if _rm == null:
		return
	_acc += delta
	if _acc < REFRESH_SEC:
		return
	_acc = 0.0
	_refresh()


func _refresh() -> void:
	var lobby := _rm.lobby
	if lobby == null:
		return
	# ★ 一次刷新只读一次快照:分两次读会被两次读之间的房间增删穿过,渲染出自相矛盾的一屏。
	var rooms := LobbySnapshot.collect(lobby)
	var ports: Array[Dictionary] = []
	if lobby.launcher != null:
		ports = lobby.launcher.busy_ports()
	var snap := ServerStatus.build(rooms, ports, Time.get_unix_time_from_system())
	_render_overview(snap["counts"])
	_sync_rows(snap["rooms"])


func _render_overview(counts: Dictionary) -> void:
	var uptime := maxi(0, int(Time.get_unix_time_from_system() - _started_at))
	_overview.text = "房间 %d · 待开局 %d · 对局中 %d · worker %d 在跑 · 端口 %d / %d · 已运行 %s" % [
			int(counts.get("rooms", 0)), int(counts.get("waiting", 0)),
			int(counts.get("in_match", 0)), int(counts.get("workers_alive", 0)),
			int(counts.get("ports_used", 0)), int(counts.get("ports_total", 0)), _hms(uptime)]


func _update_footnote() -> void:
	if _footnote == null:
		return
	var ip := _lan_ip if not _lan_ip.is_empty() else "未检测到"
	_footnote.text = "公网联机需转发 UDP %d 与 %s · 朋友在客户端「服务器地址」里填 %s" % [
			NetBus.DEFAULT_PORT, WorkerLauncher.port_span_text(), ip]


func _sync_rows(rooms: Array[Dictionary]) -> void:
	var codes: Array = []
	for r in rooms:
		codes.append(str(r["code"]))
	_rooms_meta.text = "(%d 间)" % rooms.size()
	if codes != _codes:
		_rebuild_rows(rooms)
		_codes = codes
		return
	for r in rooms:
		_apply_row(_rows[str(r["code"])]["cells"], r)


func _rebuild_rows(rooms: Array[Dictionary]) -> void:
	for c in _rows_col.get_children():
		_rows_col.remove_child(c)
		c.queue_free()
	_rows.clear()
	_empty_label = null
	if rooms.is_empty():
		# 空态:不能让表看起来"渲染失败"。★ 概览/右列也要一起变 0(由各自的刷新负责)。
		_empty_label = UiFactory.label("现在没有房间。玩家建房后会出现在这里。", 32, UiFactory.C_TEXT_MUTE)
		_rows_col.add_child(_empty_label)
		return
	for r in rooms:
		var code := str(r["code"])
		var panel := PanelContainer.new()
		panel.add_theme_stylebox_override("panel", UiFactory.row_box())
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 0)
		panel.add_child(row)
		var cells: Array[Label] = []
		for i in COL_TITLES.size():
			var l := _cell("", int(COL_WIDTHS[i]), 32, UiFactory.C_TEXT)
			row.add_child(l)
			cells.append(l)
		panel.custom_minimum_size.y = ROW_H
		_rows_col.add_child(panel)
		_rows[code] = {"panel": panel, "cells": cells}
		_apply_row(cells, r)


func _apply_row(cells: Array[Label], r: Dictionary) -> void:
	var state := str(r["state"])
	cells[0].text = str(r["code"])
	cells[0].add_theme_color_override("font_color", UiFactory.C_WHITE)

	var kind := str(r["kind"])
	cells[1].text = str({"1v1": "1v1", "royale": "大乱斗", "team": "3v3"}.get(kind, kind))
	cells[1].add_theme_color_override("font_color",
			{"1v1": UiFactory.C_ACCENT, "royale": UiFactory.C_MODE_ROYALE,
			"team": UiFactory.C_MODE_TEAM}.get(kind, UiFactory.C_TEXT))

	cells[2].text = "%d / %d" % [int(r["players"]), int(r["cap"])]
	cells[2].add_theme_color_override("font_color", UiFactory.C_TEXT)

	cells[3].text = str(STATE_TEXT.get(state, state))
	cells[3].add_theme_color_override("font_color", {
		"waiting": UiFactory.C_TEXT_DIM, "in_match": UiFactory.C_GOLD,
		"stale": UiFactory.C_DANGER}.get(state, UiFactory.C_TEXT))

	var port := int(r["worker_port"])
	cells[4].text = "—" if port <= 0 else str(port)
	cells[4].add_theme_color_override("font_color", UiFactory.C_TEXT_DIM)
	cells[5].text = _mmss(float(r["age_sec"]))
	cells[5].add_theme_color_override("font_color", UiFactory.C_TEXT_DIM)
	cells[6].text = UiFactory.fit_name(str(r["map"]), MAP_UNITS)
	cells[6].add_theme_color_override("font_color", UiFactory.C_TEXT_DIM)


# ── 小件 ────────────────────────────────────────────────────────────────────

func _cell(text: String, w: int, size: int, color: Color) -> Label:
	var l := UiFactory.label(text, size, color)
	if w > 0:
		l.custom_minimum_size.x = w
	return l


func _spacer() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return c


func _inset(c: Control, px: int) -> Control:
	var wrap := MarginContainer.new()
	wrap.add_theme_constant_override("margin_left", px)
	wrap.add_theme_constant_override("margin_right", px)
	wrap.add_child(c)
	return wrap


func _inset_left(c: Control, px: int) -> Control:
	var wrap := MarginContainer.new()
	wrap.add_theme_constant_override("margin_left", px)
	wrap.add_child(c)
	return wrap


# 可见滚动条:轨道 C_FIELD(比面板底亮一档)、滑块 C_BORDER、悬停转 C_ACCENT。
# 轨道若用 C_ROW 压在 C_SURFACE 上几乎看不见(设计期实测)。
func _style_vbar(bar: VScrollBar) -> void:
	bar.custom_minimum_size.x = 16
	var track := StyleBoxFlat.new()
	track.bg_color = UiFactory.C_FIELD
	track.set_corner_radius_all(0)
	bar.add_theme_stylebox_override("scroll", track)
	bar.add_theme_stylebox_override("scroll_focus", track)
	var grab := StyleBoxFlat.new()
	grab.bg_color = UiFactory.C_BORDER
	grab.set_corner_radius_all(0)
	bar.add_theme_stylebox_override("grabber", grab)
	var hi := StyleBoxFlat.new()
	hi.bg_color = UiFactory.C_ACCENT
	hi.set_corner_radius_all(0)
	bar.add_theme_stylebox_override("grabber_highlight", hi)
	bar.add_theme_stylebox_override("grabber_pressed", hi)


func _hms(sec: int) -> String:
	return "%02d:%02d:%02d" % [sec / 3600, (sec / 60) % 60, sec % 60]


func _mmss(sec: float) -> String:
	var s := maxi(0, int(sec))
	return "%02d:%02d" % [s / 60, s % 60]


# ── 设计期仪器(不是守卫):把每个文字控件到最近一层 PanelContainer 的四向内缩打出来。
# 「有没有字顶格/出框」人眼看降采样截图判不准(设计期实测把 1214≤1288 判反过)。
# 纪律同 --matchsync-diag:开关关着时一行都不打。
func _audit_if_requested() -> void:
	if not OS.get_cmdline_user_args().has("--panel-audit"):
		return
	_audit.call_deferred()


func _audit() -> void:
	for _i in 3:
		await get_tree().process_frame
	_audit_walk(self, Rect2())


func _audit_walk(n: Node, box: Rect2) -> void:
	if n is PanelContainer:
		box = (n as Control).get_global_rect()
	if n is Label or n is Button or n is RichTextLabel or n is VScrollBar:
		if box.size.x > 0.0:
			var g := (n as Control).get_global_rect()
			print("INSET %-14s L%6.1f R%6.1f T%6.1f B%6.1f  %s" % [n.get_class(),
					g.position.x - box.position.x, box.end.x - g.end.x,
					g.position.y - box.position.y, box.end.y - g.end.y,
					_text_of(n).substr(0, 20)])
	for ch in n.get_children():
		_audit_walk(ch, box)


func _text_of(c: Control) -> String:
	if c is Label or c is Button:
		return (c as Label).text
	if c is RichTextLabel:
		return (c as RichTextLabel).text.split("\n")[0]
	if c is VScrollBar:
		return "<滚动条>"
	return ""
