extends SceneTree

# 大厅房记录与注册表的纯逻辑守卫(不碰 NetBus / 端口 / 场景树 ⇒ `-s` 可跑)。
# 覆盖:统一 Room 的默认值与模式判据、三表合一(同号跨模式不串、按 mode 精确取/删)、房号分配、
#       名单冻结、三种模式的列表载荷字段集。
# ★ 去掉什么才会红:
#   ① 把 `is_royale()` 改成恒 true ⇒ ② 红;
#   ② 把 `erase()` 改成按 code 从所有表删 ⇒ ④ 红(同号跨模式共存被破坏);
#   ③ 列表载荷漏一个键(如大乱斗的 match_time)⇒ ⑦/⑧ 红(客户端读不到那一列);
#   ④ 私密房不再按凭据过滤 ⇒ ⑧ 红(第三人看见私密房)。
# ⚠ -s 脚本套外层 timeout。

const EXPECTED_CHECKS := 11

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _mk(mode: String, code: String) -> RoomTypes.Room:
	var r := RoomTypes.Room.new()
	r.mode = mode
	r.code = code
	return r


func _keys(d: Dictionary) -> Array:
	var out: Array = d.keys()
	out.sort()
	return out


func _initialize() -> void:
	# ① 统一房记录的默认值(字段并集,每个模式的旧默认都被保住)
	var fresh := RoomTypes.Room.new()
	_chk(fresh.mode == "" and fresh.code == "" and fresh.players.is_empty()
			and fresh.player_role.is_empty() and not fresh.in_match and not fresh.started
			and fresh.worker_port == 0 and fresh.worker_pid == 0 and fresh.roster.is_empty()
			and fresh.created_at == 0.0 and fresh.is_public and fresh.invite_code == ""
			and fresh.team_of.is_empty() and fresh.max_players == 0 and not fresh.beta
			and fresh.time_rules.is_empty(),
			"统一 Room 的字段默认值(全空/零/false;is_public 默认 true)")

	# ② 模式判据:三种 mode 各自只认自己(加 mode 的意义就在这 —— 不再 `is RoyaleRoom`)
	var pvp := _mk(ModeDefs.MODE_PVP, "0001")
	var roy := _mk(ModeDefs.MODE_ROYALE, "0002")
	var team := _mk(ModeDefs.MODE_TEAM, "0003")
	_chk(pvp.is_duel() and not pvp.is_royale() and not pvp.is_team()
			and roy.is_royale() and not roy.is_duel() and not roy.is_team()
			and team.is_team() and not team.is_duel() and not team.is_royale(),
			"is_duel/is_royale/is_team 只有各自的 mode 为真")

	# ③ 1v1 旧字段名 started 是 in_match 的别名(外部 lobby_snapshot / rejoin_probe 读它)
	pvp.started = true
	var alias_ok := pvp.in_match
	pvp.in_match = false
	_chk(alias_ok and not pvp.started, "started 与 in_match 是同一份值(双向别名)")

	# ④ 三表合一:同号跨模式共存;find 带 mode 精确取、不带 mode 按旧顺序(1v1 → 大乱斗 → 3v3)
	var reg := RoomRegistry.new()
	reg.add(_mk(ModeDefs.MODE_PVP, "0421"))
	reg.add(_mk(ModeDefs.MODE_ROYALE, "0421"))
	reg.add(_mk(ModeDefs.MODE_TEAM, "0421"))
	_chk(reg.of(ModeDefs.MODE_PVP).size() == 1 and reg.of(ModeDefs.MODE_ROYALE).size() == 1
			and reg.of(ModeDefs.MODE_TEAM).size() == 1 and reg.of("nope").is_empty()
			and reg.find("0421", ModeDefs.MODE_ROYALE).is_royale()
			and reg.find("0421", ModeDefs.MODE_TEAM).is_team()
			and reg.find("0421").is_duel() and reg.find("9999") == null,
			"同号跨模式共存;of(mode) 按模式过滤;find(code) 走 1v1→大乱斗→3v3")

	# ⑤ erase 只从它自己的模式里删(旧实现按 code 反查三张表 = 静默错拆)
	reg.erase(reg.find("0421", ModeDefs.MODE_ROYALE))
	_chk(reg.find("0421", ModeDefs.MODE_ROYALE) == null
			and reg.find("0421", ModeDefs.MODE_PVP) != null
			and reg.find("0421", ModeDefs.MODE_TEAM) != null,
			"erase(room) 只摘自己那张表(同号的另两个模式还在)")

	# ⑥ 房号分配:4 位、只在本模式内去重(把一张表填到只剩 0007 ⇒ 必须收敛到它,不会撞号也不会死循环)
	var dens := RoomRegistry.new()
	for n in range(10000):
		var c := "%04d" % n
		if c != "0007":
			dens.add(_mk(ModeDefs.MODE_TEAM, c))
	_chk(dens.next_code(ModeDefs.MODE_TEAM) == "0007"
			and dens.next_code(ModeDefs.MODE_PVP).length() == 4,
			"next_code 只在本模式内去重(满表时收敛到唯一空号)")

	# ⑦ 名单冻结(role + 昵称快照;没上报昵称的落「玩家」)
	var fr := RoomRegistry.new()
	fr.set_name(7, "阿七")
	var room := _mk(ModeDefs.MODE_TEAM, "0123")
	room.players.append(7)
	room.player_role[7] = 2
	room.players.append(9)
	room.player_role[9] = 5
	fr.freeze_roster(room)
	_chk(room.roster.size() == 2
			and int((room.roster[0] as Dictionary).get("role", 0)) == 2
			and str((room.roster[0] as Dictionary).get("name", "")) == "阿七"
			and str((room.roster[1] as Dictionary).get("name", "")) == "玩家",
			"freeze_roster 冻结 role + 昵称(缺昵称落「玩家」)")

	# ⑧ 1v1 列表载荷:字段集逐字不变;对局中取冻结名单,房主 = 名单第一条
	var pvp_reg := RoomRegistry.new()
	var a := _mk(ModeDefs.MODE_PVP, "0011")
	a.players.append(1)
	a.player_role[1] = 1
	a.created_at = 1.0
	pvp_reg.set_name(1, "房主甲")
	pvp_reg.add(a)
	var waiting_rows := pvp_reg.list_payload(ModeDefs.MODE_PVP)
	var ghost := _mk(ModeDefs.MODE_PVP, "0012")
	pvp_reg.add(ghost)   # 未开局且没人的房 = 幽灵房,不列
	a.in_match = true
	a.player_role.clear()
	a.roster = [{"role": 1, "name": "房主甲"}, {"role": 2, "name": "客乙"}]
	a.players.clear()
	pvp_reg.set_name(1, "")
	var match_rows := pvp_reg.list_payload(ModeDefs.MODE_PVP)
	_chk(waiting_rows.size() == 1 and match_rows.size() == 1
			and _keys(waiting_rows[0]) == _keys({"code": 1, "players": 1, "names": [], "in_match": false,
					"is_public": true, "host": "", "map": ""})
			and int(match_rows[0]["players"]) == 2
			and str(match_rows[0]["host"]) == "房主甲"
			and match_rows[0]["names"] == ["房主甲", "客乙"],
			"1v1 列表载荷字段集不变;局中走冻结名单、空房不列")

	# ⑨ 大乱斗列表载荷:多三个键;私密房无凭据不列、有凭据才列
	var roy_reg := RoomRegistry.new()
	var priv := _mk(ModeDefs.MODE_ROYALE, "0021")
	priv.host_peer = 1
	priv.players.append(1)
	priv.player_role[1] = 1
	priv.is_public = false
	priv.invite_code = "8888"
	priv.max_players = 6
	priv.beta = true
	priv.match_time = 300
	roy_reg.set_name(1, "房主乙")
	roy_reg.add(priv)
	var rj := RejoinRegistry.new()
	var hidden := roy_reg.list_payload(ModeDefs.MODE_ROYALE, "", rj)
	rj.grant("tok", "0021", 1, 7999, 4242, Time.get_ticks_msec())
	var shown := roy_reg.list_payload(ModeDefs.MODE_ROYALE, "tok", rj)
	_chk(hidden.is_empty() and shown.size() == 1
			and _keys(shown[0]) == _keys({"code": "", "players": 0, "names": [], "in_match": false,
					"is_public": false, "host": "", "map": "", "max_players": 0, "beta": false,
					"match_time": 0})
			and int(shown[0]["max_players"]) == 6 and bool(shown[0]["beta"])
			and int(shown[0]["match_time"]) == 300 and str(shown[0]["host"]) == "房主乙",
			"大乱斗列表载荷含 max_players/beta/match_time;私密房按凭据过滤")

	# ⑩ 3v3 列表载荷:max_players = 6、team_counts 三档(未选边落 \"0\")
	var team_reg := RoomRegistry.new()
	var troom := _mk(ModeDefs.MODE_TEAM, "0031")
	troom.host_peer = 1
	troom.max_players = 6
	troom.players.append(1)
	troom.player_role[1] = 1
	troom.players.append(2)
	troom.player_role[2] = 2
	troom.team_of[1] = 1
	team_reg.add(troom)
	var trow: Dictionary = team_reg.list_payload(ModeDefs.MODE_TEAM)[0]
	var tc: Dictionary = trow.get("team_counts", {})
	_chk(int(trow.get("max_players", 0)) == 6 and int(tc.get("1", -1)) == 1
			and int(tc.get("2", -1)) == 0 and int(tc.get("0", -1)) == 1,
			"3v3 列表载荷 max_players=6、team_counts 三档(未选边归 0)")

	# ⑪ 端口归还延迟:注册表只做转发(数值唯一来源 = ModeRoomRules → WorkerLauncher 常量)
	var dreg := RoomRegistry.new()
	_chk(dreg.port_return_delay(ModeDefs.MODE_PVP) == ModeRoomRules.port_return_seconds(ModeDefs.MODE_PVP)
			and dreg.port_return_delay(ModeDefs.MODE_ROYALE) == ModeRoomRules.port_return_seconds(ModeDefs.MODE_ROYALE)
			and dreg.port_return_delay(ModeDefs.MODE_TEAM) == ModeRoomRules.port_return_seconds(ModeDefs.MODE_TEAM),
			"port_return_delay 只转发 ModeRoomRules(不写第二份 120/360)")

	if _checks < EXPECTED_CHECKS:
		_fails.append("断言条数不足(%d/%d)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("ROOM REGISTRY OK(%d 条断言)" % _checks)
	else:
		for f in _fails:
			print("  FAIL %s" % f)
		print("ROOM REGISTRY FAIL(%d/%d)" % [_fails.size(), _checks])
	quit(0)
