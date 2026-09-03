class_name PvpHud
extends CanvasLayer

# PvP 对局 HUD(CanvasLayer layer=130,盖在 PostProcess/单机 HUD 之上):
#  - 广播层:全屏 (0,0,0,0.3) 遮罩 + 屏幕正中央巨大白字——开场/倒计时/本局结果/胜利失败/断线通知统一走这里
#  - 记分(左下角):P1/P2 击杀、局胜、局号
#  - 延迟(右下角):NetBus.ping_updated 平滑 RTT
const LAYER := 130
const FONT_PATH := "res://assets/fonts/less_perfect_dos_vga.ttf"
const COLOR_SCORE := Color(0.9, 0.95, 1.0)
const MASK_COLOR := Color(0.0, 0.0, 0.0, 0.3)
const BIG_COLOR := Color(0.95, 0.95, 0.95, 0.9)
const SUB_COLOR := Color(0.82, 0.84, 0.9, 0.85)

const ST_COUNTDOWN := 0
const ST_PLAYING := 1
const ST_ROUND_OVER := 2
const ST_MATCH_OVER := 3

var _score_label: Label
var _mask: ColorRect
var _center: CenterContainer
var _big: Label          # 广播主文案(巨字)
var _sub: Label          # 广播副文案(第几局/局胜比分)
var _ping_label: Label
var _countdown := 0.0
var _in_countdown := false

func _ready() -> void:
	layer = LAYER
	# ── 广播层:全屏遮罩 + 居中 VBox(主/副文案) ──
	_mask = ColorRect.new()
	_mask.color = MASK_COLOR
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

	# ── 记分:左下角 ──
	_score_label = _make_label(34, COLOR_SCORE)
	_score_label.anchor_top = 1.0
	_score_label.anchor_bottom = 1.0
	_score_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_score_label.offset_left = 20
	_score_label.offset_right = 980
	_score_label.offset_top = -72
	_score_label.offset_bottom = -18
	add_child(_score_label)

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
	_score_label.text = ""
	_set_broadcast(true, "对战开始", "第 1 局")

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

# 外部(如断线通知)直接弹广播;countdown 计时由 _process 续写
func show_notice(big: String, sub: String = "") -> void:
	_in_countdown = false
	_set_broadcast(true, big, sub)

# 倒计时数字本地走秒(服务器只在状态切换时广播一次 round_state)
func _process(delta: float) -> void:
	if not _in_countdown:
		return
	_countdown -= delta
	if _countdown > 0.0:
		_big.text = str(maxi(ceili(_countdown), 1))
	else:
		_in_countdown = false

func _on_ping(ms: int) -> void:
	_ping_label.text = "延迟 %d ms" % ms

func _on_round_state(data: Dictionary) -> void:
	var state: int = data.get("state", ST_PLAYING)
	var round: int = data.get("round", 1)
	var scores: Dictionary = data.get("scores", {})
	var rounds_won: Dictionary = data.get("rounds_won", {})
	var s1: int = int(scores.get(1, 0))
	var s2: int = int(scores.get(2, 0))
	var w1: int = int(rounds_won.get(1, 0))
	var w2: int = int(rounds_won.get(2, 0))
	_score_label.text = "P1 击杀 %d    P2 击杀 %d    -    局胜 %d - %d    第 %d 局" % [s1, s2, w1, w2, round]
	var me: int = PvpSession.role
	match state:
		ST_COUNTDOWN:
			_countdown = float(data.get("timer", 3.0))
			_in_countdown = true
			# 主文案 = 巨大倒计时数字(_process 续写);副文案 = 第几局(首局用"对战开始")
			var sub := "对战开始" if round <= 1 else "第 %d 局" % round
			_set_broadcast(true, str(maxi(ceili(_countdown), 1)), sub)
		ST_PLAYING:
			_in_countdown = false
			_set_broadcast(false, "", "")
		ST_ROUND_OVER:
			_in_countdown = false
			var winner: int = int(data.get("winner", 0))
			if winner != 0:
				_set_broadcast(true, "本局胜利!" if winner == me else "本局落败",
						"局胜 %d - %d" % [w1, w2])
			else:
				_set_broadcast(true, "P%d 赢得本局!" % (1 if w1 > w2 else 2), "局胜 %d - %d" % [w1, w2])
		ST_MATCH_OVER:
			_in_countdown = false
			var mwinner: int = int(data.get("match_winner", 0))
			if mwinner == me:
				_set_broadcast(true, "胜利!", "你赢得了整场对战")
			elif mwinner != 0:
				_set_broadcast(true, "失败", "再接再厉…")
			else:
				_set_broadcast(true, "P%d 获胜!" % (1 if w1 > w2 else 2), "对局结束,返回菜单…")
