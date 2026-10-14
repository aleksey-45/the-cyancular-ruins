extends SceneTree

# 对局结算载荷与统计数据冒烟测试：
# 验证结算面板数据载荷结构、击杀/阵亡/伤害统计汇总、MVP 评定算法以及数据序列化往返。
# 运行方式：
#   "$GODOT" --headless --path . -s res://tests/smoke/match_result_payload_smoke.gd

func _initialize() -> void:
	var script = load("res://ui/screens/match_result_payload.gd")
	if script == null:
		print("MATCH RESULT PAYLOAD: FAIL(加载 match_result_payload.gd 失败)")
		quit(1)
		return
	var fails: Array[String] = []
	var names := {1: "阿甲", 2: "bob", 3: "阿丙", 4: "dave", 5: "阿戊", 6: "frank"}
	var teams := {1: 1, 2: 1, 3: 1, 4: 2, 5: 2, 6: 2}

	var duel: Dictionary = script.for_duel({ "stats": {
			1: {"kills": 7, "deaths": 2, "assists": 0, "dealt": 500, "taken": 200, "kscore": 800, "acs": 400},
			2: {"kills": 3, "deaths": 5, "assists": 0, "dealt": 300, "taken": 400, "kscore": 250, "acs": 125}},
			"rounds_won": {1: 2, 2: 1}, "mvp": 1, "match_winner": 1 }, names, 1)
	if duel["columns"] != ["kills", "deaths", "dealt", "taken", "acs"]:
		fails.append("★ 1v1 的 columns 应为 [kills, deaths, dealt, taken, acs],实得 %s" % [duel["columns"]])
	if str(duel["title"]) != "胜利!":
		fails.append("1v1 我赢了应念「胜利!」,实得 %s" % duel["title"])
	if int(duel["sections"][0]["rows"][0]["kills"]) != 7:
		fails.append("1v1 榜首应是 7 杀")
	# rank 为名次字段，由 _finish 排序后填充
	if int(duel["sections"][0]["rows"][0]["rank"]) != 1:
		fails.append("★ 榜首 rank 应被填成 1(_finish 的名次循环),实得 %d"
				% int(duel["sections"][0]["rows"][0]["rank"]))
	if int(duel["mvp"].get("section", -1)) != 0 or int(duel["mvp"].get("row", -1)) != 0:
		fails.append("★ 1v1:mvp 应指向 {section:0, row:0}(role 1 即榜首),实得 %s"
				% [duel["mvp"]])
	var d0: Dictionary = duel["sections"][0]["rows"][0]
	if int(d0["dealt"]) != 500 or int(d0["taken"]) != 200:
		fails.append(("★ 1v1:role 1 应 dealt=500 / taken=200(各读各的键),实得 dealt=%d / taken=%d"
				+ " —— 两列实参互换时这里红") % [int(d0["dealt"]), int(d0["taken"])])
	var d1: Dictionary = duel["sections"][0]["rows"][1]
	if int(d1["dealt"]) != 300 or int(d1["taken"]) != 400:
		fails.append("★ 1v1:role 2 应 dealt=300 / taken=400,实得 dealt=%d / taken=%d"
				% [int(d1["dealt"]), int(d1["taken"])])

	var d_bad: Array[String] = []
	if int(d0["kills"]) != 7 or int(d0["deaths"]) != 2 or int(d0["assists"]) != 0:
		d_bad.append("role 1 应 kills=7 / deaths=2 / assists=0,实得 %d/%d/%d"
				% [int(d0["kills"]), int(d0["deaths"]), int(d0["assists"])])
	if int(d1["kills"]) != 3 or int(d1["deaths"]) != 5 or int(d1["assists"]) != 0:
		d_bad.append("role 2 应 kills=3 / deaths=5 / assists=0,实得 %d/%d/%d"
				% [int(d1["kills"]), int(d1["deaths"]), int(d1["assists"])])
	if not d_bad.is_empty():
		fails.append(("★ 1v1:「击杀 / 阵亡 / 助攻」三列必须各读各的键(kills/deaths/assists):%s"
				+ " —— deaths↔assists 对调、或两列读同一个键时这里红,而其它断言全绿") % str(d_bad))

	var duel_mvp: Dictionary = script.for_duel({ "stats": {
			1: {"kills": 3, "deaths": 4, "assists": 0, "dealt": 100, "taken": 250, "kscore": 300, "acs": 100},
			2: {"kills": 9, "deaths": 1, "assists": 0, "dealt": 450, "taken": 120, "kscore": 900, "acs": 450}},
			"rounds_won": {1: 0, 2: 2}, "mvp": 2, "match_winner": 2 }, names, 1)
	if int(duel_mvp["mvp"].get("section", -1)) != 0 or int(duel_mvp["mvp"].get("row", -1)) != 0:
		fails.append(("1v1 的 mvp 行号必须在排序之后计算: role 2(9 杀)应落到第 1 行"
				+ " = {section:0, row:0}, 实得 %s") % [duel_mvp["mvp"]])

	# ② 1v1 平局:match_winner == 0 必须念「平 局」,不许走 1v1 兜底保护念成 P 某人获胜
	var draw: Dictionary = script.for_duel({ "stats": {
			1: {"kills": 2, "deaths": 1, "assists": 0, "dealt": 10, "taken": 10, "kscore": 200, "acs": 200},
			2: {"kills": 2, "deaths": 1, "assists": 0, "dealt": 10, "taken": 10, "kscore": 200, "acs": 200}},
			"match_winner": 0 }, names, 1)
	if str(draw["title"]) != "平 局":
		fails.append("★ 1v1 平局应念「平 局」,实得 %s" % draw["title"])

	# 1v1 模式中，若某 role 缺少 stats 条目（0 杀），依然需要生成对应行并以 0 填充
	var one_sided: Dictionary = script.for_duel({ "stats": {
			1: {"kills": 5, "deaths": 0, "assists": 0, "dealt": 100, "taken": 0, "kscore": 500, "acs": 500}},
			"rounds_won": {1: 2, 2: 0}, "match_winner": 1 }, names, 2)
	if (one_sided["sections"][0]["rows"] as Array).size() != 2:
		fails.append("★ 1v1 缺 stats 条目的 role 必须仍出一行(0 杀),实得 %d 行"
				% (one_sided["sections"][0]["rows"] as Array).size())
	else:
		var loser: Dictionary = one_sided["sections"][0]["rows"][1]
		if int(loser["kills"]) != 0:
			fails.append("★ 缺条目的 role 那一行应是 0 杀,实得 %d" % int(loser["kills"]))
		if str(loser["name"]) != "bob":
			fails.append("★ 缺条目的 role 那一行应仍是 role 2 的昵称,实得 %s" % loser["name"])
		# 输的那位(role 2,看自己的结算页)必须看到「失败」,不是别人赢的文案
		if str(one_sided["title"]) != "失败":
			fails.append("★ role 2 看自己输掉的 1v1 应念「失败」,实得 %s" % one_sided["title"])

	var roy: Dictionary = script.for_royale({ "stats": {
			1: {"kills": 3, "deaths": 5, "assists": 0, "dealt": 120, "taken": 300, "kscore": 3, "acs": 3},
			2: {"kills": 9, "deaths": 2, "assists": 0, "dealt": 400, "taken": 100, "kscore": 9, "acs": 9},
			3: {"kills": 0, "deaths": 4, "assists": 0, "dealt": 20, "taken": 200, "kscore": 0, "acs": 0}},
			"match_winner": 2 }, names, 1)
	if roy["columns"] != ["kills", "deaths", "dealt", "taken"]:
		fails.append("大乱斗 columns 应为 [kills,deaths,dealt,taken],实得 %s" % [roy["columns"]])
	# 判空保护：缺少 stats 时避免 rows[0] 越界导致测试异常终止
	var rrows: Array = roy["sections"][0]["rows"]
	if rrows.is_empty():
		fails.append("大乱斗结算数据为空（缺少 stats 条目）")
	elif int(rrows[0]["kills"]) != 9:
		fails.append("★ 大乱斗榜首应是 9 杀(降序排错)")
	# 大乱斗造成与承受伤害字段校验：榜首 role 2 的 dealt 与 taken 需正确映射
	if not rrows.is_empty():
		if int(rrows[0]["dealt"]) != 400 or int(rrows[0]["taken"]) != 100:
			fails.append(("★ 大乱斗榜首(role 2)应 dealt=400 / taken=100(各读各的键),"
					+ "实得 dealt=%d / taken=%d —— 两列实参互换时这里红")
					% [int(rrows[0]["dealt"]), int(rrows[0]["taken"])])
	if str(roy["title"]) != "游戏结束":
		fails.append("★ 大乱斗标题应是「游戏结束」,实得 %s" % roy["title"])
	# 大乱斗击杀与阵亡字段校验
	if not rrows.is_empty():
		var r_bad: Array[String] = []
		if int(rrows[0]["kills"]) != 9 or int(rrows[0]["deaths"]) != 2 \
				or int(rrows[0]["assists"]) != 0:
			r_bad.append("role 2 应 kills=9 / deaths=2 / assists=0,实得 %d/%d/%d"
					% [int(rrows[0]["kills"]), int(rrows[0]["deaths"]), int(rrows[0]["assists"])])
		if not r_bad.is_empty():
			fails.append(("★ 大乱斗:榜首那行必须各读各的键(kills/deaths/assists):%s"
					+ " —— deaths↔assists 对调时这里红") % str(r_bad))

	# 大乱斗标题校验：获胜视角依然显示「游戏结束」
	var roy_win: Dictionary = script.for_royale({ "stats": {
			1: {"kills": 3, "deaths": 5, "assists": 0, "dealt": 120, "taken": 300, "kscore": 3, "acs": 3},
			2: {"kills": 9, "deaths": 2, "assists": 0, "dealt": 400, "taken": 100, "kscore": 9, "acs": 9},
			3: {"kills": 0, "deaths": 4, "assists": 0, "dealt": 20, "taken": 200, "kscore": 0, "acs": 0}},
			"match_winner": 2 }, names, 2)
	if str(roy_win["title"]) != "游戏结束":
		fails.append("大乱斗标题应为「游戏结束」，实得 %s" % roy_win["title"])
	# 大乱斗平局情况校验
	var roy_draw: Dictionary = script.for_royale({ "stats": {
			1: {"kills": 3, "deaths": 5, "assists": 0, "dealt": 120, "taken": 300, "kscore": 3, "acs": 3},
			2: {"kills": 9, "deaths": 2, "assists": 0, "dealt": 400, "taken": 100, "kscore": 9, "acs": 9},
			3: {"kills": 0, "deaths": 4, "assists": 0, "dealt": 20, "taken": 200, "kscore": 0, "acs": 0}},
			"match_winner": 0 }, names, 1)
	if str(roy_draw["title"]) != "游戏结束":
		fails.append("大乱斗平局标题应为「游戏结束」，实得 %s"
				% roy_draw["title"])

	# 3v3 队伍结算：按 ACS 降序排序后，MVP 指向排在首位的角色
	var stats := {1: {"kills": 5, "deaths": 3, "assists": 2, "dealt": 400, "taken": 250, "kscore": 600, "acs": 200},
			2: {"kills": 2, "deaths": 5, "assists": 1, "dealt": 150, "taken": 400, "kscore": 200, "acs": 66},
			4: {"kills": 3, "deaths": 4, "assists": 0, "dealt": 300, "taken": 200, "kscore": 350, "acs": 100},
			5: {"kills": 8, "deaths": 1, "assists": 3, "dealt": 900, "taken": 150, "kscore": 1200, "acs": 400}}
	var team: Dictionary = script.for_team({ "stats": stats, "mvp": 5, "match_winner": 2 }, names, teams, 1)
	if team["columns"] != ["kills", "deaths", "assists", "dealt", "taken", "acs"]:
		fails.append("3v3 columns 应为 [kills,deaths,assists,dealt,taken,acs],实得 %s" % [team["columns"]])
	if (team["sections"] as Array).size() != 2:
		fails.append("★ 3v3 必须两节(按队分栏),实得 %d" % (team["sections"] as Array).size())
	if int(team["mvp"].get("section", -1)) != 1 or int(team["mvp"].get("row", -1)) != 0:
		fails.append("★ mvp 应指向第 2 节第 1 行(role 5 属 2 队、ACS 最高;排序前它在第 2 行),实得 %s" % [team["mvp"]])
	if str(team["title"]) != "失败":
		fails.append("3v3 我(1 队)输了应念「失败」,实得 %s" % team["title"])

	var t1rows: Array = team["sections"][0]["rows"]
	var t_dealt := -1
	if not t1rows.is_empty():
		t_dealt = int(t1rows[0]["dealt"])
	if t_dealt != 400:
		fails.append("3v3 伤害列必须读取 dealt 字段(role 1 应为 400), 实得 %d" % t_dealt)

	var t_bad: Array[String] = []
	var t_a0: Array = team["sections"][0]["rows"]
	var t_b0: Array = team["sections"][1]["rows"]
	if t_a0.size() != 2 or t_b0.size() != 2:
		t_bad.append("两节各应有 2 行,实得 A 队 %d 行 / B 队 %d 行" % [t_a0.size(), t_b0.size()])
	else:
		if int(t_a0[0]["kills"]) != 5 or int(t_a0[0]["deaths"]) != 3 or int(t_a0[0]["assists"]) != 2:
			t_bad.append("A 队 role 1 应 kills=5 / deaths=3 / assists=2,实得 %d/%d/%d"
					% [int(t_a0[0]["kills"]), int(t_a0[0]["deaths"]), int(t_a0[0]["assists"])])
		if int(t_a0[1]["kills"]) != 2 or int(t_a0[1]["deaths"]) != 5 or int(t_a0[1]["assists"]) != 1:
			t_bad.append("A 队 role 2 应 kills=2 / deaths=5 / assists=1,实得 %d/%d/%d"
					% [int(t_a0[1]["kills"]), int(t_a0[1]["deaths"]), int(t_a0[1]["assists"])])
		if int(t_b0[0]["kills"]) != 8 or int(t_b0[0]["deaths"]) != 1 or int(t_b0[0]["assists"]) != 3:
			t_bad.append("B 队 role 5 应 kills=8 / deaths=1 / assists=3,实得 %d/%d/%d"
					% [int(t_b0[0]["kills"]), int(t_b0[0]["deaths"]), int(t_b0[0]["assists"])])
		if int(t_b0[1]["kills"]) != 3 or int(t_b0[1]["deaths"]) != 4 or int(t_b0[1]["assists"]) != 0:
			t_bad.append("B 队 role 4 应 kills=3 / deaths=4 / assists=0,实得 %d/%d/%d"
					% [int(t_b0[1]["kills"]), int(t_b0[1]["deaths"]), int(t_b0[1]["assists"])])
	if not t_bad.is_empty():
		fails.append(("★ 3v3:「击杀 / 阵亡 / 助攻」三列必须各读各的键(kills/deaths/assists):%s"
				+ " —— deaths↔assists 对调时这里红,而 ④d 与所有计数断言照旧全绿") % str(t_bad))

	# ④b 3v3 平局：match_winner == 0 时标题显示「平 局」
	var team_draw: Dictionary = script.for_team({ "stats": stats, "mvp": 5, "match_winner": 0 },
			names, teams, 1)
	if str(team_draw["title"]) != "平 局":
		fails.append("3v3 平局应显示「平 局」, 实得 %s" % team_draw["title"])

	# ④c my_team == 0 时默认显示「失败」
	var team_no_team: Dictionary = script.for_team({ "stats": stats, "mvp": 5, "match_winner": 1 },
			names, teams, 0)
	if str(team_no_team["title"]) != "失败":
		fails.append("my_team == 0 应显示「失败」, 实得 %s" % team_no_team["title"])

	# ⑤ 某 role 没有 stats 条目时跳过该行，不伪造 0 数据
	var partial: Dictionary = script.for_team({ "stats": {1: stats[1]}, "mvp": 1,
			"match_winner": 1 }, names, teams, 1)
	if int((partial["sections"][1]["rows"] as Array).size()) != 0:
		fails.append("没有 stats 条目的 role 不应生成空行")

	# ⑥ 纯函数确定性：相同输入两次调用生成结果完全一致
	if str(script.for_team({ "stats": stats, "mvp": 5, "match_winner": 2 }, names, teams, 1)) \
			!= str(team):
		fails.append("同一输入两次调用给出了不同的载荷")

	# ⑦ 容错处理：缺少 stats 字段时安全生成空榜或默认全 0 行，不回退读取局内 scores
	var no_stats_duel: Dictionary = script.for_duel({ "scores": {1: 5, 2: 3}, "deaths": {1: 1, 2: 2},
			"match_winner": 1 }, names, 1)
	var nsd: Array = no_stats_duel["sections"][0]["rows"]
	if nsd.size() != 2:
		fails.append("缺少 stats 时 1v1 仍应出两行全 0 数据, 实得 %d 行" % nsd.size())
	else:
		for ri in nsd.size():
			var nr: Dictionary = nsd[ri]
			if int(nr["kills"]) != 0 or int(nr["dealt"]) != 0 or int(nr["acs"]) != 0:
				fails.append(("缺少 stats 时 1v1 行数据必须全为 0: 第 %d 行实得 kills=%d / dealt=%d / acs=%d")
						% [ri + 1, int(nr["kills"]), int(nr["dealt"]), int(nr["acs"])])
	# ⑦b 大乱斗缺少 stats 时输出空榜
	var scores_only_roy: Dictionary = script.for_royale({ "scores": {1: 5, 2: 3}, "deaths": {1: 1, 2: 2},
			"match_winner": 1 }, names, 1)
	var sor: Array = scores_only_roy["sections"][0]["rows"]
	if sor.size() != 0:
		fails.append(("缺少 stats 时大乱斗必须为空榜, 实得 %d 行") % sor.size())
	# ⑦c 3v3 缺少 stats 时两队数据均为空
	var scores_only_team: Dictionary = script.for_team({ "scores": {1: 5, 4: 3}, "match_winner": 1 },
			names, teams, 1)
	var sot0: Array = scores_only_team["sections"][0]["rows"]
	var sot1: Array = scores_only_team["sections"][1]["rows"]
	if sot0.size() != 0 or sot1.size() != 0:
		fails.append(("缺少 stats 时 3v3 两节都必须为空, 实得 A 队 %d 行 / B 队 %d 行")
				% [sot0.size(), sot1.size()])

	# ⑧ 校验所有列键在 ui/match_result.gd 的 COLUMN_TITLES 中均已配置中文标题
	var rs = load("res://ui/screens/match_result.gd")
	var scmap: Dictionary = script.get_script_constant_map()
	if rs == null:
		fails.append("无法加载 ui/match_result.gd 进行 COLUMN_TITLES 校验")
	else:
		var cmap: Dictionary = rs.get_script_constant_map()
		if not cmap.has("COLUMN_TITLES"):
			fails.append("ui/match_result.gd 里找不到 COLUMN_TITLES")
		else:
			var titles: Dictionary = cmap["COLUMN_TITLES"]
			var cols: Array = []
			for cname in ["C_DUEL", "C_ROYALE", "C_TEAM"]:
				if not scmap.has(cname):
					fails.append("MatchResultPayload 里找不到 %s" % cname)
					continue
				for col in (scmap[cname] as Array):
					if not cols.has(str(col)):
						cols.append(str(col))
			for col in cols:
				if not titles.has(col):
					fails.append("列 %s 在 COLUMN_TITLES 里没有对应标题" % col)

	if fails.is_empty():
		print("MATCH RESULT PAYLOAD: ALL-OK")
		quit(0)
	else:
		print("MATCH RESULT PAYLOAD: FAIL")
		for f in fails:
			print("  - %s" % f)
		quit(1)
