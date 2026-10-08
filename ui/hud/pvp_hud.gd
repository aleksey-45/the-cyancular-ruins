class_name PvpHud
extends CanvasLayer

# 1v1 PvP 对局 HUD 界面：
# 包含中央广播通知、顶部记分栏、网络延迟显示以及对手掉线重连提示。

const ST_COUNTDOWN := 0
const ST_PLAYING := 1
const ST_ROUND_OVER := 2
const ST_MATCH_OVER := 3

@onready var _broadcast: Broadcast = $Broadcast
@onready var _score_label: Label = $ScoreWrap/ScoreLabel
@onready var _ping_label: Label = $PingWrap/PingLabel
@onready var _grace_wrap: PanelContainer = $GraceWrap
@onready var _grace_label: Label = $GraceWrap/GraceLabel

# 探针测试兼容属性：转发访问中央广播的遮罩与主标签
var _mask: ColorRect:
	get:
		return _broadcast.mask if _broadcast != null else null
var _big: Label:
	get:
		return _broadcast.big if _broadcast != null else null

# 对手掉线宽限期倒计时字典：角色编号 -> 剩余秒数
var _grace: Dictionary = {}

func _ready() -> void:
	PixelFont.shared()
	NetBus.local_round_state.connect(_on_round_state)
	NetBus.ping_updated.connect(_on_ping)
	_grace_label.add_theme_color_override("font_color", UiFactory.C_GRACE)
	_broadcast.set_broadcast(true, "对战开始", "第 1 局")

# 外部通知直接显示广播内容
func show_notice(big: String, sub: String = "") -> void:
	_broadcast.set_broadcast(true, big, sub)

# 更新中央广播与掉线倒计时
func _process(delta: float) -> void:
	_broadcast.tick(delta)
	if not _grace.is_empty():
		_grace = GraceWindow.tick_display(_grace, delta)
		_refresh_grace()

# 刷新对手掉线重连提示框
func _refresh_grace() -> void:
	var opp := 3 - PvpSession.role
	var has_opp: bool = _grace.has(opp)
	_grace_wrap.visible = has_opp
	if has_opp:
		_grace_label.text = "对手掉线中,等待重连… 剩余 %ds" % int(ceilf(float(_grace[opp])))

func _on_ping(ms: int) -> void:
	_ping_label.text = "%dms" % ms
	_ping_label.add_theme_color_override("font_color", UiFactory.ping_color(ms))

func _on_round_state(data: Dictionary) -> void:
	# 服务端下发宽限期状态更新并刷新界面
	_grace = data.get("grace", {})
	_refresh_grace()
	var state: int = data.get("state", ST_PLAYING)
	var round: int = data.get("round", 1)
	var scores: Dictionary = data.get("scores", {})
	var rounds_won: Dictionary = data.get("rounds_won", {})
	var s1: int = int(scores.get(1, 0))
	var s2: int = int(scores.get(2, 0))
	var w1: int = int(rounds_won.get(1, 0))
	var w2: int = int(rounds_won.get(2, 0))
	_score_label.text = "P1 击杀 %d        P2 击杀 %d        局胜 %d - %d        第 %d 局" % [
			s1, s2, w1, w2, round]
	var me: int = PvpSession.role
	match state:
		ST_COUNTDOWN:
			var sub := "对战开始" if round <= 1 else "第 %d 局" % round
			_broadcast.start_countdown(float(data.get("timer", 3.0)), sub)
		ST_PLAYING:
			_broadcast.set_broadcast(false, "", "")
		ST_ROUND_OVER:
			var winner: int = int(data.get("winner", 0))
			if winner != 0:
				_broadcast.set_broadcast(true, "本局胜利!" if winner == me else "本局落败",
						"局胜 %d - %d" % [w1, w2])
			else:
				_broadcast.set_broadcast(true, "P%d 赢得本局!" % (1 if w1 > w2 else 2), "局胜 %d - %d" % [w1, w2])
		ST_MATCH_OVER:
			var mwinner: int = int(data.get("match_winner", 0))
			if mwinner == me:
				_broadcast.set_broadcast(true, "胜利!", "你赢得了整场对战")
			elif mwinner != 0:
				_broadcast.set_broadcast(true, "失败", "再接再厉…")
			else:
				_broadcast.set_broadcast(true, "P%d 获胜!" % (1 if w1 > w2 else 2), "对局结束,返回菜单…")
