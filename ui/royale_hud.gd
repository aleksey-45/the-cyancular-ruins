class_name RoyaleHud
extends CanvasLayer

# 大乱斗 HUD(CanvasLayer layer=130):
#  - 右上角击杀排行榜(实时):名次/昵称/击杀数/存活状态,自己高亮;下方显示剩余时间
#  - 广播层:全屏遮罩 + 居中巨字(开局倒计时/终局胜败)
#  - 延迟(右下角)
# 数据全部来自 round_state 载荷:{state, scores(总击杀), timer, names, alive, left, match_winner}
#
# 字体来源:统一走 UiFactory.style_control(内部转调 core/pixel_font.gd 的 PixelFont.shared()),
# 不再自建 load(ttf) + theme override 抄本。字号必须是 16 的倍数(本项目像素字体硬约定,
# 见 ui/ui_factory.gd 文件头)—— 本文件全部字号已按 16 归一。

const LAYER := 130
# 颜色一律取 UiFactory 的调色板(单一来源,见 ui/ui_factory.gd 的 token 段)。
const COLOR_BOARD := UiFactory.C_TEXT
const COLOR_ME := UiFactory.C_ACCENT
const COLOR_DEAD := UiFactory.C_TEXT_DIM
const COLOR_LEFT := UiFactory.C_DANGER
const BIG_COLOR := UiFactory.C_TEXT
const SUB_COLOR := UiFactory.C_TEXT_DIM

# 排行榜面板宽(原 480):一行要塞「名次 + 昵称 + 击杀 + 阵亡 + 状态」五段,
# 480 时只要昵称稍长,末段的「存活/复活中/离开」就被顶出面板(2026-09-13 实测:
# 9 字昵称那行约 690px vs 面板 480)。
const BOARD_W := 720.0
# 昵称列的显示宽度上限(半角单位;汉字算 2)。超出按 … 截断 —— 状态段必须留在面板内。
const NAME_UNITS := 14

const ST_COUNTDOWN := 0
const ST_PLAYING := 1
const ST_ROUND_OVER := 2
const ST_MATCH_OVER := 3

var _board_vbox: VBoxContainer
var _board_title: Label
# 排行榜行 Label(不含标题/计时):**复用**而不是每次重建 —— 见 _on_round_state 里的说明
var _rows: Array[Label] = []
var _last_row_count := -1
var _board_bg: ColorRect
var _timer_label: Label
var _mask: ColorRect
var _center: CenterContainer
var _big: Label
var _sub: Label
var _ping_label: Label
var _countdown := 0.0
var _in_countdown := false
var _state := ST_COUNTDOWN
var _my_name := "Anon"

func _ready() -> void:
	layer = LAYER
	_my_name = PvpSession.player_name

	# ── 排行榜(右上角、击杀计数下方;血条在左上角,不重叠)──
	_board_bg = ColorRect.new()
	_board_bg.color = Color(0.0, 0.0, 0.0, 0.45)   # 深底板:排行榜直接压在地图上,浅色开阔区会吃掉文字
	_board_bg.position = Vector2(1920 - BOARD_W - 16, 96)
	_board_bg.size = Vector2(BOARD_W, 64)
	_board_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_board_bg)
	_board_vbox = VBoxContainer.new()
	_board_vbox.position = Vector2(1920 - BOARD_W - 4, 102)
	_board_vbox.custom_minimum_size = Vector2(BOARD_W - 8.0, 0)
	_board_vbox.add_theme_constant_override("separation", 4)
	_board_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_board_vbox)
	_board_title = _make_label(32, COLOR_ME)
	_board_title.text = "—— 击杀排行榜 ——"
	_board_vbox.add_child(_board_title)
	_timer_label = _make_label(32, COLOR_BOARD)
	_board_vbox.add_child(_timer_label)

	# ── 广播层 ──
	_mask = ColorRect.new()
	_mask.color = Color(0.0, 0.0, 0.0, 0.3)
	_mask.set_anchors_preset(Control.PRESET_FULL_RECT)
	_mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mask.visible = false
	add_child(_mask)
	_center = CenterContainer.new()
	_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_center.visible = false
	var vbox := VBoxContainer.new()
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_big = _make_label(144, BIG_COLOR)
	_sub = _make_label(64, SUB_COLOR)
	vbox.add_child(_big)
	vbox.add_child(_sub)
	_center.add_child(vbox)
	add_child(_center)

	# ── 延迟:右下角 ──
	var ping_wrap := PanelContainer.new()
	ping_wrap.add_theme_stylebox_override("panel", _plate_box(14.0, 6.0))
	ping_wrap.anchor_left = 1.0
	ping_wrap.anchor_right = 1.0
	ping_wrap.anchor_top = 1.0
	ping_wrap.anchor_bottom = 1.0
	ping_wrap.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	ping_wrap.grow_vertical = Control.GROW_DIRECTION_BEGIN
	ping_wrap.offset_left = -24.0
	ping_wrap.offset_right = -24.0
	ping_wrap.offset_top = -24.0
	ping_wrap.offset_bottom = -24.0
	ping_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(ping_wrap)
	_ping_label = _make_label(32, UiFactory.C_TEXT_DIM)
	_ping_label.text = "延迟 -- ms"
	ping_wrap.add_child(_ping_label)

	# ── 按键提示(左下角):自杀脱困 ──
	var hint_wrap := PanelContainer.new()
	hint_wrap.add_theme_stylebox_override("panel", _plate_box(10.0, 4.0))
	hint_wrap.position = Vector2(16, 1386)
	hint_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hint_wrap)
	var hint := _make_label(16, UiFactory.C_TEXT_DIM)
	hint.text = "K = 自杀脱困(卡住时)"
	hint_wrap.add_child(hint)

	NetBus.local_round_state.connect(_on_round_state)
	NetBus.ping_updated.connect(_on_ping)
	_set_broadcast(true, "大乱斗", "等待开局…")

# HUD 元素底板(与单机 HUD 同一套做法,见 ui/hud.gd 的 PLATE_COLOR):
# 对局 HUD 直接压在地图上,地图开阔区是浅灰蓝 —— 不垫底时浅色小字读不出来。
static func _plate_box(pad_x: float, pad_y: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.45)
	sb.set_corner_radius_all(0)
	sb.content_margin_left = pad_x
	sb.content_margin_right = pad_x
	sb.content_margin_top = pad_y
	sb.content_margin_bottom = pad_y
	return sb


# 昵称**定宽**成一列:按显示宽度(汉字/全角算 2 个半角单位)截断,超出补 …,
# 不足的用半角空格补满。截断保证后面的状态段不被顶出面板;补满让「击杀/阵亡/状态」
# 三列在行与行之间纵向对齐(不补的话短昵称那几行的列是错开的,整块读起来是一堆居中字)。
# 单位宽度按字体算:拉丁走 8x16 的 DOS 位图(半角 8px),汉字走 16px 网格的 Unifont ——
# 在 32px 字号下半角 16px、全角 32px,故「1 单位 = 半角字符宽」成立。
static func _fit_name(s: String, max_units: int) -> String:
	var units := 0
	var out := ""
	for i in s.length():
		var w := 2 if s.unicode_at(i) > 0x2E80 else 1
		if units + w > max_units:
			out += "…"
			units += 1
			break
		units += w
		out += s[i]
	while units < max_units:
		out += " "
		units += 1
	return out


func _make_label(size: int, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 字体 + 字号统一由工厂套用(唯一字体来源;size 必须是 16 的倍数,工厂内有 assert 守卫)
	UiFactory.style_control(l, size)
	return l

func _set_broadcast(show: bool, big: String, sub: String) -> void:
	_mask.visible = show
	_center.visible = show
	_big.text = big
	_sub.text = sub

func show_notice(big: String, sub: String = "") -> void:
	_in_countdown = false
	_set_broadcast(true, big, sub)

# 倒计时数字本地走秒(服务器只在状态切换/每秒同步时广播 round_state)
func _process(delta: float) -> void:
	if _in_countdown:
		_countdown -= delta
		if _countdown > 0.0:
			_big.text = str(maxi(ceili(_countdown), 1))
		else:
			_in_countdown = false
			if _state == ST_PLAYING:
				_set_broadcast(false, "", "")
	# 剩余时间本地走秒微调(每秒有服务器广播校正)
	if _state == ST_PLAYING and not _in_countdown and _timer_label.has_meta("remain"):
		var remain := float(_timer_label.get_meta("remain")) - delta
		_timer_label.set_meta("remain", remain)
		_timer_label.text = "剩余时间  %d:%02d" % [int(maxf(remain, 0.0)) / 60, int(maxf(remain, 0.0)) % 60]

func _on_ping(ms: int) -> void:
	_ping_label.text = "延迟 %d ms" % ms

func _on_round_state(data: Dictionary) -> void:
	var state := int(data.get("state", ST_PLAYING))
	_state = state
	var scores: Dictionary = data.get("scores", {})
	var names: Dictionary = data.get("names", {})
	var alive: Dictionary = data.get("alive", {})
	var left: Array = data.get("left", [])
	var deaths: Dictionary = data.get("deaths", {})
	# ── 排行榜:按击杀降序 ──
	# ★ **复用行、只改文字**，不要每次 queue_free 后重建 N 个 Label。
	#   本函数每秒被调一次(round_state 的 HUD 同步),每次阵亡再加一次;重建 N 个 Label 的
	#   同步成本实测 2.6 / 3.8 / 4.7 ms(4 / 6 / 8 行),是纯粹的每秒浪费 ——
	#   见 tests/royale_hud_cost_probe.tscn 与 docs/royale-soak-2026-09-12.md §3.1。
	#   行数**只在人数变化时**才对不齐(进/退场),那时才增删。
	var rows: Array = []
	for role_s in names:
		rows.append({"role": int(role_s), "name": str(names[role_s]),
				"kills": int(scores.get(int(role_s), 0)),
				"deaths": int(deaths.get(int(role_s), 0))})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["kills"] != b["kills"]:
			return a["kills"] > b["kills"]
		return a["role"] < b["role"])
	while _rows.size() > rows.size():
		(_rows.pop_back() as Label).queue_free()
	while _rows.size() < rows.size():
		var nl := _make_label(32, COLOR_BOARD)
		# 钉死行宽 + 兜底裁剪:文本宽度不再由内容决定(昵称长短不一把整行撑出面板)。
		nl.custom_minimum_size = Vector2(BOARD_W - 8.0, 0)
		nl.size_flags_horizontal = Control.SIZE_FILL
		nl.clip_text = true
		_board_vbox.add_child(nl)
		_rows.append(nl)
	if _rows.size() != _last_row_count:
		_last_row_count = _rows.size()
		# 底板高度随行数自适应(标题 + 计时 + N 行 + 内边距)。
		# 只在行数变了才取 combined_minimum_size —— 它内部强制一次 layout,不该每秒付。
		_board_bg.size.y = _board_vbox.get_combined_minimum_size().y + 14
	for i in range(rows.size()):
		var e: Dictionary = rows[i]
		var is_me: bool = e["name"] == _my_name
		var tag := "存活"
		var col := COLOR_BOARD if not is_me else COLOR_ME
		if left.has(e["role"]):
			tag = "离开"
			col = COLOR_LEFT
		elif not bool(alive.get(e["role"], true)) and state == ST_PLAYING:
			tag = "复活中"
			col = COLOR_DEAD if not is_me else COLOR_ME
		var row: Label = _rows[i]
		row.add_theme_color_override("font_color", col)
		row.text = "%d. %s  击杀 %d  阵亡 %d  %s" % [
				i + 1, _fit_name(str(e["name"]), NAME_UNITS), e["kills"], e["deaths"], tag]

	# ── 中央广播 ──
	var me_alive := true
	for e in rows:
		if e["name"] == _my_name:
			me_alive = bool(alive.get(e["role"], true))
	match state:
		ST_COUNTDOWN:
			_countdown = float(data.get("timer", 3.0))
			_in_countdown = true
			_timer_label.text = "准备…"
			_set_broadcast(true, str(maxi(ceili(_countdown), 1)), "大乱斗开始")
		ST_PLAYING:
			_in_countdown = false
			_set_broadcast(false, "", "")
			var remain := float(data.get("timer", 300.0))
			_timer_label.set_meta("remain", remain)
			_timer_label.text = "剩余时间  %d:%02d" % [int(remain) / 60, int(remain) % 60]
		ST_MATCH_OVER:
			_in_countdown = false
			_timer_label.text = "对局结束"
			var mw := int(data.get("match_winner", 0))
			if mw == 0:
				_set_broadcast(true, "平 局", "杀敌数不相上下")
			elif rows.size() > 0 and mw != 0:
				# winner 名字:names 里 role==mw
				var wname := str(names.get(str(mw), names.get(mw, "P%d" % mw)))
				if wname == _my_name:
					_set_broadcast(true, "胜 利 !", "你是大乱斗之王")
				else:
					_set_broadcast(true, "失 败", "%s 赢得了大乱斗" % wname)
		_:
			pass
