class_name PvpHud
extends CanvasLayer

# PvP 对局 HUD(CanvasLayer layer=130,盖在 PostProcess/单机 HUD 之上)。
# 布局(遮罩/居中文案/记分/延迟与像素字体、颜色)已迁进 pvp_hud.tscn,这里只留信号驱动逻辑:
#  - 广播层:全屏 (0,0,0,0.3) 遮罩 + 屏幕正中央巨大白字——开场/倒计时/本局结果/胜利失败/断线通知统一走这里
#  - 记分(**顶部正中**):P1/P2 击杀、局胜、局号
#  - 延迟(右下角):NetBus.ping_updated 平滑 RTT

const ST_COUNTDOWN := 0
const ST_PLAYING := 1
const ST_ROUND_OVER := 2
const ST_MATCH_OVER := 3

@onready var _score_label: Label = $ScoreLabel
@onready var _mask: ColorRect = $Mask
@onready var _center: CenterContainer = $Center
@onready var _big: Label = $Center/VBox/BigLabel
@onready var _sub: Label = $Center/VBox/SubLabel
@onready var _ping_label: Label = $PingLabel

var _countdown := 0.0
var _in_countdown := false

func _ready() -> void:
	PixelFont.shared()   # 一次:共享字体关抗锯齿/微调/子像素,本场景所有像素 Label 全局锐利
	NetBus.local_round_state.connect(_on_round_state)
	NetBus.ping_updated.connect(_on_ping)
	_set_broadcast(true, "对战开始", "第 1 局")

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
	_ping_label.add_theme_color_override("font_color", _ping_color(ms))

# 延迟按阈值着色:绿(<60)/黄(<100)/橙(<150)/红(≥150)
func _ping_color(ms: int) -> Color:
	if ms < 60:
		return Color(0.45, 0.9, 0.45)
	if ms < 100:
		return Color(1.0, 0.85, 0.25)
	if ms < 150:
		return Color(1.0, 0.6, 0.15)
	return Color(1.0, 0.3, 0.3)

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
