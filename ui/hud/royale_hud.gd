class_name RoyaleHud
extends CanvasLayer


const LAYER := 130
# 颜色一律取 UiFactory 的调色板(单一来源,见 ui/ui_factory.gd 的 token 段)。
const COLOR_BOARD := UiFactory.C_TEXT
const COLOR_ME := UiFactory.C_ACCENT
const COLOR_DEAD := UiFactory.C_TEXT_DIM
const COLOR_LEFT := UiFactory.C_DANGER
# 「掉线中」= 还在宽限期内、可能回来:与上三档并列的第四种语义,故用调色板里新加的那一档(理由与实测对比度见 UiFactory.C_GRACE 那段);别为了省一个常量把它并进任何一档。
const COLOR_GRACE := UiFactory.C_GRACE

# 排行榜面板宽(原 480):一行要塞「名次 + 昵称 + 击杀 + 阵亡 + 状态」五段,480 时只要昵称稍长,末段就被顶出面板(实测 9 字昵称那行约 690px vs 面板 480)。
const BOARD_W := 720.0
# 排行榜几何(HUD 例外 = anchors + token):底板/内容列都锚 top-right,偏移全部由 BOARD_W / SP_* 算,
# 不再在 .tscn 里写 -736 / -716 / 96 / 102 这批从版式反推的魔法数(原先还叠着 1920/1440 口径)。
const BOARD_TOP := UiFactory.SP_9 + UiFactory.SP_6   # 96:离屏幕上沿
const BOARD_INSET := 6.0                             # 内容列相对底板的内缩(像素档)
const BOARD_BG_EXTRA := 34.0                         # 底板比内容多出的高度(上下留白;迁移不改像素)
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
	# 排行榜:右上角锚点 + token 偏移(替换 .tscn 里的魔法偏移;数值与迁移前逐像素相同)。
	_board_bg.anchor_left = 1.0
	_board_bg.anchor_right = 1.0
	_board_bg.offset_left = -(BOARD_W + UiFactory.SP_4)
	_board_bg.offset_right = -UiFactory.SP_4
	_board_bg.offset_top = BOARD_TOP
	_board_vbox.anchor_left = 1.0
	_board_vbox.anchor_right = 1.0
	_board_vbox.offset_left = -(BOARD_W - UiFactory.SP_1)
	_board_vbox.offset_right = -UiFactory.SP_1
	_board_vbox.offset_top = BOARD_TOP + BOARD_INSET
	_board_vbox.offset_bottom = _board_vbox.offset_top
	# 两块底板样式走 UiFactory 的 HUD 底板工厂(原先手写 StyleBoxFlat 的 _plate_box 已删):
	# 内容留白 14/6 与 10/4 是像素档,颜色仍是 C_PLATE(单一源在 UiFactory)。
	UiFactory.hud_plate(_ping_wrap, 14, 6)
	UiFactory.hud_plate(_hint_wrap, 10, 4)
	NetBus.local_round_state.connect(_on_round_state)
	NetBus.ping_updated.connect(_on_ping)
	_broadcast.countdown_finished.connect(_on_countdown_finished)
	_broadcast.set_broadcast(true, "大乱斗", "等待开局…")


func _on_countdown_finished() -> void:
	if _state == ST_PLAYING:
		_broadcast.set_broadcast(false, "", "")



# HUD 元素底板统一走 UiFactory.hud_plate(见 _ready);本文件不再有 StyleBox 构造。
static func _fit_name(s: String, max_units: int) -> String:
	return UiFactory.fit_name(s, max_units)


func _make_label(size: int, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiFactory.style_control(l, size)
	return l

func show_notice(big: String, sub: String = "") -> void:
	_broadcast.set_broadcast(true, big, sub)

func _process(delta: float) -> void:
	_broadcast.tick(delta)
	if _state == ST_PLAYING and not _broadcast.is_counting() and _timer_label.has_meta("remain"):
		var remain := float(_timer_label.get_meta("remain")) - delta
		_timer_label.set_meta("remain", remain)
		_timer_label.text = "剩余时间  %d:%02d" % [int(maxf(remain, 0.0)) / 60, int(maxf(remain, 0.0)) % 60]

func _on_ping(ms: int) -> void:
	_ping_label.text = "%dms" % ms
	# ★ 阈值配色:本条以前只吃 tscn 里那个静态灰蓝、从不上色,而 1v1 那条一直按阈值上色 ⇒ 同一个数字在两种模式里长得不一样;共用单一来源(与 PvpHud 同款)。
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
		var nl := _make_label(UiFactory.T_H2, COLOR_BOARD)
		nl.custom_minimum_size = Vector2(BOARD_W - UiFactory.SP_2, 0)
		nl.size_flags_horizontal = Control.SIZE_FILL
		nl.clip_text = true
		_board_vbox.add_child(nl)
		_rows.append(nl)
	if _rows.size() != _last_row_count:
		_last_row_count = _rows.size()
		_board_bg.size.y = _board_vbox.get_combined_minimum_size().y + BOARD_BG_EXTRA
	for i in range(rows.size()):
		var e: Dictionary = rows[i]
		var is_me: bool = e["name"] == _my_name
		var tag := "存活"
		var col := COLOR_BOARD if not is_me else COLOR_ME
		if left.has(e["role"]):
			tag = "离开"
			col = COLOR_LEFT
		elif grace.has(e["role"]):
			# 「掉线」= 还在宽限期内、可能会回来。★ 排在「离开」之后:离开是终态,而两者在同一帧都可能成立(服务器刚 _grace.leave 完就 mark_disconnected)⇒ 万一快照旧了一拍,「离开」才是该显示的那个。
			# ★★ 标签刻意取短:这一行本来就贴着面板宽(9 字昵称实测 ≈690px / 面板 720),「掉线 42s」比既有的「复活中」只多 2 单位;不要改成「掉线中,等待重连…」那种长句 —— 会把末段顶出面板(clip_text 静默裁掉,不是崩)。
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
