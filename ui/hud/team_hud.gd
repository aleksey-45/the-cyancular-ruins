class_name TeamHud
extends CanvasLayer

# 3v3 团队对抗 HUD 界面：
# 包含顶部记分栏、网络延迟指示器与中央广播提示。
# 记分与胜负结算基于队伍阵营而非单个玩家序号。

const ST_COUNTDOWN := 0
const ST_PLAYING := 1
const ST_ROUND_OVER := 2
const ST_MATCH_OVER := 3

@onready var _broadcast: Broadcast = $Broadcast
@onready var _score_label: Label = $ScoreWrap/ScoreLabel
@onready var _ping_label: Label = $PingWrap/PingLabel

# 探针测试兼容属性：转发访问中央广播的主副标签
var _big: Label:
	get:
		return _broadcast.big if _broadcast != null else null
var _sub: Label:
	get:
		return _broadcast.sub if _broadcast != null else null

var _my_team := 0   # 本地玩家所属队伍编号，由对局初始化时注入


func set_my_team(t: int) -> void:
	_my_team = t


func _ready() -> void:
	PixelFont.shared()
	NetBus.local_round_state.connect(_on_round_state)
	NetBus.ping_updated.connect(_on_ping)
	_broadcast.set_broadcast(true, "对战开始", "第 1 局")


# 外部通知直接显示广播内容
func show_notice(big: String, sub: String = "") -> void:
	_broadcast.set_broadcast(true, big, sub)


func _process(delta: float) -> void:
	_broadcast.tick(delta)


func _on_ping(ms: int) -> void:
	_ping_label.text = "%dms" % ms
	_ping_label.add_theme_color_override("font_color", UiFactory.ping_color(ms))


func _on_round_state(data: Dictionary) -> void:
	var state: int = data.get("state", ST_PLAYING)
	var round: int = data.get("round", 1)
	var scores: Dictionary = data.get("scores", {})
	var rounds_won: Dictionary = data.get("rounds_won", {})
	var s1: int = int(scores.get(1, 0))
	var s2: int = int(scores.get(2, 0))
	var w1: int = int(rounds_won.get(1, 0))
	var w2: int = int(rounds_won.get(2, 0))
	# 按队伍显示当前击杀数与大比分
	_score_label.text = "A 队击杀 %d        B 队击杀 %d        局胜 %d - %d        第 %d 局" % [
			s1, s2, w1, w2, round]
	match state:
		ST_COUNTDOWN:
			var sub := "对战开始" if round <= 1 else "第 %d 局" % round
			_broadcast.start_countdown(float(data.get("timer", 3.0)), sub)
		ST_PLAYING:
			_broadcast.set_broadcast(false, "", "")
		ST_ROUND_OVER:
			var winner: int = int(data.get("winner", 0))
			if winner != 0:
				var mine := winner == _my_team
				# 胜利条件为单局达到目标击杀数
				_broadcast.set_broadcast(true, "本局胜利!" if mine else "本局落败",
						("A 队" if winner == 1 else "B 队") + " 先到 9 杀")
			else:
				_broadcast.set_broadcast(true, "本局结束", "局胜 %d - %d" % [w1, w2])
		ST_MATCH_OVER:
			var mwinner: int = int(data.get("match_winner", 0))
			# 当队伍全员离场时整场判为平局
			if mwinner == _my_team and _my_team != 0:
				_broadcast.set_broadcast(true, "胜利!", "你们赢下了整场对战")
			elif mwinner != 0:
				_broadcast.set_broadcast(true, "失败", "再接再厉…")
			else:
				_broadcast.set_broadcast(true, "平 局", "双方都离开了对局…")

