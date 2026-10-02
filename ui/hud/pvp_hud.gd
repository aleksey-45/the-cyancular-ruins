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

@onready var _score_label: Label = $ScoreWrap/ScoreLabel
@onready var _mask: ColorRect = $Mask
@onready var _center: CenterContainer = $Center
@onready var _big: Label = $Center/VBox/BigLabel
@onready var _sub: Label = $Center/VBox/SubLabel
@onready var _ping_label: Label = $PingWrap/PingLabel
@onready var _grace_wrap: PanelContainer = $GraceWrap
@onready var _grace_label: Label = $GraceWrap/GraceLabel

var _countdown := 0.0
var _in_countdown := false
# 「对手掉线中」(阶段 3,spec §4 的 3.1):role(int) -> 剩余秒。
# ★ 服务器只在**状态转折点**广播 `grace`,两次之间由本类**自己走秒**(与下面 `_countdown`
#   同款口径);那份减法的唯一实现是 `GraceWindow.tick_display`(别在这里手写一份)。
var _grace: Dictionary = {}

func _ready() -> void:
	PixelFont.shared()   # 一次:共享字体关抗锯齿/微调/子像素,本场景所有像素 Label 全局锐利
	NetBus.local_round_state.connect(_on_round_state)
	NetBus.ping_updated.connect(_on_ping)
	# 颜色只从调色板取(本次新增的第四种语义色,见 UiFactory.C_GRACE 那段的对比度实测)
	_grace_label.add_theme_color_override("font_color", UiFactory.C_GRACE)
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

# 倒计时数字本地走秒(服务器只在状态切换时广播一次 round_state);
# 「对手掉线中」的秒数同理 —— 两者共用一个 `_process`。
func _process(delta: float) -> void:
	if _in_countdown:
		_countdown -= delta
		if _countdown > 0.0:
			_big.text = str(maxi(ceili(_countdown), 1))
		else:
			_in_countdown = false
	# ★ 不受 `_in_countdown` 的早退影响(上面那两行是**缩进在 if 里**的,别改成早退):
	#   掉线可能发生在倒计时里,那时这两个数字都要各自走秒。
	if not _grace.is_empty():
		_grace = GraceWindow.tick_display(_grace, delta)
		_refresh_grace()

# 「对手掉线中,等待重连… 剩余 Ns」。
# ★ 1v1 的对手 role 恒为 `3 - 自己`(与副本、击杀播报、P2 染色同源)。
# ★ 判据写 `has(opp)` 而**不是**"取 `_grace` 的第一个键":后者在将来多出一个 role 时
#   (比如观战位)会印错人,而且**不报错**。
func _refresh_grace() -> void:
	var opp := 3 - PvpSession.role
	var has_opp: bool = _grace.has(opp)
	_grace_wrap.visible = has_opp
	if has_opp:
		_grace_label.text = "对手掉线中,等待重连… 剩余 %ds" % int(ceilf(float(_grace[opp])))

func _on_ping(ms: int) -> void:
	# ★ 不带「延迟」二字,直接 "24ms"(2026-09-17 用户要求)。字数少一半 → 右下角占位更小,
	#   小地图能更贴近下边(见 ui/minimap.gd 的 EDGE_BOTTOM)。
	_ping_label.text = "%dms" % ms
	# 阈值配色已抽到 UiFactory(单一来源,大乱斗那条也走它 —— 见 UiFactory.ping_color)
	_ping_label.add_theme_color_override("font_color", UiFactory.ping_color(ms))

func _on_round_state(data: Dictionary) -> void:
	# 「对手掉线中」(阶段 3,spec §4 的 3.1):载荷里 `grace` = {role -> 剩余秒}。
	# ★ **缺键 = 此刻没人掉线**(服务端空表不带上该键,见 `GraceWindow.merge_into`)——
	#   不是"未知",也不是错误。老客户端忽略未知键、新客户端拿到缺键都走同一支。
	_grace = data.get("grace", {})
	# ★★ **本函数的唯一一次刷新**(2026-09-29 删掉了函数尾那次重复调用)。
	#   原先首尾各刷一次,而尾那次的注释写着「本帧的权威值覆盖本地走秒的结果」—— 那句话**属于
	#   这一处**(赋值一完成就把权威值画上去;本地走秒发生在**两帧之间**的 `_process` 里,见上),
	#   尾那次只是**同参重刷**:`_grace` 的唯一写点就是上面这一行,`PvpSession.role` 在本函数里
	#   也没有第二个值,故两次调用的画面结果**逐字相同**(`_refresh_grace` 只写
	#   `_grace_wrap.visible` 与 `_grace_label.text`,函数体里没有任何读它们的地方)。
	#   ⇒ **别在函数尾再加一次**:它不改行为,只会让人以为"中间某处会改 `_grace`"。
	#   (若将来真在 `match state:` 的某个分支里改了 `_grace`,那时也**不**该在尾上补一笔 ——
	#    该在那个分支里自己刷,或者把赋值挪到分发**之前**。)
	_refresh_grace()
	var state: int = data.get("state", ST_PLAYING)
	var round: int = data.get("round", 1)
	var scores: Dictionary = data.get("scores", {})
	var rounds_won: Dictionary = data.get("rounds_won", {})
	var s1: int = int(scores.get(1, 0))
	var s2: int = int(scores.get(2, 0))
	var w1: int = int(rounds_won.get(1, 0))
	var w2: int = int(rounds_won.get(2, 0))
	# 段间只用留白分段。原先「击杀 5    -    局胜」里那个孤立的 "-" 与「局胜 1 - 0」的连字符
	# 同形,一段话里出现两种含义的短横(2026-09-13 视觉评析)。
	_score_label.text = "P1 击杀 %d        P2 击杀 %d        局胜 %d - %d        第 %d 局" % [
			s1, s2, w1, w2, round]
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
