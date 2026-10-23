class_name RoomList
extends RefCounted

# 大厅页的「房间列表」面板(2026-10-22 Task 10 纯搬移自 scenes/mp_lobby.gd):模式筛选 / 三个载荷归并 / 房卡绘制 / 加入弹层(房号 + 邀请码)。
# ★ 节点路径(%语义名)、信号、文案、房卡版式一律逐字未动:卡片按载荷现建,名字 / meta("code") / 禁用态都是探针与回调的据点。
# ★ 状态归这里:_rooms_by_mode / _got / 四颗筛选按钮 / 加入弹层的三个节点;页只留 _mode(筛选值)与加入应答那套状态机(_ack / _sent_ms / _join_pending / …)。
# ★★ _grid 仍住在页上(scenes/mp_lobby.gd 的 var _grid):tests/harness/{rejoin,team_match}_watcher.gd 用 _page.get("_grid") 按卡号找房卡,
#    句柄搬进本文件它们会静默拿到 null(而"探针找不到卡"与"卡没建出来"在输出上长得一样)。

# ★ 只有这三个版式常量留在代码里:房卡是运行时按载荷建的(_make_card),而它的宽必须与 .tscn 里 CardGrid 的 offset_left/right + h_separation 一致 —— 同一件事有两个来源,改一个就要改另一个,否则卡片与网格错位(而不报错)。
# ★ 其余版式常量(各行 / 各块的 y 与空档、按钮尺寸)已随迁移进 .tscn,代码里不再有副本。
const PAGE_MARGIN := 76.0
const CARD_COLUMNS := 4
const CARD_GAP := 24.0

# 模式色(与对局无关的一套,只在菜单系用)。★ 3v3 刻意不用蓝 —— #639BFF 就是 UiFactory.C_TEAM_A(队 1 的队色),而队色在 3v3 里是有玩法语义的颜色("一眼看出谁是队友"),撞色会让大厅的「3v3」与对局的「队 1」混淆。
# ★★ 模式色定义在 ui/factory/ui_factory.gd(调色板单一来源是硬约束:颜色只在那里定义,不要再写 Color(...) 字面量)。这里只引用不写字面量,否则同一套颜色会被定义两遍、静默漂移。
const MODE_COLOR := {
	PvpSession.MODE_PVP: UiFactory.C_ACCENT,
	PvpSession.MODE_TEAM: UiFactory.C_MODE_TEAM,
	PvpSession.MODE_ROYALE: UiFactory.C_MODE_ROYALE,
}
const MODE_LABEL := {
	PvpSession.MODE_PVP: "1 v 1",
	PvpSession.MODE_TEAM: "3 v 3",
	PvpSession.MODE_ROYALE: "大 乱 斗",
}

var page: MpLobby = null

var _rooms_by_mode := {}           # mode -> Array(载荷条目,已打 "mode" 键)
var _got := {"pvp": false, "royale": false, "team": false}
var _filter_btns := {}             # mode -> Button(含 "" = 全部)
var _join_panel: PanelContainer = null
var _join_code_edit: LineEdit = null
var _join_invite_edit: LineEdit = null


func setup(p: MpLobby) -> void:
	page = p


# 接骨架:四颗筛选按钮 + 加入弹层。★ 控件的信号在这里接(不挪进页 _ready):"按钮画在屏上、按下去毫无反应"没有任何运行时信号可观测。
func register(root: Node) -> void:
	_filter_btns = {}
	for f in [["", root.get_node("%FilterAll")], [PvpSession.MODE_PVP, root.get_node("%FilterPvp")],
			[PvpSession.MODE_TEAM, root.get_node("%FilterTeam")], [PvpSession.MODE_ROYALE, root.get_node("%FilterRoyale")]]:
		var m: String = f[0]
		var b: Button = f[1]
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


# 三颗筛选按钮的选中态与页的 _mode 是同一件事的两半,收在这里刷新 —— 由页的 _set_filter 统一调(在按钮 handler 里各写一遍的话,"程序改了 _mode"这条路就漏了)。
func set_filter_selected(mode: String) -> void:
	for m in _filter_btns:
		(_filter_btns[m] as Button).button_pressed = (m == mode)


func toggle_join_panel() -> void:
	_join_panel.visible = not _join_panel.visible


func hide_join_panel() -> void:
	_join_panel.visible = false


# 三个载荷入口各自把条目并入同一张表(打完 mode 标),再统一重绘。★ 每条都打上 mode 标 —— 卡片要显示模式、筛选器也按它过滤,而服务端载荷里没有这个键。
func ingest(mode: String, rooms: Array) -> void:
	var tagged: Array = []
	for r in rooms:
		if typeof(r) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = (r as Dictionary).duplicate()
		d["mode"] = mode
		tagged.append(d)
	_rooms_by_mode[mode] = tagged
	_got[mode] = true


# 三张表都回来了才重绘(页在收齐那一刻调 redraw)。
func all_got() -> bool:
	return _got.values().all(func(v: bool) -> bool: return v)


# 发列房请求前复位(三条 RPC 各自的应答算"到了"的记账)。
func reset_got() -> void:
	_got = {"pvp": false, "royale": false, "team": false}


func clear_rooms() -> void:
	_rooms_by_mode.clear()


# 重绘整张网格。★★ 必须先 remove_child 再 queue_free:只 queue_free 的话旧节点要到帧末才没,同帧再建一次就会在网格里留下两批卡叠着(它们都还是 _grid 的子节点,get_children() 数得出来)。
# 生产里三条 RPC 应答确实可能落在同一帧(ingest 每收到一条就可能触发一次重绘)。本仓在"热重建视觉"那处踩过同款(WeaponPickup.configure)。
func redraw() -> void:
	for c in page._grid.get_children():
		page._grid.remove_child(c)
		c.queue_free()
	var shown := 0
	var total := 0
	for mode in [PvpSession.MODE_PVP, PvpSession.MODE_ROYALE, PvpSession.MODE_TEAM]:
		# 未满优先、满房排最后 —— 在每个模式内部排。★★ sort_custom 的比较函数返回 true = a 排在 b 前面(不是"a 该往后挪"):要"未满的在前",就必须在 a 未满而 b 满时返回 true。
		# 写反(a 满时返回 true)= 满房排到了前面,与状态栏文案相反;而断言全按 meta 找卡、对顺序不敏感 ⇒ 零守卫(顺序断言随 lobby_* 探针已删·2026-10-09)。1v1 载荷没有 max_players ⇒ 默认 2,与卡片那处同一个默认值。
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


# 一张房卡 = 一颗 Button(卡本体就是可点区域)。★ 不用 PanelContainer + 覆盖层:那样"点不动"的判据会散在覆盖层的连接数上,而 disabled / focus_mode / pressed 三个原生属性都在 Button 上,判据落在同一个节点上。
# ★ 子节点一律 mouse_filter = IGNORE:内容画在 Button 之上,但点击必须落到卡本体,否则点文字那一片就等于没点。
func _make_card(r: Dictionary) -> Button:
	var mode := str(r.get("mode", PvpSession.MODE_PVP))
	var code := str(r.get("code", ""))
	var in_match := bool(r.get("in_match", false))
	var mine := PvpSession.can_rejoin_to(code, mode)

	var btn := Button.new()
	_style_card(btn)
	btn.custom_minimum_size = Vector2(_card_width(), 440)
	btn.size = Vector2(_card_width(), 440)
	btn.set_meta("code", code)
	btn.set_meta("mode", mode)
	btn.text = ""   # 内容全部自绘

	# ★ 卡底:外层 C_BORDER 线由 Button 自己的 stylebox 画,内层 C_INNER 线由这块内缩 1px 的透明底 PanelContainer 画(与 UiFactory.menu_panel() 同一个形状)。外壳必须仍是 Button(卡的 text 恒空 + meta("code") 是找卡的据点),所以不能真的把卡换成 PanelContainer;零守卫:读 meta("code") 的探针已删(2026-10-09)。
	var frame := PanelContainer.new()
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.offset_left = 1.0
	frame.offset_top = 1.0
	frame.offset_right = -1.0
	frame.offset_bottom = -1.0
	var fsb := StyleBoxFlat.new()
	fsb.bg_color = Color(0, 0, 0, 0)   # 只画线、不画底(底在外层 Button 上)
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

	# ★★ 次序是承重的:先问「这是我的房吗 + 凭据还在吗」(can_rejoin_to 已在上面算好),这一档可点(点了走回局);不是我的房,才轮到「对局中 ⇒ 禁用」那一档。
	# 反过来写 = 回局这一档连点都点不到,而一行报错都没有。
	btn.disabled = in_match and not mine
	if btn.disabled:
		btn.focus_mode = Control.FOCUS_NONE
		btn.modulate = Color(1, 1, 1, 0.55)   # 整体压暗:一眼看出这间进不去
	else:
		btn.focus_mode = Control.FOCUS_ALL
		btn.pressed.connect(func() -> void:
			Sfx.play("ui")
			# ★★ 回局那条路也要记下模式 —— 与"加入"那条同款。ESC 回主菜单 → 多人模式(新页,_current_mode == "")→ 点自己那间对局中的房 → try_rejoin_row → go_match → match_start → _enter_match_scene() 落进 else ⇒ 回局也会进错场景。
			# 没有这一行,_enter_match_scene 的 else(push_error)就是唯一能把它喊出来的地方。
			page._current_mode = mode
			if not page.try_rejoin_row(code, in_match, mode):
				page._join_code(code, mode))
	return btn


func _card_width() -> float:
	var usable := 1920.0 - PAGE_MARGIN * 2.0 - CARD_GAP * float(CARD_COLUMNS - 1)
	return floor(usable / float(CARD_COLUMNS))


# 卡头 = 一条标题带(方向 B):C_HEADER 底 + 只有下边一条 C_BORDER 线;左 = 模式名(模式色),右 = 状态角标。★ 与 UiFactory.header_strip() 同一个味道,但工厂版标题色固定为金、也不带右侧角标,故按同一套版式拼一条。
# ★ 角标三档次序:对局中 优先于 私密 · 我的 —— 一间对局中的私密房对别人根本不列出,能同时满足两条的只有"我的房且已开局",那时"对局中"是更有用的信息。
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
	# 与 UiFactory.header_strip 同一轮放大(12/6 → 20/12)。★ 这里是第二份字面量(工厂那条标题带不带右侧角标,故没走工厂)—— 两边要同步手改。
	sb.content_margin_left = 20.0
	sb.content_margin_right = 20.0
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
	# ★ 三档取色刻意避开 C_WARN —— 它在调色板里被钉死为「弹夹见底」单一语义(ui_factory.gd 明写只用于「低弹量/耗尽」);拿它表"私密"会让那个金色在大厅与 HUD 里指两件事。
	var badge_col := UiFactory.C_TEXT_DIM if in_match \
			else (UiFactory.C_TEXT if not is_public else UiFactory.C_ACCENT)
	var badge_l := UiFactory.label(badge, 16, badge_col)
	badge_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(badge_l)
	return strip


# 房卡底(方向 B 的凿刻感):外层一条 C_BORDER(常态)/ C_ACCENT(悬停/焦点),填充走 C_SURFACE;内层那条 C_INNER 线由子节点那块 frame 画。
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
	# ★ 1v1 的载荷没有 max_players(1v1 恒 2 人)—— 前端补,而不是去动那三个载荷的形状。
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
func _card_map_thumb(mode: String, map_path: String) -> Control:
	var frame := PanelContainer.new()
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.custom_minimum_size = Vector2(120, 120)
	frame.add_theme_stylebox_override("panel", UiFactory.panel_box())
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


# ★ 名字走 UiFactory.fit_name(名字, 14) 定宽截断(与结算页同款)—— 不截的话长昵称会把卡顶宽(卡宽是 4 列网格算出来的固定值,顶宽 = 整行错位);名单最多 3 行,超出显示 …等 N 人。
func _card_names(names_raw: Variant) -> Control:
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var names: Array = names_raw if names_raw is Array else []
	var shown := mini(names.size(), 3)
	for i in shown:
		var is_host := i == 0
		box.add_child(UiFactory.label("· %s%s" % [
				UiFactory.fit_name(str(names[i]), 14), "(房主)" if is_host else ""],
				16, UiFactory.C_TEXT_DIM))
	if names.size() > shown:
		box.add_child(UiFactory.label("…等 %d 人" % names.size(), 16, UiFactory.C_TEXT_DIM))
	return box
