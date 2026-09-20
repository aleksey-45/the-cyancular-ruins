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

	# ② 1v1 平局:match_winner == 0 必须念「平 局」,不许走 1v1 兜底念成 P 某人获胜
	var draw: Dictionary = script.for_duel({ "scores": {1: 2, 2: 2}, "match_winner": 0 }, names, 1)
	if str(draw["title"]) != "平 局":
		fails.append("★ 1v1 平局应念「平 局」,实得 %s" % draw["title"])

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
	var stats := {1: {"kills": 5, "deaths": 3, "dmg": 400, "kscore": 600, "acs": 200},
			2: {"kills": 2, "deaths": 5, "dmg": 150, "kscore": 200, "acs": 66},
			4: {"kills": 8, "deaths": 1, "dmg": 900, "kscore": 1200, "acs": 400}}
	var team: Dictionary = script.for_team({ "stats": stats, "mvp": 4, "match_winner": 2 }, names, teams, 1)
	if team["columns"] != ["kills", "deaths", "dmg", "acs"]:
		fails.append("3v3 columns 应为 [kills,deaths,dmg,acs],实得 %s" % [team["columns"]])
	if (team["sections"] as Array).size() != 2:
		fails.append("★ 3v3 必须两节(按队分栏),实得 %d" % (team["sections"] as Array).size())
	if int(team["mvp"].get("section", -1)) != 1 or int(team["mvp"].get("row", -1)) != 0:
		fails.append("★ mvp 应指向第 2 节第 1 行(role 4 属 2 队且 ACS 最高),实得 %s" % [team["mvp"]])
	if str(team["title"]) != "失败":
		fails.append("3v3 我(1 队)输了应念「失败」,实得 %s" % team["title"])

	# ⑤ ★ 某 role 没有 stats 条目 -> 跳过该行,不硬造 0
	var partial: Dictionary = script.for_team({ "stats": {1: stats[1]}, "mvp": 1,
			"match_winner": 1 }, names, teams, 1)
	if int((partial["sections"][1]["rows"] as Array).size()) != 0:
		fails.append("★ 没有 stats 条目的 role 不许硬造 0 行(2 队应 0 行)")

	# ⑥ ★ 排序确定性:同一份输入连算两次,载荷必须逐字段相同
	if str(script.for_team({ "stats": stats, "mvp": 4, "match_winner": 2 }, names, teams, 1)) \
			!= str(team):
		fails.append("★ 同一输入两次调用给出了不同的榜(排序不确定)")

	if fails.is_empty():
		print("MATCH RESULT PAYLOAD: ALL-OK")
		quit(0)
	else:
		print("MATCH RESULT PAYLOAD: FAIL")
		for f in fails:
			print("  - %s" % f)
		quit(1)
