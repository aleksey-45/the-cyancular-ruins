class_name RoyaleHud
extends CanvasLayer

# 多人大乱斗 HUD 界面：
# 包含右上角实时击杀排行榜、剩余倒计时、中央广播通知与右下角网络延迟指示。
# 数据由服务端权威 round_state 快照周期性同步驱动。

const LAYER := 130

# 界面配色均取自统一调色板
const COLOR_BOARD := UiFactory.C_TEXT
const COLOR_ME := UiFactory.C_ACCENT
const COLOR_DEAD := UiFactory.C_TEXT_DIM
const COLOR_LEFT := UiFactory.C_DANGER
const COLOR_GRACE := UiFactory.C_GRACE

const BOARD_W := 720.0
const NAME_UNITS := 14

const ST_COUNTDOWN := 0
const ST_PLAYING := 1
const ST_ROUND_OVER := 2
const ST_MATCH_OVER := 3

@onready var _board_bg: ColorRect = $BoardBg
@onready var _board_vbox: VBoxContainer = $BoardBox
@onready var _timer_label: Label = $BoardBox/TimerLabel
@onready var _broadcast: Broadcast = $Broadcast
@onready var _ping_wrap: PanelContainer = $PingWrap
@onready var _ping_label: Label = $PingWrap/PingLabel
@onready var _hint_wrap: PanelContainer = $HintWrap

# 探针测试兼容属性：转发访问中央广播的主标签
var _big: Label:
	get:
		return _broadcast.big if _broadcast != null else null

var _rows: Array[Label] = []
var _last_row_count := -1
var _state := ST_COUNTDOWN
var _grace: Dictionary = {}
var _my_name := "Anon"

func _ready() -> void:
	layer = LAYER
	PixelFont.shared()
	_my_name = PvpSession.player_name
	_ping_wrap.add_theme_stylebox_override("panel", _plate_box(14.0, 6.0))
	_hint_wrap.add_theme_stylebox_override("panel", _plate_box(10.0, 4.0))
	NetBus.local_round_state.connect(_on_round_state)
	NetBus.ping_updated.connect(_on_ping)
	_broadcast.countdown_finished.connect(_on_countdown_finished)
	_broadcast.set_broadcast(true, "大乱斗", "等待开局…")


func _on_countdown_finished() -> void:
	if _state == ST_PLAYING:
		_broadcast.set_broadcast(false, "", "")


# 构造通用矩形底板样式
static func _plate_box(pad_x: float, pad_y: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = UiFactory.C_PLATE
	sb.set_corner_radius_all(0)
	sb.content_margin_left = pad_x
	sb.content_margin_right = pad_x
	sb.content_margin_top = pad_y
	sb.content_margin_bottom = pad_y
	return sb


# 对昵称进行等宽约束截断
static func _fit_name(s: String, max_units: int) -> String:
	return UiFactory.fit_name(s, max_units)


func _make_label(size: int, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiFactory.style_control(l, size)
	return l

# 外部通知直接显示广播内容
func show_notice(big: String, sub: String = "") -> void:
	_broadcast.set_broadcast(true, big, sub)


func _process(delta: float) -> void:
	_broadcast.tick(delta)
	# 对局进行中平滑更新剩余时间
	if _state == ST_PLAYING and not _broadcast.is_counting() and _timer_label.has_meta("remain"):
		var remain := float(_timer_label.get_meta("remain")) - delta
		_timer_label.set_meta("remain", remain)
		_timer_label.text = "剩余时间  %d:%02d" % [int(maxf(remain, 0.0)) / 60, int(maxf(remain, 0.0)) % 60]

func _on_ping(ms: int) -> void:
	_ping_label.text = "%dms" % ms
	_ping_label.add_theme_color_override("font_color", UiFactory.ping_color(ms))

func _on_round_state(data: Dictionary) -> void:
	var state := int(data.get("state", ST_PLAYING))
	_state = state
	var names: Dictionary = data.get("names", {})
	var alive: Dictionary = data.get("alive", {})
	var left: Array = data.get("left", [])
	var deaths: Dictionary = data.get("deaths", {})
	var scores: Dictionary = data.get("scores", {})
	_grace = data.get("grace", {})
	var rows := _refresh_board(names, scores, deaths, alive, left, _grace, state)
	_refresh_broadcast(state, data, names, rows, alive)


# 刷新排行榜数据与显示行，优先复用已有标签以避免每秒频繁重建的内存开销
func _refresh_board(names: Dictionary, scores: Dictionary, deaths: Dictionary,
		alive: Dictionary, left: Array, grace: Dictionary, state: int) -> Array:
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
		nl.custom_minimum_size = Vector2(BOARD_W - 8.0, 0)
		nl.size_flags_horizontal = Control.SIZE_FILL
		nl.clip_text = true
		_board_vbox.add_child(nl)
		_rows.append(nl)
	if _rows.size() != _last_row_count:
		_last_row_count = _rows.size()
		# 底板高度随玩家行数自适应调整
		_board_bg.size.y = _board_vbox.get_combined_minimum_size().y + 34
	for i in range(rows.size()):
		var e: Dictionary = rows[i]
		var is_me: bool = e["name"] == _my_name
		var tag := "存活"
		var col := COLOR_BOARD if not is_me else COLOR_ME
		if left.has(e["role"]):
			tag = "离开"
			col = COLOR_LEFT
		elif grace.has(e["role"]):
			tag = "掉线 %ds" % int(ceilf(float(grace[e["role"]])))
			col = COLOR_GRACE
		elif not bool(alive.get(e["role"], true)) and state == ST_PLAYING:
			tag = "复活中"
			col = COLOR_DEAD if not is_me else COLOR_ME
		var row: Label = _rows[i]
		row.add_theme_color_override("font_color", col)
		row.text = "%d. %s  击杀 %d  阵亡 %d  %s" % [
				i + 1, _fit_name(str(e["name"]), NAME_UNITS), e["kills"], e["deaths"], tag]
	return rows


# 刷新中央广播提示内容
func _refresh_broadcast(state: int, data: Dictionary, names: Dictionary, rows: Array,
		alive: Dictionary) -> void:
	match state:
		ST_COUNTDOWN:
			_timer_label.text = "准备…"
			_broadcast.start_countdown(float(data.get("timer", 3.0)), "大乱斗开始")
		ST_PLAYING:
			_broadcast.set_broadcast(false, "", "")
			var remain := float(data.get("timer", 300.0))
			_timer_label.set_meta("remain", remain)
			_timer_label.text = "剩余时间  %d:%02d" % [int(remain) / 60, int(remain) % 60]
		ST_MATCH_OVER:
			_timer_label.text = "对局结束"
			var mw := int(data.get("match_winner", 0))
			if mw == 0:
				_broadcast.set_broadcast(true, "平 局", "杀敌数不相上下")
			elif rows.size() > 0 and mw != 0:
				var wname := str(names.get(str(mw), names.get(mw, "P%d" % mw)))
				if wname == _my_name:
					_broadcast.set_broadcast(true, "胜 利 !", "你是大乱斗之王")
				else:
					_broadcast.set_broadcast(true, "失 败", "%s 赢得了大乱斗" % wname)
		_:
			pass

