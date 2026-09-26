class_name MatchResultPayload
extends RefCounted

# 结算页的**适配器**:把三个模式各自的 round_state 形状,折成 MatchResult 认的那一个载荷。
#
# ★★ 为什么单独一个文件、而不是写在三个客户端里:
#   ① 它们是**纯函数**(入参全是字典/常量,不碰节点、不读 autoload)⇒ `-s` 冒烟直接钉;
#      写在 pvp_game / royale_game / team_game 里就得把整个游戏场景实例化才测得到;
#   ② 三个模式**共用**「列标题 / 没有的列不列 / 平局文案」这些口径 —— 抄三份必然漂。
# ★ 反过来,`ui/match_result.gd` **不知道任何模式规则**;模式差异全部收在本文件。
#
# ★★ 三条不改会静默出错的口径:
#   ① `columns` **由数据决定** —— 某模式没有的数不进 columns,而不是补一列恒 0
#      (恒 0 的列读起来像"这人打了但什么都没干",而事实是他根本没这项统计);
#   ② 排序必须**确定性** —— 同样的局两次跑要给出同一个榜(主键降序 → 阵亡升序 → 昵称升序);
#   ③ `match_winner == 0` 是**平局**。1v1 那条别照抄 `ui/pvp_hud.gd` 的兜底
#      (`"P%d 获胜!" % (1 if w1 > w2 else 2)`)—— 那会把平局念成「P1 获胜」。

const C_KILLS := ["kills"]


# 1v1。`scores` 是 role -> **击杀数**(局胜在 `rounds_won`);**没有逐人阵亡** ⇒ 只列 kills。
static func for_duel(round: Dictionary, names: Dictionary, my_role: int) -> Dictionary:
	var scores: Dictionary = round.get("scores", {})
	var rows: Array = []
	for role in [1, 2]:
		# ★ `scores` 是 role -> **本局击杀**,1v1 只有这两个 role ⇒ 缺条目 = **本局 0 杀**,
		#   不是"没有这个人的数据"(与 `for_team` 的 `stats` 那条**规则不同**,别照抄:
		#   那边缺条目真的是"掉线/中途加入" ⇒ 刻意跳过那一行)。
		#   ★ 写成 `if not scores.has(role): continue` 会在一局 5-0 时画出**只有一行**的
		#     1v1 榜 —— 输的那位从自己的结算页上**消失**,且不报错。
		rows.append(_row(_name_of(names, role), int(scores.get(role, 0)), 0, 0, 0))
	_finish(rows, "kills")
	var won: Dictionary = round.get("rounds_won", {})
	return {
		"title": _verdict(int(round.get("match_winner", 0)), my_role),
		"subtitle": "局胜 %d - %d" % [int(won.get(1, 0)), int(won.get(2, 0))],
		"columns": C_KILLS,
		"sections": [{"label": "对局", "color": UiFactory.C_TEXT, "rows": rows}],
		"mvp": {},
	}


# 大乱斗。自由混战:`scores` / `deaths` 都是 role -> 计数。**没有 dmg/acs** ⇒ 不列。
#
# ★★ 标题恒为「游戏结束」,**与 `match_winner` 无关**(用户 2026-09-21 裁定:
#    「大乱斗结算榜单不应该有任何胜利/失败,而是游戏结束」)。
#    大乱斗是自由混战:N 个人里只有榜首算"赢",把 N-1 个人判成「失败」既不准确也没意义
#    —— 榜本身就说明了名次。故**刻意不调 `_verdict`**:那个函数只服务 1v1(与 3v3 的
#    `_verdict_team`),它们的胜利/失败语义**一个字都没动**。
# ★ `my_role` 仍是本函数的第 3 个形参(调用方 `royale_game._build_result_payload` 传
#    `PvpSession.role`,签名不动 —— `kh_l6_probe` 的 ⑯ 按位置钉着那个实参);
#   本函数现在用不到它,但**不要**删:签名是三模式适配器的公共形状,删了要改调用点与探针。
static func for_royale(round: Dictionary, names: Dictionary, my_role: int) -> Dictionary:
	var scores: Dictionary = round.get("scores", {})
	var deaths: Dictionary = round.get("deaths", {})
	var rows: Array = []
	for role in scores:
		rows.append(_row(_name_of(names, int(role)), int(scores[role]), int(deaths.get(role, 0)), 0, 0))
	_finish(rows, "kills")
	return {
		"title": "游戏结束",
		"subtitle": "",
		"columns": ["kills", "deaths"],
		"sections": [{"label": "击杀排行榜", "color": UiFactory.C_TEXT, "rows": rows}],
		"mvp": {},
	}


# 3v3。两节(A/B 队),栏内按 ACS 排;`mvp` 指向 ACS 最高者。
# ★ `stats` 按 role、`names` 也按 role ⇒ 直接可拼。
# ★ 某 role 没有 stats 条目(掉线 / 中途加入)⇒ **跳过该行,不硬造 0**。
static func for_team(round: Dictionary, names: Dictionary, teams: Dictionary, my_team: int) -> Dictionary:
	var stats: Dictionary = round.get("stats", {})
	var mvp_role: int = int(round.get("mvp", 0))
	var sections: Array = []
	for t in [1, 2]:
		var rows: Array = []
		for role in stats:
			if int(teams.get(int(role), 0)) != t:
				continue
			var s: Dictionary = stats[role]
			rows.append(_row(_name_of(names, int(role)), int(s.get("kills", 0)),
					int(s.get("deaths", 0)), int(s.get("dealt", 0)), int(s.get("acs", 0)),
					int(role) == mvp_role))
		_finish(rows, "acs")
		sections.append({
			"label": "A 队" if t == 1 else "B 队",
			"color": UiFactory.C_TEAM_A if t == 1 else UiFactory.C_TEAM_B,
			"rows": rows,
		})
	# mvp 的行号必须在**排完序之后**数,否则高亮会落在错的那一行
	var pos := {}
	for si in sections.size():
		var rows: Array = sections[si]["rows"]
		for ri in rows.size():
			if bool(rows[ri]["mvp"]):
				pos = {"section": si, "row": ri}
	var won: Dictionary = round.get("rounds_won", {})
	return {
		"title": _verdict_team(int(round.get("match_winner", 0)), my_team),
		"subtitle": "局胜 %d - %d" % [int(won.get(1, 0)), int(won.get(2, 0))],
		"columns": ["kills", "deaths", "dealt", "acs"],
		"sections": sections,
		"mvp": pos,
	}


static func _row(nm: String, kills: int, deaths: int, dealt: int, acs: int, mvp: bool = false) -> Dictionary:
	return {"rank": 0, "name": nm, "kills": kills, "deaths": deaths,
			"dealt": dealt, "acs": acs, "mvp": mvp}


# 确定性排序 + 填名次:主键降序 → 阵亡升序 → 昵称升序。
static func _finish(rows: Array, key: String) -> void:
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a[key]) != int(b[key]):
			return int(a[key]) > int(b[key])
		if int(a["deaths"]) != int(b["deaths"]):
			return int(a["deaths"]) < int(b["deaths"])
		return str(a["name"]) < str(b["name"]))
	for i in rows.size():
		rows[i]["rank"] = i + 1


static func _name_of(names: Dictionary, role: int) -> String:
	return str(names.get(role, "玩家%d" % role))


# 1v1 的 `match_winner` 是 **role 号**。0 = 平局(两人局胜相同)。
# ★ 本函数**只服务 1v1**(`for_duel`):大乱斗的标题走 `for_royale` 里那句恒定的
#   「游戏结束」(自由混战没有"你输了"这个说法,见那处注释)。
static func _verdict(match_winner: int, my_role: int) -> String:
	if match_winner == 0:
		return "平 局"
	return "胜利!" if match_winner == my_role else "失败"


# 3v3 的 `match_winner` 是 **队号**。0 = 平局(两队都走光 —— 见 TeamHost 的走光即弃权)。
static func _verdict_team(match_winner: int, my_team: int) -> String:
	if match_winner == 0:
		return "平 局"
	if my_team == 0:
		return "失败"     # 队伍表还没到(倒计时窗口) —— 不谎报胜利
	return "胜利!" if match_winner == my_team else "失败"
