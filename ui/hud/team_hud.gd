class_name TeamHud
extends CanvasLayer

# 3v3 对局 HUD(CanvasLayer layer=130,与 PvpHud/RoyaleHud 同层)。布局沿用 pvp_hud.tscn(记分条/延迟;
# 中央广播走共享组件 ui/hud/broadcast.tscn),只改语义:记分与播报的键是"队号"、判胜负按"我方队伍",
# 都不是 role。本页是最小可用版式,联机 UI 重做那份会把它一起重做。

const ST_COUNTDOWN := 0
const ST_PLAYING := 1
const ST_ROUND_OVER := 2
const ST_MATCH_OVER := 3

@onready var _broadcast: Broadcast = $Broadcast
@onready var _score_label: Label = $ScoreWrap/ScoreLabel
@onready var _ping_label: Label = $PingWrap/PingLabel

var _my_team := 0   # 由外部(match_sync 到达后)写入:team_game 调 set_my_team()


func set_my_team(t: int) -> void:
	_my_team = t


func _ready() -> void:
	PixelFont.shared()
	Wire.local_round_state.connect(_on_round_state)
	Wire.ping_updated.connect(_on_ping)
	_broadcast.set_broadcast(true, "对战开始", "第 1 局")


# 外部(如断线通知)直接弹广播;倒计时由 Broadcast 自己续写(这里一并把它停掉)。
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
	# ★ 文案用"队"不用"P":键是队号(见 TeamHost._broadcast_round_state)。
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
				# ★ 下面那个 `9` 是字面量,权威在 `TeamHost.TEAM_KILLS_TO_WIN`(= 9);本 HUD 不能引 `TeamHost`
				#   (会把 MatchHost 整条链拖进客户端)⇒ 只能人工对齐,漏改不报错(零守卫)。也别改成 `%d` 去兜圈取常量。
				_broadcast.set_broadcast(true, "本局胜利!" if mine else "本局落败",
						("A 队" if winner == 1 else "B 队") + " 先到 9 杀")
			else:
				_broadcast.set_broadcast(true, "本局结束", "局胜 %d - %d" % [w1, w2])
		ST_MATCH_OVER:
			var mwinner: int = int(data.get("match_winner", 0))
			# ★ mwinner == 0 在 3v3 里是新可达值(两队都走光 ⇒ 平局),而 ui/pvp_hud.gd 对 0 用的是
			#   1v1 口径的兜底 "P%d 获胜!" % (1 if w1 > w2 else 2) ⇒ 照抄会把平局念成「P2 获胜」;
			#   正确样板是 ui/royale_hud.gd 的 mw == 0 ⇒ "平 局"。
			if mwinner == _my_team and _my_team != 0:
				_broadcast.set_broadcast(true, "胜利!", "你们赢下了整场对战")
			elif mwinner != 0:
				_broadcast.set_broadcast(true, "失败", "再接再厉…")
			else:
				_broadcast.set_broadcast(true, "平 局", "双方都离开了对局…")
