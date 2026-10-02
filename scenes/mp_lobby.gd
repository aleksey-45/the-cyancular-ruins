extends LobbyPage

# 统一联机大厅(**取代** matchmaking / royale_lobby / team_lobby 三个页)。
# 顶栏(昵称/地址/启服) → 模式筛选 + 创建/加入 → 房卡网格 → 状态栏。
# 三套服务端注册表原样保留:本页**并发调三次**现有列房 RPC,前端合并打标(设计 §3.7.3)。
#
# ★ 一条纪律:三个模式在这里的差异**全部**收在 `_mode` 这一个变量上
#   (筛选值 / 创建弹层的形态 / 等待室的形态 / 转连方式)。别再按"哪个页面"分叉 ——
#   那正是本次要消灭的重复。
# ★ 本页的梯顺序 = `[worker → claim → 大厅 → ack]`(与旧的大乱斗/3v3 页同款):
#   1v1 旧页那条 `[worker → join → 大厅 → claim]` 随三页一起退役;合并后**只有**这一条,
#   而它必须容纳三模式 —— join 那条梯的职责由 ack 那条(建房/加入 8s 无应答)覆盖。
#
# ★ 场景是裸 Control,UI 全在代码里建(与三个旧页同款);控件一律走 UiFactory,字号 16 的倍数。

# ── 版式常量(真实像素;1920×1440 设计稿)──
const PAGE_MARGIN := 40.0
const CARD_COLUMNS := 4
const CARD_GAP := 22.0
const ROW_H := 64.0

var _mode := ""                    # 当前**筛选**:"" = 全部;否则 PvpSession.MODE_*
var _rooms_by_mode := {}           # mode -> Array(载荷条目,已打 "mode" 键)
var _grid: GridContainer = null
var _filter_btns := {}             # mode -> Button(含 "" = 全部)
var _join_panel: PanelContainer = null
var _join_code_edit: LineEdit = null
var _join_invite_edit: LineEdit = null

# **我当前所在那间房**的模式(转连时按它选场景)。
# ★★ 它与 `PvpSession.room_mode` **不是一回事**:后者是**凭据**的模式(供列表里判"这一行
#   是不是我的房"),在"建了房但 `note_room` 还没跑到"这一档上是**空串** —— 拿它去分派
#   `_enter_match_scene` 会把 1v1 的对局**静默切进 `team_game.tscn`**(不报错)。别合并成一个字段。
var _current_mode := ""

# 建房/加入的 8s 无应答兜底(合并后只剩这一条 ack 梯)
var _ack := true
var _sent_ms := 0

# 三个模式各自的"已收到应答"标记(三条 RPC 各自到达)
var _got := {"pvp": false, "royale": false, "team": false}

# 刚发出的加入请求(1v1):房号**只暂存**,等服务端答"加进去了"才写进 PvpSession(I1 纪律,
# 与旧 1v1 页 `_join_code_pending` 同款)。
var _join_pending := {}

# 模式未知的加入(`_mode == ""`)会**同时问三张表**,只有一间存在 ⇒ 其余几句「房间不存在」
# 是预期噪音,由 `_swallow_absent` 吞掉不显示。收到任何正向应答即复位。
var _probe_multi_join := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_add_lobby_background()
	_build_top_bar()
	_build_filter_bar()
	_build_card_grid()
	_build_status_bar()

	NetBus.local_room_list.connect(_on_room_list)
	NetBus.local_room_created.connect(_on_room_created)
	NetBus.local_room_joined.connect(_on_room_joined)
	NetBusExt.local_royale_rooms.connect(_on_royale_rooms)
	NetBusExt.local_royale_room_state.connect(_on_room_state_royale)
	NetBusExt.local_team_rooms.connect(_on_team_rooms)
	NetBusExt.local_team_room_state.connect(_on_room_state_team)

	_finish_lobby_ready()


# ── 版式 ────────────────────────────────────────────────────────────

# 本页的按钮:32 号字 + 描边式。★ 不复用基类 `_page_button` —— 那个是 16 号(旧页 KH 版式),
#   与设计稿 §3.2「输入框/按钮高 64,字号 32」不符。
func _mp_button(text: String, pos: Vector2, size: Vector2, fn: Callable) -> Button:
	var b := UiFactory.button(text, 32, size)
	b.position = pos
	b.size = size
	add_child(b)
	b.pressed.connect(fn)
	return b


# 顶栏:昵称行 / 服务器地址行 / 右上本机局域网 IP。
func _build_top_bar() -> void:
	var name_l := UiFactory.label("昵称", 32, UiFactory.C_TEXT)
	name_l.position = Vector2(PAGE_MARGIN, 40)
	name_l.size = Vector2(200, ROW_H)
	name_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(name_l)
	var name_le := UiFactory.line_edit(self, Vector2(240, 40), Vector2(520, ROW_H),
			"昵称(头上显示)", PvpSession.player_name)
	UiFactory.style_control(name_le, 32)   # 本次版式统一到 32(基类 line_edit 的默认是 16)
	name_le.text_changed.connect(func(t: String) -> void:
		PvpSession.player_name = t.strip_edges() if not t.strip_edges().is_empty() else "Anon"
		_push_lobby_name())

	var addr_l := UiFactory.label("服务器地址", 32, UiFactory.C_TEXT)
	addr_l.position = Vector2(PAGE_MARGIN, 120)
	addr_l.size = Vector2(200, ROW_H)
	addr_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(addr_l)
	_addr_edit = UiFactory.line_edit(self, Vector2(240, 120), Vector2(520, ROW_H),
			"服务器地址", PvpSession.server_address)
	UiFactory.style_control(_addr_edit, 32)
	_mp_button("刷新列表", Vector2(780, 120), Vector2(200, ROW_H), _on_refresh_pressed)
	var srv := _mp_button("启动/重启本机服务器", Vector2(1000, 120), Vector2(360, ROW_H),
			_on_local_server_pressed)
	srv.tooltip_text = "关闭旧的本机大厅,重新拉起同目录的 Cyancular Ruins Server.exe,并自动连 127.0.0.1 刷新列表"

	# 右上:本机局域网 IP(常驻显示,不靠易被刷掉的状态栏)
	_ip_label = UiFactory.label(LocalServer.lan_ip_hint(), 32, UiFactory.C_ACCENT)
	_ip_label.position = Vector2(1380, 40)
	_ip_label.size = Vector2(500, ROW_H)
	_ip_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(_ip_label)


# 筛选行:四颗分段按钮(全部 / 1v1 / 3v3 / 大乱斗)+ 右侧创建/加入。
func _build_filter_bar() -> void:
	var group := ButtonGroup.new()
	var filters := [["", "全部"], [PvpSession.MODE_PVP, "1 v 1"],
			[PvpSession.MODE_TEAM, "3 v 3"], [PvpSession.MODE_ROYALE, "大 乱 斗"]]
	var x := PAGE_MARGIN
	for f in filters:
		var m: String = f[0]
		var b := _mp_button(str(f[1]), Vector2(x, 230), Vector2(160, 60),
				func() -> void: _set_filter(m))
		# 分段按钮:选中态用 Button 自己的 toggle 画(免得多一份配色),ButtonGroup 保证互斥。
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = (m == _mode)
		_filter_btns[m] = b
		x += 160.0 + 12.0
	_mp_button("＋ 创建房间", Vector2(1300, 230), Vector2(280, 60), _open_create_dialog)
	_mp_button("加入房间", Vector2(1600, 230), Vector2(280, 60), _toggle_join_panel)


func _build_card_grid() -> void:
	_grid = GridContainer.new()
	_grid.columns = CARD_COLUMNS
	_grid.add_theme_constant_override("h_separation", int(CARD_GAP))
	_grid.add_theme_constant_override("v_separation", int(CARD_GAP))
	_grid.position = Vector2(PAGE_MARGIN, 470)
	_grid.size = Vector2(1920.0 - PAGE_MARGIN * 2.0, 0)
	add_child(_grid)


func _build_status_bar() -> void:
	_status = UiFactory.label("", 32, UiFactory.C_TEXT)
	_status.position = Vector2(PAGE_MARGIN, 1330)
	_status.size = Vector2(1500, ROW_H)
	add_child(_status)
	_mp_button("返回主菜单", Vector2(1680, 1330), Vector2(200, ROW_H), _on_back_pressed)


func _on_back_pressed() -> void:
	NetBus.stop()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


# ── 筛选 ────────────────────────────────────────────────────────────

# 切筛选模式。★ 三颗分段按钮的选中态与 `_mode` 是**同一件事的两半**,收在这里刷新,
#   别在按钮 handler 里各写一遍(那样"程序改了 `_mode`"这条路就漏了)。
func _set_filter(mode: String) -> void:
	_mode = mode
	for m in _filter_btns:
		(_filter_btns[m] as Button).button_pressed = (m == mode)
	_redraw_cards()


# ── 合并与重绘 ──────────────────────────────────────────────────────

# 三个载荷入口各自把条目并入同一张表,再统一重绘。
# ★ 每条都**打上 mode 标** —— 卡片要显示模式,筛选器也按它过滤;服务端载荷里没有这个键
#   (三套注册表各管各的,谁也不该知道别人)。
func _ingest_rooms(mode: String, rooms: Array) -> void:
	var tagged: Array = []
	for r in rooms:
		if typeof(r) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = (r as Dictionary).duplicate()
		d["mode"] = mode
		tagged.append(d)
	_rooms_by_mode[mode] = tagged
	_got[mode] = true
	_ack = true
	_sent_ms = 0
	if _got.values().all(func(v: bool) -> bool: return v):
		_redraw_cards()


func _on_room_list(rooms: Array) -> void:
	_ingest_rooms(PvpSession.MODE_PVP, rooms)


func _on_royale_rooms(rooms: Array) -> void:
	# Beta 房与普通房互不可见(客户端侧;服务器侧 join 守卫是第二道)
	_ingest_rooms(PvpSession.MODE_ROYALE, rooms.filter(func(r) -> bool:
		return typeof(r) == TYPE_DICTIONARY and bool(r.get("beta", false)) == PvpSession.beta_mode))


func _on_team_rooms(rooms: Array) -> void:
	_ingest_rooms(PvpSession.MODE_TEAM, rooms.filter(func(r) -> bool:
		return typeof(r) == TYPE_DICTIONARY and bool(r.get("beta", false)) == PvpSession.beta_mode))


# 重绘整张网格。
# ★★ **必须先 `remove_child` 再 `queue_free`** —— 只 `queue_free` 的话旧节点要到**帧末**才没,
#   同帧再建一次就会在网格里留下**两批卡叠着**(而且它们都还是 `_grid` 的子节点,
#   `get_children()` 数得出来)。生产里三条 RPC 应答**确实可能落在同一帧**
#   (`_ingest_rooms` 每收到一条就可能触发一次重绘)。本仓在"热重建视觉"那处踩过同款
#   (`WeaponPickup.configure` 的注释)。
func _redraw_cards() -> void:
	for c in _grid.get_children():
		_grid.remove_child(c)
		c.queue_free()
	var shown := 0
	var total := 0
	for mode in [PvpSession.MODE_PVP, PvpSession.MODE_ROYALE, PvpSession.MODE_TEAM]:
		# 未满优先、对局中的排最后 —— **在每个模式内部**排(旧 1v1 页那条观感纪律)。
		# 1v1 的载荷没有 max_players ⇒ 取默认 2,与卡片那一处同一个默认值。
		var rows: Array = _rooms_by_mode.get(mode, []).duplicate()
		rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return int(a.get("players", 0)) >= int(a.get("max_players", 2)) \
					and int(b.get("players", 0)) < int(b.get("max_players", 2)))
		for r in rows:
			total += 1
			if _mode != "" and mode != _mode:
				continue
			_grid.add_child(_make_card(r))
			shown += 1
	if shown == 0:
		var empty := UiFactory.label("暂无房间 —— 点「＋ 创建房间」开一局吧", 32, UiFactory.C_TEXT_DIM)
		_grid.add_child(empty)
	_status.text = "共 %d 个房间(显示 %d 个;未满优先,对局中的照列)" % [total, shown]


# ── 造卡 ────────────────────────────────────────────────────────────

# 模式色(与对局**无关**的一套,只在菜单系用)。★ 3v3 刻意**不用蓝** —— `#639BFF` 就是
# `UiFactory.C_TEAM_A`(队 1 的队色),而队色在 3v3 里是**有玩法语义**的颜色
# ("一眼看出谁是队友")。拿它当模式色会让大厅的「3v3」与对局的「队 1」撞色。
# ★ 键用 `PvpSession.MODE_*`(已实测:别的类的常量可以当 const 字典的键 —— 见 Task 3 报告)。
const MODE_COLOR := {
	PvpSession.MODE_PVP: UiFactory.C_ACCENT,
	PvpSession.MODE_TEAM: Color(0.627, 0.549, 1.0),      # #A08CFF
	PvpSession.MODE_ROYALE: Color(0.910, 0.639, 0.239),  # #E8A33D
}
const MODE_LABEL := {
	PvpSession.MODE_PVP: "1 v 1",
	PvpSession.MODE_TEAM: "3 v 3",
	PvpSession.MODE_ROYALE: "大 乱 斗",
}


# 一张房卡 = **一颗 Button**(卡本体就是可点区域)。
# ★ 为什么不是 PanelContainer + 覆盖层:那样"点不动"就要靠探针去数覆盖层的连接数,
#   而 `disabled` / `focus_mode` / `pressed` 这三个原生属性都在 Button 上 —— 探针的三条
#   断言(`disabled` / 0 连接 / 不吃焦点)直接落在同一个节点上,没有第二处真值。
# ★ 子节点一律 `mouse_filter = IGNORE`:内容画在 Button 之上,但点击必须落到卡本体,
#   否则点文字那一片就等于没点。
func _make_card(r: Dictionary) -> Button:
	var mode := str(r.get("mode", PvpSession.MODE_PVP))
	var code := str(r.get("code", ""))
	var in_match := bool(r.get("in_match", false))
	var mine := PvpSession.can_rejoin_to(code, mode)

	var btn := Button.new()
	UiFactory.style_button(btn, "primary")
	btn.custom_minimum_size = Vector2(_card_width(), 400)
	btn.size = Vector2(_card_width(), 400)
	btn.set_meta("code", code)
	btn.set_meta("mode", mode)
	btn.text = ""   # 内容全部自绘

	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	col.add_theme_constant_override("separation", 8)
	btn.add_child(col)

	col.add_child(_card_header(mode, r))
	col.add_child(_card_body(r))

	# ★★ 次序是承重的:**先问「这是我的房吗 + 凭据还在吗」**(`can_rejoin_to` 已在上面算好),
	#    这一档**可点**(点了走回局);不是我的房,才轮到「对局中 ⇒ 禁用」那一档。
	#    反过来写 = 回局这一档连点都点不到,而**一行报错都没有**。
	btn.disabled = in_match and not mine
	if btn.disabled:
		btn.focus_mode = Control.FOCUS_NONE
		btn.modulate = Color(1, 1, 1, 0.55)   # 整体压暗:一眼看出这间进不去
	else:
		btn.focus_mode = Control.FOCUS_ALL
		btn.pressed.connect(func() -> void:
			Sfx.play("ui")
			if not try_rejoin_row(code, in_match, mode):
				_join_code(code, mode))
	return btn


func _card_width() -> float:
	var usable := 1920.0 - PAGE_MARGIN * 2.0 - CARD_GAP * float(CARD_COLUMNS - 1)
	return floor(usable / float(CARD_COLUMNS))


# 卡头一行:左 = 模式名(模式色),右 = 状态角标。
# ★ 角标三档的**次序**:`对局中` 优先于 `私密 · 我的` —— 一间对局中的私密房对**别人**
#   根本不列出,能同时满足两条的只有"我的房且已开局",那时"对局中"是更有用的信息。
func _card_header(mode: String, r: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 12)

	var name_l := UiFactory.label(str(MODE_LABEL[mode]), 32, MODE_COLOR[mode])
	name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_l)

	var in_match := bool(r.get("in_match", false))
	var is_public := bool(r.get("is_public", true))
	var mine := PvpSession.can_rejoin_to(str(r.get("code", "")), mode)
	var badge := "对局中" if in_match else ("私密 · 我的" if (not is_public and mine) else "等待中")
	# ★ 三档取色**刻意避开 `C_WARN`** —— 它在调色板里被钉死为「弹夹见底」**单一语义**
	#   (`ui_factory.gd` 的 `C_WARN` 注释明写"**只**用于「低弹量/耗尽」")。拿它表"私密"
	#   会让那个金色在大厅与 HUD 里指两件事。这里用中性亮白:不抢强调色,也不借用语义色。
	var badge_col := UiFactory.C_TEXT_DIM if in_match \
			else (UiFactory.C_TEXT if not is_public else UiFactory.C_ACCENT)
	row.add_child(UiFactory.label(badge, 32, badge_col))
	return row


# 卡身:房间号(48) → 副标(32) → [地图缩略图 120×120 | 人数/房主] → 名单(最多 3 行)。
func _card_body(r: Dictionary) -> Control:
	var mode := str(r.get("mode", PvpSession.MODE_PVP))
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 6)

	box.add_child(UiFactory.label(str(r.get("code", "")), 48, UiFactory.C_TEXT))
	box.add_child(UiFactory.label(_card_subtitle(mode, r), 32, UiFactory.C_TEXT_DIM))

	var mid := HBoxContainer.new()
	mid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mid.add_theme_constant_override("separation", 16)
	mid.add_child(_card_map_thumb(mode, str(r.get("map", ""))))
	var meta := VBoxContainer.new()
	meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# ★ 1v1 的载荷**没有** max_players(1v1 恒 2 人)—— 前端补,而不是去动那三个载荷的形状。
	var maxp := int(r.get("max_players", 2))
	meta.add_child(UiFactory.label("人数 %d / %d" % [int(r.get("players", 0)), maxp], 32, UiFactory.C_TEXT_DIM))
	meta.add_child(UiFactory.label("房主 %s" % str(r.get("host", "玩家")), 32, UiFactory.C_TEXT_DIM))
	mid.add_child(meta)
	box.add_child(mid)

	box.add_child(_card_names(r.get("names", [])))
	return box


# 副标按模式给不同的一行(它就是各模式"规则摘要"的位置)。
func _card_subtitle(mode: String, r: Dictionary) -> String:
	var pub := "公开" if bool(r.get("is_public", true)) else "私密"
	if mode == PvpSession.MODE_ROYALE:
		var mins := int(r.get("match_time", 0)) / 60
		return "%s · 限时 %d 分" % [pub, mins] if mins > 0 else pub
	if mode == PvpSession.MODE_TEAM:
		var tc: Dictionary = r.get("team_counts", {})
		return "%s · A%d / B%d / 未选%d" % [pub, int(tc.get("1", 0)), int(tc.get("2", 0)), int(tc.get("0", 0))]
	return "%s · 三局两胜" % pub


# 地图缩略图。★ 复用 MapCatalog 那套(选图面板已经在用它现画地形简略图)——
#   **不要**另写一份画法:两份必然漂,而漂了不报错,只是两张图长得不一样。
#   `map` 为空(= 未上报 / 随机)时退化成一块模式色占位,而不是留一个空洞。
func _card_map_thumb(mode: String, map_path: String) -> Control:
	var frame := PanelContainer.new()
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.custom_minimum_size = Vector2(120, 120)
	frame.add_theme_stylebox_override("panel", UiFactory.panel_box())
	if map_path != "" and MapCatalog.is_valid_map(map_path):
		var tex := TextureRect.new()
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# 签名 `MapCatalog.texture(path: String, cell_px: int = CELL_PX) -> ImageTexture`
		# —— 与 `ui/map_picker.gd` 同一个入口。
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


# 名单行:**最多 3 行**,超出显示 `…等 N 人`。
# ★ 名字走 `UiFactory.fit_name(名字, 14)` 定宽截断(与结算页同款)—— 不截的话长昵称会
#   把卡顶宽(卡宽是 4 列网格算出来的固定值,顶宽 = 整行错位)。
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


# ── 拉列表(三条并发)────────────────────────────────────────────────

# 基类钩子。★ **不是一条统一 RPC** —— 三条并发、各自到达,合并后重绘。
#   代价照实登记:刷新延迟由最慢那份决定(设计 §3.7.3)。
#   token 仍要带(B1 甲案):大厅据此把"持凭据本人自己那间私密房"也列出来。
func _send_list_request() -> void:
	_got = {"pvp": false, "royale": false, "team": false}
	_rooms_by_mode.clear()
	NetBus.rpc_id(1, "list_rooms")
	NetBusExt.rpc_id(1, "royale_list", PvpSession.token)
	NetBusExt.rpc_id(1, "team_list", PvpSession.token)


# ── 大厅回复 ────────────────────────────────────────────────────────

# 1v1 建房:建房者就是房主。记房号 + 记模式(转连时按 `_current_mode` 选场景)。
func _on_room_created(code: String) -> void:
	_current_mode = PvpSession.MODE_PVP
	PvpSession.note_room(code, _current_mode)
	_ack = true
	_sent_ms = 0
	_probe_multi_join = false
	_status.text = "房间号 %s —— 等对手加入(可叫对方刷新列表点进来)" % code


# 服务端答"加进去了" —— **本页唯一**记 1v1 加入房号的地方(I1:失败的加入不得留下
# `room_code`,否则 `can_rejoin_to(我自己的房)` 恒 false,自己那间房永远是灰的)。
func _on_room_joined(role: int) -> void:
	if not _join_pending.is_empty():
		_current_mode = str(_join_pending.get("mode", PvpSession.MODE_PVP))
		PvpSession.note_room(str(_join_pending.get("code", "")), _current_mode)
		_join_pending = {}
	_ack = true
	_sent_ms = 0
	_probe_multi_join = false
	_status.text = "已加入,等待开战……"


func _on_room_state_royale(state: Dictionary) -> void:
	_current_mode = PvpSession.MODE_ROYALE
	PvpSession.note_room(str(state.get("code", "")), _current_mode)
	_ack = true
	_sent_ms = 0
	_probe_multi_join = false
	_status.text = "已进入大乱斗房间 %s,等待开局…" % str(state.get("code", ""))


func _on_room_state_team(state: Dictionary) -> void:
	_current_mode = PvpSession.MODE_TEAM
	PvpSession.note_room(str(state.get("code", "")), _current_mode)
	_ack = true
	_sent_ms = 0
	_probe_multi_join = false
	_status.text = "已进入 3v3 房间 %s,等待选边/开局…" % str(state.get("code", ""))


# 大厅文本播报。
# ★ 模式未知的加入会同时问三张表(见 `_join_code`),只有一间存在 ⇒ 另几句「房间不存在」
#   是**预期噪音**,吞掉不显示(否则玩家会看到一句与自己那间房无关的拒绝)。
func _on_server_message(t: String) -> void:
	if LocalServer.restarting:
		return
	if _swallow_absent(t):
		return
	_status.text = t


func _swallow_absent(t: String) -> bool:
	return _probe_multi_join and t == "房间不存在"


# ── 加入 ────────────────────────────────────────────────────────────

func _toggle_join_panel() -> void:
	if _join_panel == null:
		_build_join_panel()
		# ★ 首次点击是「打开」,不是「开关翻转」—— 新建的 PanelContainer 默认 visible,
		#   若无条件 `not visible` 会把刚建好的弹层**当场关掉**(点了没反应)。
		_join_panel.visible = true
		return
	_join_panel.visible = not _join_panel.visible


func _build_join_panel() -> void:
	_join_panel = PanelContainer.new()
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	vb.custom_minimum_size = Vector2(560, 0)
	_join_panel.add_child(vb)
	vb.add_child(UiFactory.label("加入房间", 32, UiFactory.C_ACCENT))
	_join_code_edit = UiFactory.line_edit(vb, Vector2.ZERO, Vector2(500, 48), "房间号", "")
	_join_code_edit.custom_minimum_size = Vector2(500, 48)
	UiFactory.style_control(_join_code_edit, 32)
	_join_invite_edit = UiFactory.line_edit(vb, Vector2.ZERO, Vector2(500, 48),
			"邀请码(私密房,可空)", "")
	_join_invite_edit.custom_minimum_size = Vector2(500, 48)
	UiFactory.style_control(_join_invite_edit, 32)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	vb.add_child(row)
	var join := UiFactory.button("加 入", 32, Vector2(180, 48))
	join.pressed.connect(func() -> void:
		_join_panel.visible = false
		_join_code(_join_code_edit.text.strip_edges(), _mode, _join_invite_edit.text))
	row.add_child(join)
	var cancel := UiFactory.button("取 消", 32, Vector2(180, 48), "quiet")
	cancel.pressed.connect(func() -> void: _join_panel.visible = false)
	row.add_child(cancel)
	add_child(_join_panel)
	# 居中锚点必须在入树之后设:未入树时父级尺寸为 0,面板会飞到屏幕左上角外(两个旧页都踩过)。
	_join_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_join_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_join_panel.grow_vertical = Control.GROW_DIRECTION_BOTH


# 加入某房间号。★ 模式未知(从"全部"列表点的、或手敲房号)时,三张表**都试一次**:
#   三次请求里只有一间存在,其余两句「房间不存在」由 `_on_server_message` 吞掉不显示
#   (见 `_swallow_absent`)。
# ★ `invite` 是**可选第三参**:私密房不在列表里,邀请码是加入它的唯一途径(设计 §3.2);
#   卡片按下那条路只传前两参(它本来就不该带邀请码)。
func _join_code(code: String, mode: String, invite: String = "") -> void:
	if code.is_empty():
		_status.text = "请填房间号"
		return
	_with_lobby(func() -> void:
		_ack = false
		_sent_ms = Time.get_ticks_msec()
		_probe_multi_join = mode == ""
		_status.text = "加入房间 %s,等待配对…" % code
		if mode == PvpSession.MODE_ROYALE:
			NetBusExt.rpc_id(1, "royale_join", code, invite, PvpSession.beta_mode)
		elif mode == PvpSession.MODE_TEAM:
			NetBusExt.rpc_id(1, "team_join", code, invite, PvpSession.beta_mode)
		elif mode == PvpSession.MODE_PVP:
			NetBus.rpc_id(1, "join_room", code)
		else:
			# 模式未知:三张表都问一次(只有一间会成功)
			NetBus.rpc_id(1, "join_room", code)
			NetBusExt.rpc_id(1, "royale_join", code, invite, PvpSession.beta_mode)
			NetBusExt.rpc_id(1, "team_join", code, invite, PvpSession.beta_mode))


# ── 创建房间弹层(Task 4 实现)────────────────────────────────────────

# 本任务只建到"按钮点得动、不炸"这一层;弹层本体在 Task 4。
func _open_create_dialog() -> void:
	_status.text = "创建房间弹层尚未接线(Task 4)"


# ── 转连与超时梯 ────────────────────────────────────────────────────

# ★★ 判据必须是**本页的 `_current_mode`**(我当前所在那间房的模式),**不是**
#   `PvpSession.room_mode`。后者是**凭据**的模式(供列表里判"这一行是不是我的房"),
#   它在"建了房但 `note_room` 还没跑到"这一档上是**空串** —— 那时下面这个 else 会把
#   1v1 的对局**静默切进 `team_game.tscn`**(不报错,只是一个场景选错了)。
#   ⇒ 两个量语义不同,不要合并成一个字段。
# ★ 两页**刻意不同**的那条纪律现在按 `_current_mode` 分派(设计 §3.1.2):
#   1v1 直切;大乱斗/3v3 必须 call_deferred —— 它们的 match_start 在 NetBus.poll 调用栈内
#   到达,栈内切场景会在这个栈里 free 大厅/重建大物理世界 → 偶发原生段错误(曾实测)。
func _enter_match_scene() -> void:
	if _current_mode == PvpSession.MODE_PVP:
		get_tree().change_scene_to_file("res://scenes/pvp_game.tscn")
	elif _current_mode == PvpSession.MODE_ROYALE:
		get_tree().call_deferred("change_scene_to_file", "res://scenes/royale_game.tscn")
	else:
		get_tree().call_deferred("change_scene_to_file", "res://scenes/team_game.tscn")


# 梯顺序 `[worker → claim → 大厅 → ack]`(合并后唯一的一条;见文件头)。
# ★ 别重排:1v1 旧页那条 join 梯的职责由末尾的 ack 梯覆盖(建房/加入 8s 无应答)。
func _process(_delta: float) -> void:
	if _tick_rejoin_timeout():
		return
	if _tick_worker_connect_timeout():
		return
	if _tick_claim_timeout():
		return
	_tick_lobby_connect_timeout()
	if not _ack and _sent_ms > 0 and Time.get_ticks_msec() - _sent_ms > 8000:
		_sent_ms = 0
		_status.text = "8 秒无响应——地址不通,或该服务器不是最新版(开服方请用最新服务端)"


# ── 基类钩子(本页实现)────────────────────────────────────────────────

# 空地址回退:取会话里的服务器地址(不再特判本机)。
func _lobby_fallback_addr() -> String:
	return PvpSession.server_address


# 本任务还没有"已在房间里"这一档(Task 5 的等待室会补);现在一律放行。
func _lobby_action_allowed() -> bool:
	return true


# 三个模式的权威规则项都上发,worker 各取自己认得的键(`server_main._on_player_options`
# 与 `MatchBootstrap` 都按 role1 那份生效)。不认得的键被静默忽略 —— 这是既有行为。
func _player_options() -> Dictionary:
	return {
		"hue": Settings.pvp_color_hue,
		"round_full_heal": Settings.pvp_round_full_heal,
		"disabled_weapons": Settings.pvp_disabled_weapons,
		"match_time": int(Settings.royale_match_min * 60.0),
		"map": Settings.mp_map_path,
	}


func _go_match_status() -> String:
	return "配对成功,连接对局服务器……"


func _on_worker_connect_failed() -> void:
	if _connecting_worker:
		_return_to_lobby("对局服务器连接失败——房间可能已失效,已返回大厅并刷新")


func _worker_timeout_msg() -> String:
	return "对局服务器无响应(房间可能已失效)——已返回大厅并刷新,请换一个房间"


func _claim_timeout_msg() -> String:
	return "对手未就绪(房间可能已失效)——已返回大厅并刷新,请换一个房间"


# 配对成功:停掉建房/加入的 ack 兜底,转由转连 worker / claim 两条梯接管。
func _on_go_match_extra() -> void:
	_sent_ms = 0


func _on_return_to_lobby() -> void:
	_sent_ms = 0
	_probe_multi_join = false


# 换服务器重连:清掉旧列表(旧房间号在新服上必然「房间不存在」)。
func _on_lobby_reconnect() -> void:
	_rooms_by_mode.clear()
	_redraw_cards()
