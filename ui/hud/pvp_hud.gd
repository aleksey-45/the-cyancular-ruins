class_name PvpHud
extends CanvasLayer

const NAME_UNITS := 14
const BOARD_ROW_WIDTH := 712.0

@export var royale_ping_plate: StyleBox
var mode := PvpSession.MODE_PVP
var local_side := 1
var team_target := 0

@onready var _broadcast: Broadcast = $Broadcast
@onready var _score: Label = $ScoreWrap/ScoreLabel
@onready var _ping: Label = $PingWrap/PingLabel
@onready var _grace_wrap: PanelContainer = $GraceWrap
@onready var _grace_label: Label = $GraceWrap/GraceLabel
@onready var _board_bg: ColorRect = $BoardBg
@onready var _board: VBoxContainer = $BoardBox
@onready var _timer: Label = $BoardBox/TimerLabel

var _grace_left := -1.0
var _rows: Array[Label] = []
var _state := NetEvent.RoundState.COUNTDOWN
var _remaining := 0.0

func _ready() -> void:
	NetBus.ping_updated.connect(_on_ping)
	_grace_label.add_theme_color_override("font_color", UiFactory.C_GRACE)
	if mode == PvpSession.MODE_ROYALE:
		$ScoreWrap.hide()
		_board_bg.show()
		_board.show()
		$PingWrap.add_theme_stylebox_override("panel", royale_ping_plate)
		_broadcast.set_broadcast(true, "大乱斗", "等待开局…")
	elif mode == PvpSession.MODE_TEAM:
		_broadcast.set_broadcast(true, "等待玩家加载", "")
	else:
		_broadcast.set_broadcast(true, "对战开始", "第 1 局")

func _process(delta: float) -> void:
	_broadcast.tick(delta)
	if mode == PvpSession.MODE_ROYALE and _state == NetEvent.RoundState.PLAYING:
		_update_timer(_remaining - delta)
	if _grace_left >= 0.0:
		_update_grace(maxf(0.0, _grace_left - delta))

func _on_ping(ms: int) -> void:
	_ping.text = "%dms" % ms
	_ping.add_theme_color_override("font_color", UiFactory.ping_color(ms))

func _update_grace(seconds: float) -> void:
	_grace_left = seconds
	_grace_wrap.visible = seconds >= 0.0
	if _grace_wrap.visible:
		_grace_label.text = "对手掉线中,等待重连… 剩余 %ds" % ceili(seconds)

func show_round(data: Dictionary, names: Dictionary) -> void:
	_state = data["state"]
	if mode == PvpSession.MODE_ROYALE:
		_refresh_board(data, names)
		_show_royale_phase(data, names)
		return
	var team := mode == PvpSession.MODE_TEAM
	if not team:
		_update_grace(data["grace"].get(3 - local_side, -1.0))
	var scores: Dictionary = data["scores"]
	var wins: Dictionary = data["rounds_won"]
	var a: int = wins.get(1, 0)
	var b: int = wins.get(2, 0)
	var kills := "A 队击杀 %d        B 队击杀 %d" if team else "P1 击杀 %d        P2 击杀 %d"
	_score.text = (kills + "        局胜 %d - %d        第 %d 局") % [
			scores.get(1, 0), scores.get(2, 0), a, b, data["round"]]
	_broadcast.show_series_phase(data)
	match _state:
		NetEvent.RoundState.ROUND_OVER:
			var winner: int = data["winner"]
			var subtitle := "局胜 %d - %d" % [a, b]
			if team:
				subtitle = "%s 先到 %d 杀" % ["A 队" if winner == 1 else "B 队", team_target]
			_broadcast.set_broadcast(true, "本局胜利!" if winner == local_side else "本局落败", subtitle)
		NetEvent.RoundState.MATCH_OVER:
			var winner: int = data["match_winner"]
			if winner == local_side:
				_broadcast.set_broadcast(true, "胜利!", "你们赢下了整场对战" if team else "你赢得了整场对战")
			elif winner != 0:
				_broadcast.set_broadcast(true, "失败", "再接再厉…")
			else:
				_broadcast.set_broadcast(true, "平局", "双方都离开了对局…" if team else "对局结束")

func _update_timer(seconds: float) -> void:
	_remaining = maxf(seconds, 0.0)
	var whole := int(_remaining)
	_timer.text = "剩余时间  %d:%02d" % [whole / 60, whole % 60]

func _refresh_board(data: Dictionary, names: Dictionary) -> void:
	var scores: Dictionary = data["scores"]
	var roles := names.keys()
	roles.sort_custom(func(a: int, b: int) -> bool:
		var first: int = scores.get(a, 0)
		var second: int = scores.get(b, 0)
		return first > second if first != second else a < b)
	var resized := _rows.size() != roles.size()
	while _rows.size() > roles.size():
		var row: Label = _rows.pop_back()
		_board.remove_child(row)
		row.queue_free()
	while _rows.size() < roles.size():
		var row := UiFactory.label("", 32, UiFactory.C_TEXT)
		row.custom_minimum_size.x = BOARD_ROW_WIDTH
		row.size_flags_horizontal = Control.SIZE_FILL
		row.clip_text = true
		_board.add_child(row)
		_rows.append(row)
	if resized:
		_board_bg.size.y = _board.get_combined_minimum_size().y + 34
	for i in roles.size():
		var role: int = roles[i]
		var mine := role == local_side
		var tag := "存活"
		var color := UiFactory.C_ACCENT if mine else UiFactory.C_TEXT
		if data["left"].has(role):
			tag = "离开"
			color = UiFactory.C_DANGER
		elif data["grace"].has(role):
			tag = "掉线 %ds" % ceili(data["grace"][role])
			color = UiFactory.C_GRACE
		elif _state == NetEvent.RoundState.PLAYING and not data["alive"][role]:
			tag = "复活中"
			color = UiFactory.C_ACCENT if mine else UiFactory.C_TEXT_DIM
		var row := _rows[i]
		row.add_theme_color_override("font_color", color)
		row.text = "%d. %s  击杀 %d  阵亡 %d  %s" % [
				i + 1, UiFactory.fit_name(names[role], NAME_UNITS), scores.get(role, 0), data["stats"][role]["deaths"], tag]

func _show_royale_phase(data: Dictionary, names: Dictionary) -> void:
	match _state:
		NetEvent.RoundState.WAITING:
			_timer.text = "等待玩家加载"
			_broadcast.set_broadcast(true, "等待玩家加载", "")
		NetEvent.RoundState.COUNTDOWN:
			_timer.text = "准备…"
			_broadcast.start_countdown(data["timer"], "大乱斗开始")
		NetEvent.RoundState.PLAYING:
			_broadcast.set_broadcast(false, "", "")
			_update_timer(data["timer"])
		NetEvent.RoundState.MATCH_OVER:
			_timer.text = "对局结束"
			var winner: int = data["match_winner"]
			if winner == 0:
				_broadcast.set_broadcast(true, "平局", "杀敌数不相上下")
			elif winner == local_side:
				_broadcast.set_broadcast(true, "胜利！", "你是大乱斗之王")
			else:
				_broadcast.set_broadcast(true, "失败", "%s 赢得了大乱斗" % names[winner])
