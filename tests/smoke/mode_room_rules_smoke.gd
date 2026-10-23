extends SceneTree

# ModeRoomRules 守卫:三模式房间规则表(人数/队伍/开始/降级/端口归还)。
# 通过 = MODE ROOM RULES OK(n 条断言);判据 grep 文本。
# ★ 去掉什么才会红:把 3v3 的 start_allowed 改成"到 6 人就开"⇒ ② 红;
#   把大乱斗的上限从 ROLE_MAX 改成 8(复刻 X1 那个洞)⇒ ① 红;
#   端口延迟写死错模式 ⇒ ③ 红。
# ⚠ -s 脚本套外层 timeout。

const EXPECTED_CHECKS := 8

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	# ① 人数上下限(上限单一来源:角色上界 / 两队满员)
	_chk(ModeRoomRules.min_players(ModeDefs.MODE_PVP) == 2
			and ModeRoomRules.max_players(ModeDefs.MODE_PVP) == 2
			and ModeRoomRules.min_players(ModeDefs.MODE_ROYALE) == 2
			and ModeRoomRules.max_players(ModeDefs.MODE_ROYALE) == ModeDefs.ROLE_MAX
			and ModeRoomRules.min_players(ModeDefs.MODE_TEAM) == 6
			and ModeRoomRules.max_players(ModeDefs.MODE_TEAM) == 6,
			"人数上下限:1v1 2/2、大乱斗 2/ROLE_MAX、3v3 6/6")

	# ② 开始判据:3v3 必须两队各 3 人(4v2 不许);大乱斗/1v1 到最低人数即可
	_chk(not ModeRoomRules.start_allowed(ModeDefs.MODE_TEAM, 6, {1: 4, 2: 2})
			and ModeRoomRules.start_allowed(ModeDefs.MODE_TEAM, 6, {1: 3, 2: 3})
			and ModeRoomRules.start_allowed(ModeDefs.MODE_ROYALE, 2, {})
			and not ModeRoomRules.start_allowed(ModeDefs.MODE_ROYALE, 1, {})
			and ModeRoomRules.start_allowed(ModeDefs.MODE_PVP, 2, {}),
			"开始判据:3v3 两队各 3;大乱斗/1v1 到最低人数")

	# ③ 端口归还延迟:1v1 120s、大乱斗/3v3 360s(与 WorkerLauncher 同源)
	_chk(ModeRoomRules.port_return_seconds(ModeDefs.MODE_PVP) == 120.0
			and ModeRoomRules.port_return_seconds(ModeDefs.MODE_ROYALE) == 360.0
			and ModeRoomRules.port_return_seconds(ModeDefs.MODE_TEAM) == 360.0,
			"端口归还:1v1 120、大乱斗/3v3 360(必须与 WorkerLauncher 常量同值)")

	# ④ 只有大乱斗允许降级开局
	_chk(ModeRoomRules.degraded_start_allowed(ModeDefs.MODE_ROYALE)
			and not ModeRoomRules.degraded_start_allowed(ModeDefs.MODE_TEAM)
			and not ModeRoomRules.degraded_start_allowed(ModeDefs.MODE_PVP),
			"降级开局只许大乱斗(3v3 满员才开是用户裁定)")

	# ⑤ 队伍语义
	_chk(ModeRoomRules.team_size(ModeDefs.MODE_TEAM) == 3
			and ModeRoomRules.team_size(ModeDefs.MODE_PVP) == 0
			and ModeRoomRules.team_size(ModeDefs.MODE_ROYALE) == 0
			and ModeRoomRules.needs_teams(ModeDefs.MODE_TEAM)
			and not ModeRoomRules.needs_teams(ModeDefs.MODE_ROYALE),
			"队伍语义:只有 3v3 有队(每队 3)")

	# ⑥ 对局中的房三模式都可见、名单都冻结(modes.md §对局中的房)
	_chk(ModeRoomRules.visible_in_match(ModeDefs.MODE_PVP)
			and ModeRoomRules.visible_in_match(ModeDefs.MODE_ROYALE)
			and ModeRoomRules.visible_in_match(ModeDefs.MODE_TEAM)
			and ModeRoomRules.freeze_roster(ModeDefs.MODE_PVP)
			and ModeRoomRules.freeze_roster(ModeDefs.MODE_ROYALE)
			and ModeRoomRules.freeze_roster(ModeDefs.MODE_TEAM),
			"对局中的房:三模式都可见、都冻结名单")

	# ⑦ 未知模式一律拒绝(不静默当 1v1)
	_chk(ModeRoomRules.min_players("duel") == 0 and ModeRoomRules.max_players("duel") == 0
			and not ModeRoomRules.start_allowed("duel", 2, {})
			and not ModeRoomRules.visible_in_match("duel"),
			"未知模式必须被拒(人数 0、不可开局、不可见)")

	# ⑧ 边界:3v3 少一人不许开(5 人)、大乱斗 16 人上限由 ROLE_MAX 决定
	_chk(not ModeRoomRules.start_allowed(ModeDefs.MODE_TEAM, 5, {1: 3, 2: 2})
			and ModeRoomRules.max_players(ModeDefs.MODE_ROYALE) == ModeDefs.ROLE_MAX,
			"边界:3v3 5 人不许开;大乱斗上限 = ROLE_MAX")

	if _checks < EXPECTED_CHECKS:
		_fails.append("断言条数不足(%d/%d)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("MODE ROOM RULES OK(%d 条断言)" % _checks)
	else:
		for f in _fails:
			print("  FAIL %s" % f)
		print("MODE ROOM RULES FAIL(%d/%d)" % [_fails.size(), _checks])
	quit(0)
