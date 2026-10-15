class_name PvpHud
extends CanvasLayer

# PvP 对局 HUD(CanvasLayer layer=130,盖在 PostProcess/单机 HUD 之上):布局已迁进 pvp_hud.tscn + ui/hud/broadcast.tscn,这里只留信号驱动逻辑。
# 广播层(全屏 (0,0,0,0.3) 遮罩 + 屏幕正中央巨大字:开场/倒计时/本局结果/胜利失败/断线通知)由三个对局 HUD 共用 broadcast.tscn,本类只喂文案与时机;记分在顶部正中,延迟在右下角。

const ST_COUNTDOWN := 0
const ST_PLAYING := 1
const ST_ROUND_OVER := 2
const ST_MATCH_OVER := 3

@onready var _broadcast: Broadcast = $Broadcast
@onready var _score_label: Label = $ScoreWrap/ScoreLabel
@onready var _ping_label: Label = $PingWrap/PingLabel
@onready var _grace_wrap: PanelContainer = $GraceWrap
@onready var _grace_label: Label = $GraceWrap/GraceLabel

# 「对手掉线中」(role(int) -> 剩余秒):★ 服务器只在状态转折点广播 grace,两次之间由本类自己走秒(与 Broadcast.tick 同一取舍);那份减法的唯一实现是 GraceWindow.tick_display(别在这里手写一份)。
var _grace: Dictionary = {}

func _ready() -> void:
	PixelFont.shared()   # 一次:共享字体关抗锯齿/微调/子像素,本场景所有像素 Label 全局锐利
	NetBus.local_round_state.connect(_on_round_state)
	NetBus.ping_updated.connect(_on_ping)
	# 颜色只从调色板取(本次新增的第四种语义色,见 UiFactory.C_GRACE 那段的对比度实测)
	_grace_label.add_theme_color_override("font_color", UiFactory.C_GRACE)
	_broadcast.set_broadcast(true, "对战开始", "第 1 局")

func show_notice(big: String, sub: String = "") -> void:
	_broadcast.set_broadcast(true, big, sub)

# 倒计时数字走秒已收进 Broadcast;「对手掉线中」的秒数仍在本类 —— 两件事各自独立(掉线可能发生在倒计时里),故这里不写早退、两段都无条件跑。
func _process(delta: float) -> void:
	_broadcast.tick(delta)
	if not _grace.is_empty():
		_grace = GraceWindow.tick_display(_grace, delta)
		_refresh_grace()

# 「对手掉线中,等待重连… 剩余 Ns」。★ 1v1 的对手 role 恒为 3 - 自己(与副本、击杀播报、P2 染色同源)。
# ★ 判据写 has(opp) 而不是"取 _grace 的第一个键":后者在将来多出一个 role(比如观战位)时会印错人,而且不报错。
func _refresh_grace() -> void:
	var opp := 3 - PvpSession.role
	var has_opp: bool = _grace.has(opp)
	_grace_wrap.visible = has_opp
	if has_opp:
		_grace_label.text = "对手掉线中,等待重连… 剩余 %ds" % int(ceilf(float(_grace[opp])))

func _on_ping(ms: int) -> void:
# ★ 不带「延迟」二字,直接 "24ms"(用户要求):字数少一半 ⇒ 右下角占位更小,小地图能更贴近下边。
	_ping_label.text = "%dms" % ms
	# 阈值配色已抽到 UiFactory(单一来源,大乱斗那条也走它 —— 见 UiFactory.ping_color)
	_ping_label.add_theme_color_override("font_color", UiFactory.ping_color(ms))

func _on_round_state(data: Dictionary) -> void:
	# 「对手掉线中」的载荷:grace = {role -> 剩余秒}。★ 缺键 = 此刻没人掉线(服务端空表不带上该键,见 GraceWindow.merge_into)—— 不是"未知",也不是错误。
	# ★★ 本函数只在这里刷新一次(函数尾那次重复调用已删):尾那次是同参重刷、画面结果逐字相同 ⇒ 别在函数尾再加一次。
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
