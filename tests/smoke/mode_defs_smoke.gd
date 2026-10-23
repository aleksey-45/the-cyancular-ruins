extends SceneTree

# ModeDefs 守卫:三模式常量 / 角色上界 / 选项键 / 结算列的**单一来源**。
# 通过 = MODE DEFS OK(n 条断言);判据 grep 文本。
# ★ 去掉什么才会红:
#   ① 三个 ID 改字面量(与 PvpSession.MODE_* 不一致)⇒ ① 红;
#   ② 把 3v3 的禁用武器加回 OPTION_KEYS ⇒ ② 红(这正是 X5 的回归);
#   ③ 结算列加/删一项 ⇒ ③ 红。
# ⚠ -s 脚本套外层 timeout。

const EXPECTED_CHECKS := 8

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	# ① ID 与 PvpSession 的三个字面量一致(本文件不引 autoload,故在这里钉字面量)
	_chk(ModeDefs.MODE_IDS == ["pvp", "royale", "team"], "MODE_IDS 必须恰为 [pvp, royale, team]")
	_chk(ModeDefs.MODE_PVP == "pvp" and ModeDefs.MODE_ROYALE == "royale" and ModeDefs.MODE_TEAM == "team",
			"MODE_* 三个常量必须与 PvpSession.MODE_* 逐字一致")

	# ② 角色上界 / 队伍尺寸(16 人上限与 X1 同源)
	_chk(ModeDefs.ROLE_MAX == 16 and ModeDefs.TEAM_SIZE == 3 and ModeDefs.TEAM_COUNT == 2,
			"ROLE_MAX/TEAM_SIZE/TEAM_COUNT 必须是 16/3/2")

	# ③ 选项键:三个模式各自"真的有这一项"的键
	_chk(ModeDefs.option_keys(ModeDefs.MODE_PVP) == ["hue", "round_full_heal", "disabled_weapons", "map"],
			"1v1 选项键应含回合回血/禁用武器,不含 match_time")
	_chk(ModeDefs.option_keys(ModeDefs.MODE_ROYALE) == ["hue", "disabled_weapons", "match_time", "map"],
			"大乱斗选项键应含禁用武器/match_time,不含回合回血")
	_chk(ModeDefs.option_keys(ModeDefs.MODE_TEAM) == ["hue", "map"],
			"3v3 选项键只应有 hue/map(禁用武器/回合回血是 X5 的泄漏源)")

	# ④ 结算列集(三模式三种组合,modes.md 登记为有意差异)
	_chk(ModeDefs.result_columns(ModeDefs.MODE_PVP) == ["kills", "deaths", "dealt", "taken", "acs"]
			and ModeDefs.result_columns(ModeDefs.MODE_ROYALE) == ["kills", "deaths", "dealt", "taken"]
			and ModeDefs.result_columns(ModeDefs.MODE_TEAM) == ["kills", "deaths", "assists", "dealt", "taken", "acs"],
			"三模式结算列集必须分别为 [k,d,dealt,taken,acs] / [k,d,dealt,taken] / [k,d,assists,dealt,taken,acs]")

	# ⑤ 未知模式:is_mode 假、表为空、label 空(不静默当 1v1)
	_chk(not ModeDefs.is_mode("") and not ModeDefs.is_mode("duel")
			and ModeDefs.option_keys("duel").is_empty() and ModeDefs.result_columns("duel").is_empty()
			and ModeDefs.label("duel") == "", "未知模式必须 is_mode=false、表为空、label 为空")

	if _checks < EXPECTED_CHECKS:
		_fails.append("断言条数不足(%d/%d)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("MODE DEFS OK(%d 条断言)" % _checks)
	else:
		for f in _fails:
			print("  FAIL %s" % f)
		print("MODE DEFS FAIL(%d/%d)" % [_fails.size(), _checks])
	quit(0)
