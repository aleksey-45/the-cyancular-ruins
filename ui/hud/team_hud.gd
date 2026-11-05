class_name TeamHud
extends CanvasLayer

# 团队对抗 HUD 界面：
# 包含顶部记分栏、网络延迟指示器与中央广播提示。
# 记分与胜负结算基于队伍阵营而非单个玩家序号。


@onready var _broadcast: Broadcast = $Broadcast
@onready var _score_label: Label = $ScoreWrap/ScoreLabel
@onready var _ping_label: Label = $PingWrap/PingLabel

var _my_team := 0   # 本地玩家所属队伍编号，由对局初始化时注入
var _counts: Dictionary = {}   # 基线冻结的团队人数，由客户端计算一次后注入


func set_my_team(t: int) -> void:
	_my_team = t


func set_team_counts(counts: Dictionary) -> void:
	_counts = counts


# 单局击杀目标由团队规则按总人数给出，不在 HUD 复制公式。
func _kills_to_win() -> int:
	if _counts.is_empty():
		return 0
	return TeamRules.kills_to_win(TeamRules.total_players(_counts))


func _ready() -> void:
	PixelFont.shared()
	NetBus.ping_updated.connect(_on_ping)
	_broadcast.set_broadcast(true, "等待玩家加载", "")


# 外部通知直接显示广播内容
func show_notice(big: String, sub: String = "") -> void:
	_broadcast.set_broadcast(true, big, sub)


func _process(delta: float) -> void:
	_broadcast.tick(delta)


func _on_ping(ms: int) -> void:
	_ping_label.text = "%dms" % ms
	_ping_label.add_theme_color_override("font_color", UiFactory.ping_color(ms))


func _on_round_state(data: Dictionary) -> void:
	if _counts.is_empty():
		_score_label.text = "等待玩家加载"
		_broadcast.set_broadcast(true, "等待玩家加载", "")
		return
	var state: int = data["state"]
	var round: int = data["round"]
	var scores: Dictionary = data["scores"]
	var rounds_won: Dictionary = data["rounds_won"]
	var s1: int = int(scores.get(1, 0))
	var s2: int = int(scores.get(2, 0))
	var w1: int = int(rounds_won.get(1, 0))
	var w2: int = int(rounds_won.get(2, 0))
	# 按队伍显示当前击杀数与大比分
	_score_label.text = "A 队击杀 %d        B 队击杀 %d        局胜 %d - %d        第 %d 局" % [
			s1, s2, w1, w2, round]
	match state:
		NetEvent.RoundState.WAITING:
			_broadcast.set_broadcast(true, "等待玩家加载", "")
		NetEvent.RoundState.COUNTDOWN:
			var sub := "对战开始" if round <= 1 else "第 %d 局" % round
			_broadcast.start_countdown(float(data["timer"]), sub)
		NetEvent.RoundState.PLAYING:
			_broadcast.set_broadcast(false, "", "")
		NetEvent.RoundState.ROUND_OVER:
			var winner: int = int(data["winner"])
			if winner != 0:
				var mine := winner == _my_team
				# 胜利条件为单局达到目标击杀数
				_broadcast.set_broadcast(true, "本局胜利!" if mine else "本局落败",
						("A 队" if winner == 1 else "B 队") + " 先到 %d 杀" % _kills_to_win())
			else:
				_broadcast.set_broadcast(true, "本局结束", "局胜 %d - %d" % [w1, w2])
		NetEvent.RoundState.MATCH_OVER:
			var mwinner: int = int(data["match_winner"])
			# 当队伍全员离场时整场判为平局
			if mwinner == _my_team and _my_team != 0:
				_broadcast.set_broadcast(true, "胜利!", "你们赢下了整场对战")
			elif mwinner != 0:
				_broadcast.set_broadcast(true, "失败", "再接再厉…")
			else:
				_broadcast.set_broadcast(true, "平局", "双方都离开了对局…")
