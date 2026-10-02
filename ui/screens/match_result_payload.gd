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

# 各模式的列 —— **顺序就是显示顺序**,由 spec §3.6 定;"模式没有的列不进"是既有口径:
#   · 大乱斗无 ACS(单局死斗 ⇒ `acs ≡ kscore`,恒等列零信息)、无助攻(自由混战无归属);
#   · 1v1 无助攻(`same_team` 恒 false ⇒ 那模式拿不到助攻,见 spec §3.4)。
# ★ 新增列必须同时在 `ui/match_result.gd` 的 `COLUMN_TITLES` 里有标题,否则表头退化成
#   裸英文键名(`.get(col, col)` 兜底、不报错)—— `match_result_payload_smoke` 的 ⑧ 守着。
const C_DUEL := ["kills", "deaths", "dealt", "taken", "acs"]
const C_ROYALE := ["kills", "deaths", "dealt", "taken"]
const C_TEAM := ["kills", "deaths", "assists", "dealt", "taken", "acs"]


# 1v1。行数据一律读 `stats`(服务端算好的七字段),**不再读 `scores`** ——
# `scores` 是"本局击杀"(每局清零),它不是结算页要的整场口径。
# ★ 遍历仍写死 `[1, 2]`:1v1 只有这两个 role,**缺条目 = 0**(不是"没有这个人的数据")——
#   写成 `if not stats.has(role): continue` 会在一局 5-0 时画出**只有一行**的榜,
#   输的那位从**自己的**结算页上消失(他正是要看到自己那一行的人)。
# 列 = K/D/造成/承受/ACS(spec §3.6)。
# ★ MVP 的落点与 `for_team` 同一形状:`_row` 的第 8 个实参就是"这一行是不是 MVP",
#   排序之后再去找那个 `mvp == true` 的行 —— **别**想着"按 role 反查行"
#   (`_row` 只承载展示字段,没有 role 键;要靠 role 找行就得另开一个临时结构)。
static func for_duel(round: Dictionary, names: Dictionary, my_role: int) -> Dictionary:
	var stats: Dictionary = round.get("stats", {})
	var mvp_role: int = int(round.get("mvp", 0))
	var rows: Array = []
	for role in [1, 2]:
		var s: Dictionary = stats.get(role, {})
		rows.append(_row(_name_of(names, role), int(s.get("kills", 0)), int(s.get("deaths", 0)),
				int(s.get("assists", 0)), int(s.get("dealt", 0)), int(s.get("taken", 0)),
				int(s.get("acs", 0)), int(role) == mvp_role))
	_finish(rows, "kills")
	# mvp 的行号必须在**排完序之后**数,否则高亮会落在错的那一行(与 `for_team` 同款)
	var mvp_pos := {}
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


# 大乱斗。自由混战:行数据读 `stats`(`scores`/`deaths` 那两条键**留给局内 HUD** ——
# `ui/royale_hud.gd` 的排行榜按它们显示实时比分,与本页是两回事)。
# 列 = K/D/造成/承受(spec §3.6):**无 ACS**(单局死斗 ⇒ `acs ≡ kscore`)、**无助攻**。
# ★★ 标题恒为「游戏结束」,**与 `match_winner` 无关**(用户 2026-09-21 裁定:
#    「大乱斗结算榜单不应该有任何胜利/失败,而是游戏结束」)。故**刻意不调 `_verdict`**。
# ★ `my_role` 仍是第 3 个形参(调用方 `royale_game._build_result_payload` 传 `PvpSession.role`,
#   签名不动 —— `kh_l6_probe` ⑯ 按位置钉着那个实参);本函数用不到它,但**不要**删。
static func for_royale(round: Dictionary, names: Dictionary, my_role: int) -> Dictionary:
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
					int(s.get("deaths", 0)), int(s.get("assists", 0)),
					int(s.get("dealt", 0)), int(s.get("taken", 0)),
					int(s.get("acs", 0)), int(role) == mvp_role))
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
		"columns": C_TEAM,
		"sections": sections,
		"mvp": pos,
	}


static func _row(nm: String, kills: int, deaths: int, assists: int, dealt: int, taken: int,
		acs: int, mvp: bool = false) -> Dictionary:
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
