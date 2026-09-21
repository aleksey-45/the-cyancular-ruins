extends SceneTree

# 结算页**适配器**的纯逻辑冒烟(三个模式 -> 统一载荷)。
# 跑法: "$GODOT" --headless --path . -s res://tests/match_result_payload_smoke.gd
# 通过 = `MATCH RESULT PAYLOAD: ALL-OK` 退出 0。
#
# ═══ 为什么需要它 ═══
# ★ 三个适配器是**纯函数**,但它们的错法全是静默的:列多一列会画出一个恒 0 的列
#   (读起来像"这人打了但什么都没干");排序非确定会让同一局两次跑给出不同的榜;
#   平局走 1v1 兜底会把「平 局」念成「P1 获胜」。这些都不会报错。
# ★ 空载守卫:load 失败立刻 quit(1),否则抛错走不到 quit() -> 进程永久挂起。

func _initialize() -> void:
	var script = load("res://ui/match_result_payload.gd")
	if script == null:
		print("MATCH RESULT PAYLOAD: FAIL(加载 match_result_payload.gd 失败)")
		quit(1)
		return
	var fails: Array[String] = []
	var names := {1: "阿甲", 2: "bob", 3: "阿丙", 4: "dave", 5: "阿戊", 6: "frank"}
	var teams := {1: 1, 2: 1, 3: 1, 4: 2, 5: 2, 6: 2}

	# ① 1v1:只有 kills 一列(服务端没有逐人阵亡) -> 不许出现 deaths 列
	var duel: Dictionary = script.for_duel({ "scores": {1: 7, 2: 3}, "rounds_won": {1: 2, 2: 1},
			"match_winner": 1 }, names, 1)
	if duel["columns"] != ["kills"]:
		fails.append("★ 1v1 的 columns 应恰为 [kills](服务端没有逐人阵亡),实得 %s" % [duel["columns"]])
	if str(duel["title"]) != "胜利!":
		fails.append("1v1 我赢了应念「胜利!」,实得 %s" % duel["title"])
	if int(duel["sections"][0]["rows"][0]["kills"]) != 7:
		fails.append("1v1 榜首应是 7 杀")
	# `rank` 是行契约的一部分(`_finish` 末尾填名次)—— 删掉那段循环,榜照画、只是名次恒 0
	if int(duel["sections"][0]["rows"][0]["rank"]) != 1:
		fails.append("★ 榜首 rank 应被填成 1(_finish 的名次循环),实得 %d"
				% int(duel["sections"][0]["rows"][0]["rank"]))

	# ② 1v1 平局:match_winner == 0 必须念「平 局」,不许走 1v1 兜底念成 P 某人获胜
	var draw: Dictionary = script.for_duel({ "scores": {1: 2, 2: 2}, "match_winner": 0 }, names, 1)
	if str(draw["title"]) != "平 局":
		fails.append("★ 1v1 平局应念「平 局」,实得 %s" % draw["title"])

	# ②b ★★ 1v1:某 role **没有 `scores` 条目** = 本局 0 杀,**必须照样出行**(不是跳过)。
	#      `for_duel` 遍历的是写死的 `[1, 2]`,缺条目只可能是"0 杀"——`_scores` 是
	#      `role -> 本局击杀`(`server/match_state.gd`),没写进字典就是没拿到人头。
	#      ★ 写成 `if not scores.has(role): continue` 会在一局 5-0 时画出**只有一行**的榜:
	#        输的那位从**自己的**结算页上消失(他正是要看到自己那一行的人),全程不报错。
	#      ★ 这条与 ⑤(3v3 缺 `stats` 条目**就该跳过**)方向相反,**两条都要在**:
	#        无脑统一成一版,总有一个模式错。
	var one_sided: Dictionary = script.for_duel({ "scores": {1: 5}, "rounds_won": {1: 2, 2: 0},
			"match_winner": 1 }, names, 2)
	if (one_sided["sections"][0]["rows"] as Array).size() != 2:
		fails.append("★ 1v1 缺 scores 条目的 role 必须仍出一行(0 杀),实得 %d 行"
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

	# ③ 大乱斗:kills + deaths 两列,按 kills 降序
	var roy: Dictionary = script.for_royale({ "scores": {1: 3, 2: 9, 3: 0},
			"deaths": {1: 5, 2: 2, 3: 4}, "match_winner": 2 }, names, 1)
	if roy["columns"] != ["kills", "deaths"]:
		fails.append("大乱斗 columns 应为 [kills,deaths],实得 %s" % [roy["columns"]])
	if int(roy["sections"][0]["rows"][0]["kills"]) != 9:
		fails.append("★ 大乱斗榜首应是 9 杀(降序排错)")
	if str(roy["title"]) != "失败":
		fails.append("大乱斗我没赢应念「失败」,实得 %s" % roy["title"])

	# ④ 3v3:两节、列含 dmg/acs、mvp 指向 ACS 最高者
	# ★ 2 队**两条** stats:只有一条时"排序前数行号"与"排序后数行号"都得到 `row 0` ——
	#   那条 mvp 断言会退化成空转(mvp 的行号必须落在**真会因排序移动**的那一行上)。
	#   这里 role 5 在 `stats` 的迭代次序里排在 role 4 **之后** ⇒ 排序前它在第 2 行;
	#   而它 ACS 400 全队最高 ⇒ 排完序升到第 1 行。于是"行号 == 0"只对**排完序再数**成立。
	var stats := {1: {"kills": 5, "deaths": 3, "dmg": 400, "kscore": 600, "acs": 200},
			2: {"kills": 2, "deaths": 5, "dmg": 150, "kscore": 200, "acs": 66},
			4: {"kills": 3, "deaths": 4, "dmg": 300, "kscore": 350, "acs": 100},
			5: {"kills": 8, "deaths": 1, "dmg": 900, "kscore": 1200, "acs": 400}}
	var team: Dictionary = script.for_team({ "stats": stats, "mvp": 5, "match_winner": 2 }, names, teams, 1)
	if team["columns"] != ["kills", "deaths", "dmg", "acs"]:
		fails.append("3v3 columns 应为 [kills,deaths,dmg,acs],实得 %s" % [team["columns"]])
	if (team["sections"] as Array).size() != 2:
		fails.append("★ 3v3 必须两节(按队分栏),实得 %d" % (team["sections"] as Array).size())
	if int(team["mvp"].get("section", -1)) != 1 or int(team["mvp"].get("row", -1)) != 0:
		fails.append("★ mvp 应指向第 2 节第 1 行(role 5 属 2 队、ACS 最高;排序前它在第 2 行),实得 %s" % [team["mvp"]])
	if str(team["title"]) != "失败":
		fails.append("3v3 我(1 队)输了应念「失败」,实得 %s" % team["title"])

	# ④b ★ 3v3 平局:match_winner == 0 必须念「平 局」—— 不许走 `ui/pvp_hud.gd` 那种兜底
	#     (`"P%d 获胜!" % …`) 把它念成「P 某人获胜」。这条**今天可达**:TeamHost.mark_disconnected
	#     在"两队都走光"时就写 0,`ui/team_hud.gd` 也真的渲染「平 局」。
	var team_draw: Dictionary = script.for_team({ "stats": stats, "mvp": 5, "match_winner": 0 },
			names, teams, 1)
	if str(team_draw["title"]) != "平 局":
		fails.append("★ 3v3 平局应念「平 局」,实得 %s" % team_draw["title"])

	# ④c ★ `my_team == 0`(队伍表还没到)必须念「失败」,不许谎报胜利。
	#     平局那一支优先于本分支 —— 由上面 ④b 钉住(它传的就是 my_team == 1)。
	var team_no_team: Dictionary = script.for_team({ "stats": stats, "mvp": 5, "match_winner": 1 },
			names, teams, 0)
	if str(team_no_team["title"]) != "失败":
		fails.append("★ my_team == 0(队伍表未到)应念「失败」,不许谎报胜利,实得 %s" % team_no_team["title"])

	# ⑤ ★ 某 role 没有 stats 条目 -> 跳过该行,不硬造 0
	var partial: Dictionary = script.for_team({ "stats": {1: stats[1]}, "mvp": 1,
			"match_winner": 1 }, names, teams, 1)
	if int((partial["sections"][1]["rows"] as Array).size()) != 0:
		fails.append("★ 没有 stats 条目的 role 不许硬造 0 行(2 队应 0 行)")

	# ⑥ 同一份输入连算两次,载荷必须逐字段相同。
	# ★ 它**不是**"排序确定性"的守卫:一个全序比较器(含昵称那一级 tiebreak)的纯静态排序
	#   **天生确定**,⑥ 照不到"序排错了"(那是 ③ 的活)。它能抓的只有**不纯** ——
	#   比较器读了会变的外部状态、或实现里藏了随机/时间。留它是为了这条反向性质。
	if str(script.for_team({ "stats": stats, "mvp": 5, "match_winner": 2 }, names, teams, 1)) \
			!= str(team):
		fails.append("★ 同一输入两次调用给出了不同的载荷(实现不纯,而非纯静态排序)")

	if fails.is_empty():
		print("MATCH RESULT PAYLOAD: ALL-OK")
		quit(0)
	else:
		print("MATCH RESULT PAYLOAD: FAIL")
		for f in fails:
			print("  - %s" % f)
		quit(1)
