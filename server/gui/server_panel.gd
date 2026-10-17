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
# 名单:行高 / 可见行数上限 / 名字定宽单位(★ 与 docs/eng/ui.md:27 的口径一致:14 单位 @ 32 号)。
const ROSTER_ROW_H := 44
const ROSTER_ROWS_MAX := 5
const ROSTER_UNITS := 14

const COL_TITLES := ["房号", "模式", "人数", "状态", "端口", "房龄", "地图"]
const COL_WIDTHS := [104, 152, 88, 168, 104, 104, 0]

const REFRESH_SEC := 0.5
# 破坏性动作的二次确认窗口:超时自动回退(不弹 AcceptDialog —— 省一个控件的可用性风险)。
const CONFIRM_SEC := 3.0

# 日志区(spec §8):正文 16(密度档),滚动条可见,增量 tail worker_<端口>.log。
const LOG_FONT := preload("res://assets/fonts/menu_font.tres")
const LOG_MAX_CHARS := 64 * 1024   # ≈ 2000 行;超了从头部截断(不做无限增长)

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
var _rows: Dictionary = {}      # row_key(kind, code) -> {panel, cells, code, kind}
# ★ 初值必须与"空房集合"不同:否则首次刷新判定"集合没变"⇒ 跳过重建 ⇒ 空态那一行永远不建。
var _codes: Array = [""]
var _empty_label: Label = null

# 右列(所选房间 + 名单):选中哪间房就显示哪间的,没选中时两块一起隐藏。
var _sel_block: PanelContainer = null
var _roster_block: PanelContainer = null
var _sel_code_lbl: Label = null
var _sel_mode_lbl: Label = null
var _sel_info_lbl: Label = null
var _sel_host_lbl: Label = null
var _close_btn: Button = null
var _roster_meta: Label = null
var _roster_col: VBoxContainer = null
var _roster_sig: Array = []     # 名单内容签名:没变就不重建(否则每 0.5s 丢掉滚动位置)
var _selected_code := ""
var _selected_kind := ""        # 与 code 一起用来精确定位房对象(三张表房号空间重叠)
var _armed_code := ""           # 二次确认武装时的目标;执行时必须与当前选中完全相同
var _armed_kind := ""
var _confirming := false
var _confirm_left := 0.0

# 日志区:跟随所选房间的 worker 日志。offset 增量读 + 跟随/暂停。
var _log_meta: Label = null
var _log_rtl: RichTextLabel = null
var _log_scroll: ScrollContainer = null
var _log_path := ""
var _log_off := 0
var _log_buf := ""
var _log_follow := true
var _scroll_bottom_pending := false   # 延到下一帧再滚到底(I1:同帧 max_value 还是旧值)


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
	page.add_child(_build_log_block())
	_audit_if_requested()


# ── 标题带:身份(版本 / pid / 端口) ─────────────────────────────────────────

func _build_header() -> Control:
	var strip := UiFactory.header_strip("服 务 器 控 制 台")
	# ★ header_strip 的左内边距是刻意的 0(菜单页里让金色标题与正文同列),搬到本页就顶格了。
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

	# ★ 脚注 16 号:它是脚注(机器读数/一次性须知),不是表头也不是数据。
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
	row.add_child(_build_right_column())
	return row


func _build_right_column() -> Control:
	var col := VBoxContainer.new()
	col.name = "RightColumn"
	col.add_theme_constant_override("separation", 16)
	col.custom_minimum_size.x = RIGHT_W
	_sel_block = _build_selected_block()
	col.add_child(_sel_block)
	_roster_block = _build_roster_block()
	col.add_child(_roster_block)
	_show_right(false)
	return col


func _build_selected_block() -> PanelContainer:
	var panel := UiFactory.menu_panel(PAD)
	var body := panel.get_node("Body") as PanelContainer
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	body.add_child(col)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 24)
	# 房号 48 = 全屏唯一的主角(spec §5.3)
	_sel_code_lbl = UiFactory.label("", 48, UiFactory.C_WHITE)
	_sel_mode_lbl = UiFactory.label("", 32, UiFactory.C_TEXT)
	head.add_child(_sel_code_lbl)
	head.add_child(_sel_mode_lbl)
	col.add_child(head)

	_sel_info_lbl = UiFactory.label("", 32, UiFactory.C_TEXT_DIM)
	col.add_child(_sel_info_lbl)
	_sel_host_lbl = UiFactory.label("", 32, UiFactory.C_TEXT_DIM)
	col.add_child(_sel_host_lbl)

	# 破坏性且低频的动作:尺寸降档(560x72 → 420x64),只给受害者颜色 C_DANGER。
	_close_btn = UiFactory.menu_button("关 闭 房 间", 32, Vector2(420, 64), "quiet")
	_close_btn.add_theme_color_override("font_color", UiFactory.C_DANGER)
	_close_btn.add_theme_color_override("font_hover_color", UiFactory.C_DANGER)
	_close_btn.pressed.connect(_on_close_pressed)
	col.add_child(_close_btn)
	return panel


func _build_roster_block() -> PanelContainer:
	var panel := UiFactory.menu_panel(PAD)
	var body := panel.get_node("Body") as PanelContainer
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	body.add_child(col)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 16)
	head.add_child(UiFactory.label("名 单", 32, UiFactory.C_GOLD))
	head.add_child(_spacer())
	_roster_meta = UiFactory.label("", 32, UiFactory.C_TEXT_DIM)
	head.add_child(_roster_meta)
	col.add_child(head)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_MAXIMIZE_FIRST
	scroll.custom_maximum_size.y = ROSTER_ROWS_MAX * ROSTER_ROW_H + (ROSTER_ROWS_MAX - 1) * ROW_GAP
	_style_vbar(scroll.get_v_scroll_bar())
	_roster_col = VBoxContainer.new()
	_roster_col.add_theme_constant_override("separation", ROW_GAP)
	_roster_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_roster_col)
	col.add_child(scroll)
	return panel


func _build_rooms_block() -> PanelContainer:
	var panel := UiFactory.menu_panel(PAD)
	var body := panel.get_node("Body") as PanelContainer
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	body.add_child(col)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 16)
	# ★ 分区标题要与表格列文字对齐:row_box 有 16px 左内边距 ⇒ 标题跟着缩 16(见 mock 的内缩审计)。
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
	# 二次确认倒计时:走每一帧(不跟 0.5s 刷新节流),超时自动回退。
	if _confirming:
		_confirm_left -= delta
		if _confirm_left <= 0.0:
			_reset_confirm()
	# 日志跟随的"滚到底"必须晚一帧才生效(I1):append 当帧的 max_value 还没被布局更新,
	# 同帧设 scroll_vertical 会被钳在旧底部,下一帧就判成"用户往上滚了"⇒ 跟随自己关掉。
	if _scroll_bottom_pending:
		_scroll_bottom_pending = false
		_scroll_log_to_bottom()
	if _rm == null:
		return
	_acc += delta
	if _acc < REFRESH_SEC:
		return
	_acc = 0.0
	_refresh()


# 取一次快照。★ 一次刷新只读一次:计数 / 房间 / 名单全从同一个 snap 出来 ——
# 分两次读会被两次读之间的房间增删穿过,渲染出「(3 间) + 现在没有房间」这种自相矛盾的屏。
func _snapshot() -> Dictionary:
	if _rm == null or _rm.lobby == null:
		return {}
	var lobby := _rm.lobby
	var rooms := LobbySnapshot.collect(lobby)
	var ports: Array[Dictionary] = []
	if lobby.launcher != null:
		ports = lobby.launcher.busy_ports()
	return ServerStatus.build(rooms, ports, Time.get_unix_time_from_system())


func _refresh() -> void:
	var snap := _snapshot()
	if snap.is_empty():
		return
	_render_overview(snap["counts"])
	_sync_rows(snap["rooms"])
	_sync_selection(snap["rooms"])


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
	var keys: Array = []
	for r in rooms:
		keys.append(ServerStatus.row_key(str(r["kind"]), str(r["code"])))
	_rooms_meta.text = "(%d 间)" % rooms.size()
	if keys != _codes:
		_rebuild_rows(rooms)
		_codes = keys
		return
	for r in rooms:
		_apply_row(_rows[ServerStatus.row_key(str(r["kind"]), str(r["code"]))]["cells"], r)


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
		var kind := str(r["kind"])
		var key := ServerStatus.row_key(kind, code)
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
		# 点行 = 选中。★ 行是 PanelContainer(不是 Button):用 gui_input 收点击 ——
		#   若为可点把 7 个 Label 塞进 Button 再手工排版,行会比现在脆得多。
		# ★ 必须把 (code, kind) 一起绑上:三张表房号空间重叠,只绑房号会选中错表的那间。
		panel.mouse_filter = Control.MOUSE_FILTER_STOP
		panel.gui_input.connect(_on_row_input.bind(code, kind))
		_rows_col.add_child(panel)
		_rows[key] = {"panel": panel, "cells": cells, "code": code, "kind": kind}
		_apply_row(cells, r)
	_apply_selection_styles()


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


# ── 选中态 + 右列 ───────────────────────────────────────────────────────────

# 每 0.5s 跟着快照走:选中的房还在就刷新右列,没了就退回空态。
# ★ 不退回第一行 —— 那会让人以为系统自动替他选了另一间房。
func _sync_selection(rooms: Array[Dictionary]) -> void:
	var found: Dictionary = {}
	# ★ 必须同时比对 (code, kind):三张表房号空间重叠,只比房号会挂到另一张表的同号房。
	for r in rooms:
		if str(r["code"]) == _selected_code and str(r["kind"]) == _selected_kind:
			found = r
			break
	if found.is_empty():
		if not _selected_code.is_empty():
			_selected_code = ""
			_selected_kind = ""
			_reset_confirm()
			_show_right(false)
			_apply_selection_styles()
		_refresh_log({})
		return
	_show_right(true)
	_render_selected(found)
	_render_roster(found)
	_refresh_log(found)


func _render_selected(r: Dictionary) -> void:
	_sel_code_lbl.text = str(r["code"])
	var kind := str(r["kind"])
	_selected_kind = kind
	_sel_mode_lbl.text = str({"1v1": "1v1", "royale": "大乱斗", "team": "3v3"}.get(kind, kind))
	_sel_mode_lbl.add_theme_color_override("font_color",
			{"1v1": UiFactory.C_ACCENT, "royale": UiFactory.C_MODE_ROYALE,
			"team": UiFactory.C_MODE_TEAM}.get(kind, UiFactory.C_TEXT))
	var port := int(r["worker_port"])
	var pid := int(r["worker_pid"])
	if port <= 0:
		_sel_info_lbl.text = "端口 — · 进程 —"
	elif bool(r["worker_alive"]):
		_sel_info_lbl.text = "端口 %d · 进程 %d 在" % [port, pid]
	else:
		_sel_info_lbl.text = "端口 %d · 进程 %d 已退出" % [port, pid]
	_sel_host_lbl.text = "房主 %s" % str(r["host"])


func _render_roster(r: Dictionary) -> void:
	var roster: Array = r["roster"]
	# ★ online_known=false 表示这间房在打(成员已转连 worker)⇒ 名单是开局冻结的快照,
	#   面板不许声称谁在线。标题上直接写清楚。
	var frozen := not bool(r["online_known"])
	_roster_meta.text = ("局中快照 · %d 人" % roster.size()) if frozen else ("%d 人" % roster.size())

	var sig: Array = [str(frozen)]
	for e in roster:
		sig.append("%d:%s" % [int(e["role"]), str(e["name"])])
	if sig == _roster_sig:
		return
	_roster_sig = sig

	for c in _roster_col.get_children():
		_roster_col.remove_child(c)
		c.queue_free()
	if roster.is_empty():
		_roster_col.add_child(UiFactory.label("（暂无名单）", 32, UiFactory.C_TEXT_MUTE))
		return
	for e in roster:
		var panel := PanelContainer.new()
		panel.add_theme_stylebox_override("panel", UiFactory.row_box())
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 0)
		panel.add_child(row)
		row.add_child(_cell(str(int(e["role"])), 56, 32, UiFactory.C_TEXT_DIM))
		# ★ 名字按 ui.md:27 的口径定宽截断(14 单位 @ 32 号),不截会顶宽、不补会错列。
		row.add_child(_cell(UiFactory.fit_name(str(e["name"]), ROSTER_UNITS), 0, 32, UiFactory.C_TEXT))
		panel.custom_minimum_size.y = ROSTER_ROW_H
		_roster_col.add_child(panel)


func _select(code: String, kind: String) -> void:
	if code == _selected_code and kind == _selected_kind:
		return
	# ★ 改选目标必须撤销武装:否则"武装 A → 改选 B → 再点"会关掉 B(C1)。
	_reset_confirm()
	_selected_code = code
	_selected_kind = kind
	_apply_selection_styles()
	var snap := _snapshot()
	if not snap.is_empty():
		_sync_selection(snap["rooms"])


func _on_row_input(event: InputEvent, code: String, kind: String) -> void:
	if event is InputEventMouseButton and event.pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_select(code, kind)


func _apply_selection_styles() -> void:
	for key in _rows:
		var panel: PanelContainer = _rows[key]["panel"]
		var row_code := str(_rows[key]["code"])
		var row_kind := str(_rows[key]["kind"])
		panel.add_theme_stylebox_override("panel",
				_row_sb(row_code == _selected_code and row_kind == _selected_kind))


func _row_sb(selected: bool) -> StyleBoxFlat:
	var sb := UiFactory.row_box()
	if selected:
		sb.border_color = UiFactory.C_ACCENT
		sb.set_border_width_all(2)
	return sb


func _show_right(v: bool) -> void:
	_sel_block.visible = v
	_roster_block.visible = v


# ── 关闭房间(唯一的写操作) ─────────────────────────────────────────────────
# 两步:第一次点变「确认关闭 X?」并起 3s 倒计时,第二次点才真执行。
func _on_close_pressed() -> void:
	if _selected_code.is_empty():
		return
	if not _confirming:
		# ★ 武装时把目标一起记下来;执行时必须比对(C1:中途改选不能误关)。
		_confirming = true
		_confirm_left = CONFIRM_SEC
		_armed_code = _selected_code
		_armed_kind = _selected_kind
		_close_btn.text = "确认关闭 %s?" % _selected_code
		_close_btn.add_theme_color_override("font_color", UiFactory.C_WHITE)
		return
	_close_room()


func _reset_confirm() -> void:
	_confirming = false
	_confirm_left = 0.0
	_armed_code = ""
	_armed_kind = ""
	if _close_btn != null:
		_close_btn.text = "关 闭 房 间"
		_close_btn.add_theme_color_override("font_color", UiFactory.C_DANGER)


# ★★ 执行时重新解析房对象,绝不拿快照里的对象直接操作:
#   快照是纯字典拷贝,而且从渲染到点击之间房完全可能已经没了(或被回收梯收掉)。
#   解析不到 = no-op + 刷新 + 一句话,不报错也不关错房。
# ★ 必须走 teardown_room 单一收口:端口归还/删注册表只许出现在它体内(tools/room_sweep_lint 钉着)。
func _close_room() -> void:
	# ★★ C1:武装的目标必须仍是当前选中的目标,否则一律不执行(判据 = ServerStatus.can_close)。
	#   武装后改选别行 ⇒ 这一次点击只是取消武装,不会关掉任何房。
	if not ServerStatus.can_close(_armed_code, _armed_kind, _selected_code, _selected_kind):
		_reset_confirm()
		return
	var code := _selected_code
	var kind := _selected_kind
	_reset_confirm()
	if _rm == null or _rm.lobby == null:
		return
	var room = _rm.lobby.room_for_panel(code, kind)
	if room == null:
		# 从渲染到点击之间房已经没了:no-op + 刷新(计划里「提示一句」没有 UI 落点,
		# 已按 Minor 登记为延后项 —— 行通常会在这次刷新里消失,看得到)。
		_refresh()
		return
	_rm.lobby.teardown_room(room, LobbyRooms.TEARDOWN_KILL, "服主关闭了本房间", true)
	_refresh()


# ── 日志区 ──────────────────────────────────────────────────────────────────
# ★ RichTextLabel 即便 scroll_active=true 也不画滚动条(设计期实测:只给一个"无从判断位置的死盒子")
#   ⇒ 用 ScrollContainer(可见滚动条 + 滚轮)+ fit_content 的 RichTextLabel。

func _build_log_block() -> Control:
	var panel := UiFactory.menu_panel(PAD)
	var body := panel.get_node("Body") as PanelContainer
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	body.add_child(col)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 16)
	head.add_child(UiFactory.label("日 志", 32, UiFactory.C_GOLD))
	head.add_child(_spacer())
	_log_meta = UiFactory.label("未选中房间", 32, UiFactory.C_TEXT_DIM)
	# 点标题 = 回到底部(暂停跟随后的恢复口)
	_log_meta.mouse_filter = Control.MOUSE_FILTER_STOP
	_log_meta.gui_input.connect(_on_log_meta_input)
	head.add_child(_log_meta)
	col.add_child(head)

	_log_scroll = ScrollContainer.new()
	_log_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# ★ AUTO:ScrollContainer 的 min_size.y 恒为 0(spec §2.2)⇒ 高度完全由下面的 EXPAND 决定。
	_log_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_log_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_style_vbar(_log_scroll.get_v_scroll_bar())

	_log_rtl = RichTextLabel.new()
	_log_rtl.bbcode_enabled = false
	_log_rtl.fit_content = true          # 高度随内容 ⇒ 由 ScrollContainer 滚
	_log_rtl.scroll_active = false
	_log_rtl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_log_rtl.add_theme_font_override("normal_font", LOG_FONT)
	_log_rtl.add_theme_font_size_override("normal_font_size", 16)
	_log_rtl.add_theme_color_override("default_color", UiFactory.C_TEXT)
	_log_scroll.add_child(_log_rtl)
	col.add_child(_log_scroll)

	# ★★ EXPAND_FILL 必须设在日志面板上:设在内层 ScrollContainer 上时,面板最小高只有 90px
	#   (AUTO 下 ScrollContainer 的 min 为 0,面板只拿到最小高)—— 设计期实测踩过。
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return panel


func _on_log_meta_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_log_follow = true
		_scroll_log_to_bottom()
		_update_log_meta()


# 跟随所选房间:没选中 / 没 worker 端口 ⇒ 空日志 + 「未选中房间」。
func _refresh_log(room: Dictionary) -> void:
	var port := int(room["worker_port"]) if not room.is_empty() else 0
	if port <= 0 or _rm == null or _rm.lobby == null or _rm.lobby.launcher == null:
		_clear_log()
		return
	var path := _rm.lobby.launcher.log_path(port)
	if path != _log_path:
		# 换房间/换 worker:重置 offset 与跟随状态
		_log_path = path
		_log_off = 0
		_log_buf = ""
		_log_rtl.text = ""
		_log_follow = true
	# ★ 跟随/暂停的判据:取 append 之前 的"是否在底部"。append 之后 max_value 会变,
	#   拿它判会把"我们刚 append 过"误读成"用户往上滚了"(I1,评审者实测复现)。
	var was_at_bottom := _log_at_bottom()
	if _log_follow and not was_at_bottom:
		_log_follow = false
	elif not _log_follow and was_at_bottom:
		# I2:用户自己滚回了底部 ⇒ 恢复跟随(spec §8 要求:点标题或滚到底部)
		_log_follow = true
	_append_log_delta()
	if _log_follow:
		# ★ 延到下一帧再滚:本帧的 max_value 还是 append 前的旧值,同帧设会被钳在旧底部
		#   ⇒ 下一帧判"不在底部"⇒ 跟随自己关掉(评审者实测:in-frame max=690 vs 下一帧 713)。
		_scroll_bottom_pending = true
	_update_log_meta()


# 增量读:只消费到最后一个换行为止,把可能写了一半的行留给下一轮。
# 否则 UTF-8 会被截在多字节中间,屏幕上冒一个乱码字符。
func _append_log_delta() -> void:
	var f := FileAccess.open(_log_path, FileAccess.READ)
	if f == null:
		return
	var total := f.get_length()
	if _log_off > total:
		_log_off = 0            # 文件被轮转/重建
		_log_buf = ""
		_log_rtl.text = ""
	if total <= _log_off:
		f.close()
		return
	f.seek(_log_off)
	var chunk := f.get_buffer(total - _log_off)
	f.close()
	var nl := chunk.rfind(10)   # '\n'
	if nl < 0:
		return                  # 还没有完整的一行
	var consumed := nl + 1
	_log_off += consumed
	var text := chunk.slice(0, consumed).get_string_from_utf8()
	_log_buf += text
	if _log_buf.length() > LOG_MAX_CHARS:
		_log_buf = _log_buf.substr(_log_buf.length() - LOG_MAX_CHARS)
		_log_rtl.text = _log_buf
		_log_follow = true
	else:
		_log_rtl.append_text(text)


func _clear_log() -> void:
	if _log_path.is_empty() and _log_buf.is_empty():
		_log_meta.text = "未选中房间"
		return
	_log_path = ""
	_log_off = 0
	_log_buf = ""
	_log_rtl.text = ""
	_log_follow = true
	_update_log_meta()


func _update_log_meta() -> void:
	if _log_path.is_empty():
		_log_meta.text = "未选中房间"
		return
	_log_meta.text = "%s ▾ · %s" % [_log_path.get_file(),
			"自动跟随中" if _log_follow else "已暂停 · 点此回到底部"]


func _log_at_bottom() -> bool:
	var bar := _log_scroll.get_v_scroll_bar()
	return _log_scroll.scroll_vertical >= int(bar.max_value - bar.page) - 2


func _scroll_log_to_bottom() -> void:
	_log_scroll.scroll_vertical = int(_log_scroll.get_v_scroll_bar().max_value)


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
	# ★ 隐藏节点没有布局(rect 退化),量出来是 L0 这种假读数 ⇒ 直接跳过整棵子树。
	if n is CanvasItem and not (n as CanvasItem).visible:
		return
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
	# ★ 分支必须分开写:Button 用 as Label 会得到 null,再取 .text 就是运行时错误(实测踩过)。
	if c is Label:
		return (c as Label).text
	if c is Button:
		return (c as Button).text
	if c is RichTextLabel:
		return (c as RichTextLabel).text.split("\n")[0]
	if c is VScrollBar:
		return "<滚动条>"
	return ""
