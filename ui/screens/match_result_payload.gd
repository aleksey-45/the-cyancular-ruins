class_name MatchResultPayload
extends RefCounted

# 结算页的适配器:把三个模式各自的 round_state 形状,折成 MatchResult 认的那一个载荷。

# ── 类型化字典试点(2026-11-02,`Dictionary[String, Variant]`)──
const C_DUEL := ["kills", "deaths", "dealt", "taken", "acs"]
const C_ROYALE := ["kills", "deaths", "dealt", "taken"]
const C_TEAM := ["kills", "deaths", "assists", "dealt", "taken", "acs"]


# 1v1。行数据一律读 stats(服务端算好的七字段),不再读 scores —— scores 是"本局击杀"(每局清零),不是结算页要的整场口径。
# ★ 遍历仍写死 [1, 2]:缺条目 = 0(不是"没有这个人的数据")—— 写成 if not stats.has(role): continue 会在一局 5-0 时画出只有一行的榜,输的那位从自己的结算页上消失。
static func for_duel(round: Dictionary, names: Dictionary, my_role: int) -> Dictionary[String, Variant]:
	var stats: Dictionary = round.get("stats", {})
	var mvp_role: int = int(round.get("mvp", 0))
	var rows: Array = []
	for role in [1, 2]:
		var s: Dictionary = stats.get(role, {})
		rows.append(_row(_name_of(names, role), int(s.get("kills", 0)), int(s.get("deaths", 0)),
				int(s.get("assists", 0)), int(s.get("dealt", 0)), int(s.get("taken", 0)),
				int(s.get("acs", 0)), int(role) == mvp_role))
	_finish(rows, "kills")
	var mvp_pos: Dictionary[String, int] = {}
	for ri in rows.size():
		if bool(rows[ri]["mvp"]):
			mvp_pos = {"section": 0, "row": ri}
	var won: Dictionary = round.get("rounds_won", {})
	return {
		"title": _verdict(int(round.get("match_winner", 0)), my_role),
		"subtitle": "局胜 %d - %d" % [int(won.get(1, 0)), int(won.get(2, 0))],
		"columns": C_DUEL,
		"sections": [{"label": "对局", "color": UiFactory.C_TEXT, "rows": rows}],
		"mvp": mvp_pos,
	}


# 大乱斗。自由混战:行数据读 stats(scores / deaths 那两条键留给局内 HUD —— ui/royale_hud.gd 的排行榜按它们显示实时比分,与本页是两回事)。
# ★★ 标题恒为「游戏结束」,与 match_winner 无关(用户裁定:「大乱斗结算榜单不应该有任何胜利/失败,而是游戏结束」)⇒ 刻意不调 _verdict。
# ★ my_role 仍是第 3 个形参(调用方传 PvpSession.role,签名不动):本函数用不到它,但不要删。零守卫(kh_l6_probe 已删·2026-10-09)。
static func for_royale(round: Dictionary, names: Dictionary, my_role: int) -> Dictionary[String, Variant]:
	var stats: Dictionary = round.get("stats", {})
	var rows: Array = []
	for role in stats:
		var s: Dictionary = stats[role]
		rows.append(_row(_name_of(names, int(role)), int(s.get("kills", 0)),
				int(s.get("deaths", 0)), int(s.get("assists", 0)),
				int(s.get("dealt", 0)), int(s.get("taken", 0)), int(s.get("acs", 0))))
	_finish(rows, "kills")
	return {
		"title": "游戏结束",
		"subtitle": "",
		"columns": C_ROYALE,
		"sections": [{"label": "击杀排行榜", "color": UiFactory.C_TEXT, "rows": rows}],
		"mvp": {},
	}


# 3v3。两节(A/B 队),栏内按 ACS 排;mvp 指向**胜队内** ACS 最高者(2026-10-30 用户裁定:全场最佳必须出自胜方,
# 服务端 `mvp_role(candidates)` 已按胜队过滤;本文件只按 role 打星,不自己再筛)。★ stats 按 role、names 也按 role ⇒ 直接可拼。★ 某 role 没有 stats 条目(掉线 / 中途加入)⇒ 跳过该行,不硬造 0。
static func for_team(round: Dictionary, names: Dictionary, teams: Dictionary, my_team: int) -> Dictionary[String, Variant]:
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
					int(s.get("deaths", 0)), int(s.get("assists", 0)),
					int(s.get("dealt", 0)), int(s.get("taken", 0)),
					int(s.get("acs", 0)), int(role) == mvp_role))
		_finish(rows, "acs")
		sections.append({
			"label": "A 队" if t == 1 else "B 队",
			"color": UiFactory.C_TEAM_A if t == 1 else UiFactory.C_TEAM_B,
			"rows": rows,
		})
	var pos: Dictionary[String, int] = {}
	for si in sections.size():
		var rows: Array = sections[si]["rows"]
		for ri in rows.size():
			if bool(rows[ri]["mvp"]):
				pos = {"section": si, "row": ri}
	var won: Dictionary = round.get("rounds_won", {})
	return {
		"title": _verdict_team(int(round.get("match_winner", 0)), my_team),
		"subtitle": "局胜 %d - %d" % [int(won.get(1, 0)), int(won.get(2, 0))],
		"columns": C_TEAM,
		"sections": sections,
		"mvp": pos,
	}


static func _row(nm: String, kills: int, deaths: int, assists: int, dealt: int, taken: int,
		acs: int, mvp: bool = false) -> Dictionary[String, Variant]:
	return {"rank": 0, "name": nm, "kills": kills, "deaths": deaths, "assists": assists,
			"dealt": dealt, "taken": taken, "acs": acs, "mvp": mvp}


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


# 1v1 的 match_winner 是 role 号,0 = 平局(两人局胜相同)。★ 本函数只服务 1v1(for_duel):大乱斗的标题走 for_royale 里那句恒定的「游戏结束」。
static func _verdict(match_winner: int, my_role: int) -> String:
	if match_winner == 0:
		return "平 局"
	return "胜利!" if match_winner == my_role else "失败"


# 3v3 的 `match_winner` 是 队号。0 = 平局(两队都走光 —— 见 TeamHost 的走光即弃权)。
static func _verdict_team(match_winner: int, my_team: int) -> String:
	if match_winner == 0:
		return "平 局"
	if my_team == 0:
		return "失败"     # 队伍表还没到(倒计时窗口) —— 不谎报胜利
	return "胜利!" if match_winner == my_team else "失败"
