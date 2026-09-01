class_name PvpHud
extends CanvasLayer

# PvP 回合记分 HUD:代码式 CanvasLayer,层级在 PostProcess(128) 与单机 HUD(129) 之上。
# 显示双方击杀/局胜/局号 + 中央状态(准备倒计时 / 胜局 / 获胜)。
const LAYER := 130
const FONT_PATH := "res://assets/fonts/less_perfect_dos_vga.ttf"
const COLOR_SCORE := Color(0.9, 0.95, 1.0)
const COLOR_STATUS := Color(1.0, 0.9, 0.4)

# 与 MatchHost.RoundState 枚举一致(客户端不直接引用服务器类)
const ST_COUNTDOWN := 0
const ST_PLAYING := 1
const ST_ROUND_OVER := 2
const ST_MATCH_OVER := 3

var _score_label: Label
var _status_label: Label
var _countdown := 0.0
var _in_countdown := false

func _ready() -> void:
	layer = LAYER
	_score_label = _make_label(Vector2(16, 16), 24, COLOR_SCORE)
	_status_label = _make_label(Vector2(0, 180), 48, COLOR_STATUS)
	_status_label.anchor_left = 0.5
	_status_label.anchor_right = 0.5
	_status_label.offset_left = -400
	_status_label.offset_right = 400
	_status_label.offset_top = 180
	_status_label.offset_bottom = 180 + 48 * 1.4
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.text = "对战开始…"
	NetBus.local_round_state.connect(_on_round_state)
	NetBus.local_kill_event.connect(_on_kill_event)

# 倒计时数字本地走秒(服务器只在状态切换时广播一次 round_state)
func _process(delta: float) -> void:
	if _in_countdown:
		_countdown -= delta
		_status_label.text = "准备! %d" % maxi(ceili(_countdown), 1)
		if _countdown <= 0.0:
			_in_countdown = false

func _make_label(pos: Vector2, size: int, color: Color) -> Label:
	var l := Label.new()
	l.position = pos
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_size_override("font_size", size)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var pf: FontFile = load(FONT_PATH) as FontFile
	if pf != null:
		pf.antialiasing = TextServer.FONT_ANTIALIASING_NONE
		pf.hinting = TextServer.HINTING_NONE
		pf.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
		l.add_theme_font_override("font", pf)
	# HUD 自身 _ready 时父节点可能还在 setup(add_child 会失败),延迟挂子节点(同 hud.gd)。
	call_deferred("add_child", l)
	return l

func _on_round_state(data: Dictionary) -> void:
	var state: int = data.get("state", ST_PLAYING)
	var round: int = data.get("round", 1)
	var scores: Dictionary = data.get("scores", {})
	var rounds_won: Dictionary = data.get("rounds_won", {})
	var s1: int = int(scores.get(1, 0))
	var s2: int = int(scores.get(2, 0))
	var w1: int = int(rounds_won.get(1, 0))
	var w2: int = int(rounds_won.get(2, 0))
	_score_label.text = "P1 击杀 %d    P2 击杀 %d    |    局胜 %d - %d    第 %d 局" % [s1, s2, w1, w2, round]
	match state:
		ST_COUNTDOWN:
			_countdown = float(data.get("timer", 3.0))
			_in_countdown = true
		ST_PLAYING:
			_in_countdown = false
			_status_label.text = ""
		ST_ROUND_OVER:
			_in_countdown = false
			var winner := 1 if w1 > w2 else 2
			_status_label.text = "P%d 赢得本局!" % winner
		ST_MATCH_OVER:
			_in_countdown = false
			var mwinner := 1 if w1 > w2 else 2
			_status_label.text = "P%d 获胜! 返回菜单…" % mwinner

func _on_kill_event(_killer: int, _victim: int) -> void:
	# 记分已由 round_state 更新;击杀播报可选
	pass
