class_name RoyaleHud
extends CanvasLayer

# 大乱斗 HUD(CanvasLayer layer=130):
#  - 左上角击杀排行榜(实时):名次/昵称/击杀数/存活状态,自己高亮;下方显示剩余时间
#  - 广播层:全屏遮罩 + 居中巨字(开局倒计时/终局胜败)
#  - 延迟(右下角)
# 数据全部来自 round_state 载荷:{state, scores(总击杀), timer, names, alive, left, match_winner}

const LAYER := 130
const FONT_PATH := "res://assets/fonts/less_perfect_dos_vga.ttf"
const COLOR_BOARD := Color(0.92, 0.96, 1.0)
const COLOR_ME := Color(0.55, 0.95, 1.0)
const COLOR_DEAD := Color(0.65, 0.68, 0.72, 0.8)
const COLOR_LEFT := Color(0.9, 0.45, 0.35, 0.8)
const BIG_COLOR := Color(0.95, 0.95, 0.95, 0.9)
const SUB_COLOR := Color(0.82, 0.84, 0.9, 0.85)

const ST_COUNTDOWN := 0
const ST_PLAYING := 1
const ST_ROUND_OVER := 2
const ST_MATCH_OVER := 3

var _board_vbox: VBoxContainer
var _board_title: Label
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

	# ── 左上角排行榜(半透明底 + VBox 行) ──
	_board_bg = ColorRect.new()
	_board_bg.color = Color(0.0, 0.0, 0.0, 0.4)
	_board_bg.position = Vector2(16, 16)
	_board_bg.size = Vector2(480, 64)
	_board_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_board_bg)
	_board_vbox = VBoxContainer.new()
	_board_vbox.position = Vector2(28, 22)
	_board_vbox.custom_minimum_size = Vector2(456, 0)
	_board_vbox.add_theme_constant_override("separation", 4)
	_board_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_board_vbox)
	_board_title = _make_label(30, COLOR_ME)
	_board_title.text = "—— 击杀排行榜 ——"
	_board_vbox.add_child(_board_title)
	_timer_label = _make_label(26, COLOR_BOARD)
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
	_big = _make_label(150, BIG_COLOR)
	_sub = _make_label(64, SUB_COLOR)
	vbox.add_child(_big)
	vbox.add_child(_sub)
	_center.add_child(vbox)
	add_child(_center)

	# ── 延迟:右下角 ──
	_ping_label = _make_label(24, Color(0.75, 0.8, 0.9, 0.9))
	_ping_label.anchor_left = 1.0
	_ping_label.anchor_right = 1.0
	_ping_label.anchor_top = 1.0
	_ping_label.anchor_bottom = 1.0
	_ping_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_ping_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_ping_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_ping_label.offset_left = -260
	_ping_label.offset_right = -20
	_ping_label.offset_top = -54
	_ping_label.offset_bottom = -18
	_ping_label.text = "延迟 -- ms"
	add_child(_ping_label)

	NetBus.local_round_state.connect(_on_round_state)
	NetBus.ping_updated.connect(_on_ping)
	_set_broadcast(true, "大乱斗", "等待开局…")

func _make_label(size: int, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", size)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var pf: FontFile = load(FONT_PATH) as FontFile
	if pf != null:
		pf.antialiasing = TextServer.FONT_ANTIALIASING_NONE
		pf.hinting = TextServer.HINTING_NONE
		pf.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
		l.add_theme_font_override("font", pf)
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
	# ── 排行榜:按击杀降序 ──
	for c in _board_vbox.get_children():
		if c != _board_title and c != _timer_label:
			c.queue_free()
	var rows: Array = []
	for role_s in names:
		rows.append({"role": int(role_s), "name": str(names[role_s]),
				"kills": int(scores.get(int(role_s), 0))})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["kills"] != b["kills"]:
			return a["kills"] > b["kills"]
		return a["role"] < b["role"])
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
		var row := _make_label(24, col)
		row.text = "%d. %s   击杀 %d   %s" % [i + 1, e["name"], e["kills"], tag]
		_board_vbox.add_child(row)
	# 底板高度随行数自适应(标题 + 计时 + N 行 + 内边距)
	_board_bg.size.y = _board_vbox.get_combined_minimum_size().y + 14

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
