extends SceneTree

# 结算页**适配器**的纯逻辑冒烟(三个模式 -> 统一载荷)。
# 跑法: "$GODOT" --headless --path . -s res://tests/smoke/match_result_payload_smoke.gd
# 通过 = `MATCH RESULT PAYLOAD: ALL-OK` 退出 0。
#
# ═══ 为什么需要它 ═══
# ★ 三个适配器是**纯函数**,但它们的错法全是静默的:列多一列会画出一个恒 0 的列
#   (读起来像"这人打了但什么都没干");排序非确定会让同一局两次跑给出不同的榜;
#   平局走 1v1 兜底会把「平 局」念成「P1 获胜」。这些都不会报错。
# ★ 空载守卫:load 失败立刻 quit(1),否则抛错走不到 quit() -> 进程永久挂起。

func _initialize() -> void:
	var script = load("res://ui/screens/match_result_payload.gd")
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
	# ★★ 1v1 的 MVP 指向(本批唯一的新行为)。★ 本夹具里 MVP(role 1)恰好就是榜首 ⇒
	#   它只钉"`mvp` 整块不许为空/不指向别处";**"行号必须在排完序之后数"那半边**由 ①b 钉。
	if int(duel["mvp"].get("section", -1)) != 0 or int(duel["mvp"].get("row", -1)) != 0:
		fails.append("★ 1v1:mvp 应指向 {section:0, row:0}(role 1 即榜首),实得 %s"
				% [duel["mvp"]])
	# ①c ★★ 「造成 / 承受」两列的**值**必须各读各的键(`dealt` / `taken`)。
	#   ★ 为什么非要有**值**断言(与 ④d 那条 3v3 的同款理由,本批给 1v1 与大乱斗补齐):
	#     `_row(..., taken, dealt, ...)` 两个实参**对调**是**一行就编得过**的改动,而上面
	#     所有列名/列数/排序/rank 断言**照样全绿** —— 图上就是「造成」「承受」两列互换。
	#   ★ 两行都判、且两个数刻意取得不同:`dealt` 与 `taken` 被读成同一个键时也红。
	var d0: Dictionary = duel["sections"][0]["rows"][0]
	if int(d0["dealt"]) != 500 or int(d0["taken"]) != 200:
		fails.append(("★ 1v1:role 1 应 dealt=500 / taken=200(各读各的键),实得 dealt=%d / taken=%d"
				+ " —— 两列实参互换时这里红") % [int(d0["dealt"]), int(d0["taken"])])
	var d1: Dictionary = duel["sections"][0]["rows"][1]
	if int(d1["dealt"]) != 300 or int(d1["taken"]) != 400:
		fails.append("★ 1v1:role 2 应 dealt=300 / taken=400,实得 dealt=%d / taken=%d"
				% [int(d1["dealt"]), int(d1["taken"])])

	# ①d ★★ 「击杀 / 阵亡 / 助攻」三列的**值**也必须各读各的键(2026-09-26 终审 重要 2)。
	#   ★ 为什么非要有它:`for_duel` 的 `_row(...)` 里 `int(s.get("deaths",0))` 与
	#     `int(s.get("assists",0))` **对调**是**一行就编得过**的改动,而上面**所有**断言
	#     (列名/列数/排序/rank/mvp/①c 的 dealt-taken)**照样全绿** —— 1v1 结算页的「阵亡」
	#     列会整列显示成助攻数。★ 三种写法都落在这条上:对调、两列都读 `deaths`、两列都读
	#     `assists`(夹具里 assists 恒 0 —— 1v1 拿不到助攻,故 `deaths` 那一列必然错)。
	#   ★ 两行都判、且 kills 一起判(三列同一个调用点,漏一个就是一行改动)。
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

	# ①b ★★ 1v1:mvp **行号必须在排完序之后数**(本批唯一的新行为,此前**零断言**:
	#     退回 `"mvp": {}`、或把数行号那段挪到 `_finish()` 之前,两支冒烟都会照旧全绿)。
	#     ★ 夹具刻意让 **MVP 不是榜首**:role 2 的 9 杀排到第 1 行,而它在 `for_duel`
	#       写死的遍历次序 `[1, 2]` 里本来在第 2 行 ⇒ 只有"排完序再数"才给得出 `row 0`;
	#       挪到排序之前 ⇒ `row 1` ⇒ 这里红。
	#     ★ 另一半:`mvp` 整块退回 `{}`(`for_royale` 那个形状)**也**落到这条上。
	var duel_mvp: Dictionary = script.for_duel({ "stats": {
			1: {"kills": 3, "deaths": 4, "assists": 0, "dealt": 100, "taken": 250, "kscore": 300, "acs": 100},
			2: {"kills": 9, "deaths": 1, "assists": 0, "dealt": 450, "taken": 120, "kscore": 900, "acs": 450}},
			"rounds_won": {1: 0, 2: 2}, "mvp": 2, "match_winner": 2 }, names, 1)
	if int(duel_mvp["mvp"].get("section", -1)) != 0 or int(duel_mvp["mvp"].get("row", -1)) != 0:
		fails.append(("★ 1v1 的 mvp 行号必须在**排完序之后**数:role 2(9 杀)应落到第 1 行"
				+ " = {section:0, row:0},实得 %s —— `\"mvp\": {}`(整块退掉)与「排序前数」"
				+ "两种实现都会落到这里") % [duel_mvp["mvp"]])

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
	# ③c ★★ 大乱斗的「造成 / 承受」也必须各读各的键(与 ①c 同款理由,`for_royale` 一个函数
	#   一个改动点,故两处各判一次):榜首 role 2 的 dealt/taken 刻意取不等值(400 / 100)——
	#   两列实参对调、或两列都读同一个键时这里红,而列名/列数/排序/标题断言**一个都不会红**。
	if not rrows.is_empty():
		if int(rrows[0]["dealt"]) != 400 or int(rrows[0]["taken"]) != 100:
			fails.append(("★ 大乱斗榜首(role 2)应 dealt=400 / taken=100(各读各的键),"
					+ "实得 dealt=%d / taken=%d —— 两列实参互换时这里红")
					% [int(rrows[0]["dealt"]), int(rrows[0]["taken"])])
	if str(roy["title"]) != "游戏结束":
		fails.append("★ 大乱斗标题应是「游戏结束」,实得 %s" % roy["title"])
	# ③d ★ 大乱斗的「击杀 / 阵亡」同款(与 ①d 同一条理由;`for_royale` 是**第三个**
	#   `_row(...)` 调用点,三个模式各判一次才是"整族都钉住")。榜首 role 2 的
	#   kills/deaths 刻意取不等值(9 / 2),assists 恒 0(大乱斗拿不到助攻)。
	if not rrows.is_empty():
		var r_bad: Array[String] = []
		if int(rrows[0]["kills"]) != 9 or int(rrows[0]["deaths"]) != 2 \
				or int(rrows[0]["assists"]) != 0:
			r_bad.append("role 2 应 kills=9 / deaths=2 / assists=0,实得 %d/%d/%d"
					% [int(rrows[0]["kills"]), int(rrows[0]["deaths"]), int(rrows[0]["assists"])])
		if not r_bad.is_empty():
			fails.append(("★ 大乱斗:榜首那行必须各读各的键(kills/deaths/assists):%s"
					+ " —— deaths↔assists 对调时这里红") % str(r_bad))

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

	# ④e ★★ 3v3 的「击杀 / 阵亡 / 助攻」三列**值**也要各读各的键(2026-09-26 终审 重要 2)。
	#   ★ 为什么必须有:这一条与 ④d 是**同一个调用点**的另一半 —— 只钉 `dealt` 时,
	#     `deaths` 与 `assists` 两个相邻 int 实参**对调**照样编译、冒烟全绿,而 3v3 结算页
	#     **每一行**的「助攻」「阵亡」两列整列互换(错的是屏上数字,没有任何断言会红)。
	#   ★ 两节都判:A 队两行的三列刻意取四个不同值(role 1 = 5/3/2、role 2 = 2/5/1),
	#     B 队同理(role 5 = 8/1/3、role 4 = 3/4/0)⇒ 任何错配都落在这三条上。
	#   ★ 行号依赖 `_finish` 的排序(主键降序 → 阵亡升序 → 昵称升序):A 队 role 1(acs 200)
	#     在 role 2(acs 66)之前、B 队 role 5(acs 400)在 role 4(acs 100)之前。
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
	# ★★ 夹具**带 `scores`**(局内 HUD 那个数据面,形状 = `role -> 击杀数` 的 int)、
	#    **不带 `stats`** —— 这正是"回退读 `scores`"那条实现会现形的形状:原夹具两样都没有,
	#    于是"整块不读"与"回退读 `scores`"给出**同一个**载荷,⑦ 的两个分支**都拦不住它**。
	#    ★ 1v1 的行是写死 `[1, 2]` 的 ⇒ 榜**永远不为空**,所以这里判的自变量是**值**
	#      (回退实现会把 `scores` 的 5/3 画上「击杀」列),不是行数。
	var no_stats_duel: Dictionary = script.for_duel({ "scores": {1: 5, 2: 3}, "deaths": {1: 1, 2: 2},
			"match_winner": 1 }, names, 1)
	var nsd: Array = no_stats_duel["sections"][0]["rows"]
	if nsd.size() != 2:
		fails.append("★ 缺 `stats` 时 1v1 仍应出两行(0 值),实得 %d 行" % nsd.size())
	else:
		for ri in nsd.size():
			var nr: Dictionary = nsd[ri]
			if int(nr["kills"]) != 0 or int(nr["dealt"]) != 0 or int(nr["acs"]) != 0:
				fails.append(("★ 缺 `stats` 时 1v1 的行必须**全是 0**(本适配器刻意**不回退**读 `scores`):"
						+ "第 %d 行实得 kills=%d / dealt=%d / acs=%d —— 回退读 `scores` 时这里会读到真实的击杀数")
						% [ri + 1, int(nr["kills"]), int(nr["dealt"]), int(nr["acs"])])
	# ⑦b ★ 大乱斗:同样**只**给 `scores`(没有 `stats`)⇒ 必须**空榜**。
	#    `for_royale` 遍历的是 `stats` 的键 ⇒ 回退读 `scores` 会凭空多出 N 行,而上面的
	#    列名/列数/标题断言**一个都不会红**(它们只看非空那一路)。
	var scores_only_roy: Dictionary = script.for_royale({ "scores": {1: 5, 2: 3}, "deaths": {1: 1, 2: 2},
			"match_winner": 1 }, names, 1)
	var sor: Array = scores_only_roy["sections"][0]["rows"]
	if sor.size() != 0:
		fails.append(("★ 只有 `scores`(无 `stats`)时大乱斗必须是空榜:回退读 `scores` 会画出 %d 行"
				+ "(本适配器不做回退 —— `scores` 是「本局击杀」,不是结算页要的整场口径)")
				% sor.size())
	# ⑦c ★ 3v3 同理:两节都必须为空(同一处改动的第三个落点,一句话的代价)。
	var scores_only_team: Dictionary = script.for_team({ "scores": {1: 5, 4: 3}, "match_winner": 1 },
			names, teams, 1)
	var sot0: Array = scores_only_team["sections"][0]["rows"]
	var sot1: Array = scores_only_team["sections"][1]["rows"]
	if sot0.size() != 0 or sot1.size() != 0:
		fails.append(("★ 只有 `scores`(无 `stats`)时 3v3 两节都必须为空,实得 A 队 %d 行 / B 队 %d 行"
				+ " —— 回退读 `scores` 时这里红") % [sot0.size(), sot1.size()])

	# ⑧ ★★ **每个列键都必须有标题**(`ui/match_result.gd` 的 `COLUMN_TITLES`)。
	#   表头走 `COLUMN_TITLES.get(col, col)` —— 漏一个键**不报错**,只是那一列的表头退化成
	#   **裸英文键名**(屏上打出 `dealt`),而所有列数/计数/值断言**照样全绿**。这正是
	#   `60860fd`(`dmg`→`dealt`)踩过的形状:改了列名却没同步标题表。
	#   ★ 键集**从三个常量推**,不写死清单 —— 写死的话,以后给 `C_DUEL` 加一列而忘了同步
	#     这里,这条守卫就**静默失明**(它守的正是"新增列必须有标题")。
	#   ★ 常量一律走 `get_script_constant_map()`(取不存在的属性会抛错 ⇒ `-s` 下挂到 timeout)。
	var rs = load("res://ui/screens/match_result.gd")
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
