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

	# ① 1v1:列 = K/D/造成/承受/ACS(spec §3.6;无助攻 —— 1v1 拿不到助攻,见 §3.4)
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
	# `rank` 是行契约的一部分(`_finish` 末尾填名次)—— 删掉那段循环,榜照画、只是名次恒 0
	if int(duel["sections"][0]["rows"][0]["rank"]) != 1:
		fails.append("★ 榜首 rank 应被填成 1(_finish 的名次循环),实得 %d"
				% int(duel["sections"][0]["rows"][0]["rank"]))

	# ② 1v1 平局:match_winner == 0 必须念「平 局」,不许走 1v1 兜底念成 P 某人获胜
	var draw: Dictionary = script.for_duel({ "stats": {
			1: {"kills": 2, "deaths": 1, "assists": 0, "dealt": 10, "taken": 10, "kscore": 200, "acs": 200},
			2: {"kills": 2, "deaths": 1, "assists": 0, "dealt": 10, "taken": 10, "kscore": 200, "acs": 200}},
			"match_winner": 0 }, names, 1)
	if str(draw["title"]) != "平 局":
		fails.append("★ 1v1 平局应念「平 局」,实得 %s" % draw["title"])

	# ②b ★★ 1v1:某 role **没有 `stats` 条目** = 本场 0 杀,**必须照样出行**(不是跳过)。
	#      `for_duel` 遍历的是写死的 `[1, 2]`,缺条目只可能是"整场 0 杀"——`stats` 是
	#      `role -> 七字段`(`server/match_round.gd`),没写进字典就是没拿到人头。
	#      ★ 写成 `if not stats.has(role): continue` 会在一局 5-0 时画出**只有一行**的榜:
	#        输的那位从**自己的**结算页上消失(他正是要看到自己那一行的人),全程不报错。
	#      ★ 这条与 ⑤(3v3 缺 `stats` 条目**就该跳过**)方向相反,**两条都要在**:
	#        无脑统一成一版,总有一个模式错。
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

	# ③ 大乱斗:kills/deaths/dealt/taken 四列,按 kills 降序(无 ACS —— 单局死斗 ⇒ acs ≡ kscore)
	# ★★ 标题恒为「游戏结束」——**与 `match_winner` 无关**(用户 2026-09-21 裁定:
	#    「大乱斗结算榜单不应该有任何胜利/失败,而是游戏结束」)。自由混战里 N 个人只有榜首
	#    算"赢",把其余 N-1 个人判成「失败」既不准确也没意义。原先这里断言的是「失败」。
	var roy: Dictionary = script.for_royale({ "stats": {
			1: {"kills": 3, "deaths": 5, "assists": 0, "dealt": 120, "taken": 300, "kscore": 3, "acs": 3},
			2: {"kills": 9, "deaths": 2, "assists": 0, "dealt": 400, "taken": 100, "kscore": 9, "acs": 9},
			3: {"kills": 0, "deaths": 4, "assists": 0, "dealt": 20, "taken": 200, "kscore": 0, "acs": 0}},
			"match_winner": 2 }, names, 1)
	if roy["columns"] != ["kills", "deaths", "dealt", "taken"]:
		fails.append("大乱斗 columns 应为 [kills,deaths,dealt,taken],实得 %s" % [roy["columns"]])
	# ★★ 先判空:新夹具不再带 `scores`,而"适配器还没改读 `stats`"或"夹具漏了 `stats`"时
	#    榜就是**空的** —— 那时 `rows[0]` **越界**,`_initialize()` 当场中断 ⇒ **不 `quit()`**
	#    ⇒ 进程**永久挂住、连一行 verdict 都没有**(`-s` 没有 `--quit-after` 兜底;★ 挂住与
	#    真失败在输出上**不可分**,都是"看不到 FAIL")。判空之后它变成一条**正常的红**。
	var rrows: Array = roy["sections"][0]["rows"]
	if rrows.is_empty():
		fails.append("★ 大乱斗榜为空(夹具缺 `stats` / 适配器还没改读 `stats`?)—— 不判空的话"
				+ " `rows[0]` 会越界,整支冒烟会**挂住**而不是失败(本仓判据:挂住与失败不可分)")
	elif int(rrows[0]["kills"]) != 9:
		fails.append("★ 大乱斗榜首应是 9 杀(降序排错)")
	if str(roy["title"]) != "游戏结束":
		fails.append("★ 大乱斗标题应是「游戏结束」,实得 %s" % roy["title"])

	# ③b ★ 上一条的**反向对照**:同一份 `stats`,只把 `match_winner` / `my_role` 换成
	#     "我赢"(两者相等),标题**必须一模一样**。
	#     ★ 为什么单开一条:③ 那一个 fixture 里 `my_role(1) != match_winner(2)` ——
	#       `"游戏结束" if match_winner != my_role else "胜利!"` 这类**仍然依赖胜负**的实现
	#       在 ③ 下**照样绿**,只有本条的"赢家视角"能把它照红。
	var roy_win: Dictionary = script.for_royale({ "stats": {
			1: {"kills": 3, "deaths": 5, "assists": 0, "dealt": 120, "taken": 300, "kscore": 3, "acs": 3},
			2: {"kills": 9, "deaths": 2, "assists": 0, "dealt": 400, "taken": 100, "kscore": 9, "acs": 9},
			3: {"kills": 0, "deaths": 4, "assists": 0, "dealt": 20, "taken": 200, "kscore": 0, "acs": 0}},
			"match_winner": 2 }, names, 2)
	if str(roy_win["title"]) != "游戏结束":
		fails.append("★ 大乱斗:即便 `my_role` 就是 `match_winner`(榜首),标题也必须是"
				+ "「游戏结束」而**不是**「胜利!」,实得 %s" % roy_win["title"])
	# 平局那一档同样不例外(`match_winner == 0` 时也**不许**冒出「平 局」)
	var roy_draw: Dictionary = script.for_royale({ "stats": {
			1: {"kills": 3, "deaths": 5, "assists": 0, "dealt": 120, "taken": 300, "kscore": 3, "acs": 3},
			2: {"kills": 9, "deaths": 2, "assists": 0, "dealt": 400, "taken": 100, "kscore": 9, "acs": 9},
			3: {"kills": 0, "deaths": 4, "assists": 0, "dealt": 20, "taken": 200, "kscore": 0, "acs": 0}},
			"match_winner": 0 }, names, 1)
	if str(roy_draw["title"]) != "游戏结束":
		fails.append("★ 大乱斗平局(`match_winner == 0`)也不许念「平 局」,实得 %s"
				% roy_draw["title"])

	# ④ 3v3:两节、列含助攻/dealt/acs、mvp 指向 ACS 最高者
	# ★ 2 队**两条** stats:只有一条时"排序前数行号"与"排序后数行号"都得到 `row 0` ——
	#   那条 mvp 断言会退化成空转(mvp 的行号必须落在**真会因排序移动**的那一行上)。
	#   这里 role 5 在 `stats` 的迭代次序里排在 role 4 **之后** ⇒ 排序前它在第 2 行;
	#   而它 ACS 400 全队最高 ⇒ 排完序升到第 1 行。于是"行号 == 0"只对**排完序再数**成立。
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

	# ④d ★★ 伤害列必须真读到**生产端现在发出的那个键**(`dealt`)。
	#     ★ 为什么非要有这条**值**断言:上面的夹具是**本冒烟自己喂的**,而消费端读不到的键
	#       (`s.get("dmg", 0)` 那种旧键)在**所有列名/计数/排序断言下照样全绿** —— 榜上
	#       伤害列恒 0,一个字都不报。e393f88 把生产端键从 `dmg` 改成 `dealt` 之后,
	#       这正是线上「3v3 结算页伤害全是 0」那个静默缺陷的形状:只改列名抓不住它。
	var t1rows: Array = team["sections"][0]["rows"]
	var t_dealt := -1
	if not t1rows.is_empty():
		t_dealt = int(t1rows[0]["dealt"])
	if t_dealt != 400:
		fails.append(("★ 3v3 伤害列必须读到生产端的 `dealt` 键(role 1 应 400),实得 %d —— "
				+ "读回旧键 `dmg` 时这里恒 0,而上面所有计数断言照样全绿") % t_dealt)

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

	# ⑦ ★ 载荷里**没有 `stats` 键**(老服务端 / 极端路径)⇒ 空榜、不崩。
	#   ★ 本适配器**不做**回退读 `scores`/`deaths`:那会让同一件事有两个来源(两份真相),
	#     而两端由同一份仓库/同一个 exe 一起更新 —— 加法的性质是"老**接收端**忽略未知键",
	#     不是"新接收端兼容老服务端"。
	var no_stats_duel: Dictionary = script.for_duel({ "match_winner": 1 }, names, 1)
	if (no_stats_duel["sections"][0]["rows"] as Array).size() != 2:
		fails.append("★ 缺 `stats` 时 1v1 仍应出两行(0 值),实得 %d 行"
				% (no_stats_duel["sections"][0]["rows"] as Array).size())
	var no_stats_roy: Dictionary = script.for_royale({ "match_winner": 1 }, names, 1)
	if (no_stats_roy["sections"][0]["rows"] as Array).size() != 0:
		fails.append("★ 缺 `stats` 时大乱斗应是空榜(不硬造行),实得 %d 行"
				% (no_stats_roy["sections"][0]["rows"] as Array).size())

	# ⑧ ★★ **每个列键都必须有标题**(`ui/match_result.gd` 的 `COLUMN_TITLES`)。
	#   表头走 `COLUMN_TITLES.get(col, col)` —— 漏一个键**不报错**,只是那一列的表头退化成
	#   **裸英文键名**(屏上打出 `dealt`),而所有列数/计数/值断言**照样全绿**。这正是
	#   `60860fd`(`dmg`→`dealt`)踩过的形状:改了列名却没同步标题表。
	#   ★ 键集**从三个常量推**,不写死清单 —— 写死的话,以后给 `C_DUEL` 加一列而忘了同步
	#     这里,这条守卫就**静默失明**(它守的正是"新增列必须有标题")。
	#   ★ 常量一律走 `get_script_constant_map()`(取不存在的属性会抛错 ⇒ `-s` 下挂到 timeout)。
	var rs = load("res://ui/match_result.gd")
	var scmap: Dictionary = script.get_script_constant_map()
	if rs == null:
		fails.append("★ 读不到 ui/match_result.gd(`COLUMN_TITLES` 覆盖断言无从成立)")
	else:
		var cmap: Dictionary = rs.get_script_constant_map()
		if not cmap.has("COLUMN_TITLES"):
			fails.append("★ ui/match_result.gd 里找不到 COLUMN_TITLES(改名了?本断言无从成立)")
		else:
			var titles: Dictionary = cmap["COLUMN_TITLES"]
			var cols: Array = []
			for cname in ["C_DUEL", "C_ROYALE", "C_TEAM"]:
				if not scmap.has(cname):
					fails.append("★ MatchResultPayload 里找不到 `%s`(列常量改名了?)" % cname)
					continue
				for col in (scmap[cname] as Array):
					if not cols.has(str(col)):
						cols.append(str(col))
			for col in cols:
				if not titles.has(col):
					fails.append(("★ 列 `%s` 在 COLUMN_TITLES 里没有标题 —— 表头会退化成裸键名"
							+ "(`.get(col, col)` 兜底,不报错),而所有列数/计数断言照样全绿") % col)

	if fails.is_empty():
		print("MATCH RESULT PAYLOAD: ALL-OK")
		quit(0)
	else:
		print("MATCH RESULT PAYLOAD: FAIL")
		for f in fails:
			print("  - %s" % f)
		quit(1)
