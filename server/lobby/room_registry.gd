class_name RoomRegistry
extends RefCounted

# 三张房间表合一(`mode -> {code: Room}`,2026-10-22 spec §3 方案 B 的第二步)。

# peer id -> 昵称(原 LobbyRooms._peer_names,列表 / 冻结名单 / 面板都读它)。
var peer_names: Dictionary = {}

var _tables: Dictionary = {}   # mode(String) -> {code(String): RoomTypes.Room}


func _init() -> void:
	for mode in ModeDefs.MODE_IDS:
		_tables[mode] = {}


# 只读视图(按 mode 过滤)。★ 别改它:增删走 add / erase,否则拆除的单一收口被绕过。
func of(mode: String) -> Dictionary:
	return _tables.get(mode, {})


func add(room: RoomTypes.Room) -> void:
	if not _tables.has(room.mode):
		return
	(_tables[room.mode] as Dictionary)[room.code] = room


# 注册表删除的**唯一**原语(lint 钉住:表内 `.erase(` 只许出现在这个函数里)。
func erase(room: RoomTypes.Room) -> void:
	(_tables.get(room.mode, {}) as Dictionary).erase(room.code)


# 按 (mode, code) 精确取;mode 空 = 旧 `_room_any` 的顺序(1v1 → 大乱斗 → 3v3),
# 只给「上报地图」那种幂等写入用 —— 拆房必须带 mode。
func find(code: String, mode: String = "") -> RoomTypes.Room:
	if mode != "":
		return (_tables.get(mode, {}) as Dictionary).get(code, null)
	for m in ModeDefs.MODE_IDS:
		var t: Dictionary = _tables[m]
		if t.has(code):
			return t[code]
	return null


func room_of_peer(mode: String, peer_id: int) -> RoomTypes.Room:
	var t: Dictionary = _tables.get(mode, {})
	for code in t:
		if (t[code] as RoomTypes.Room).players.has(peer_id):
			return t[code]
	return null


# 4 位随机号(0000~9999)的单一生成器。★ 私密房邀请码也用它 —— 那是另一个空间,不去重(与旧实现逐字同语义)。
func generate_code() -> String:
	return "%04d" % (randi() % 10000)


# 房号分配:**只在本 mode 内**去重 —— 与旧 `_generate_code` 的调用点逐字同语义(跨模式同号是允许的)。
func next_code(mode: String) -> String:
	var t: Dictionary = of(mode)
	var code := generate_code()
	while t.has(code):
		code = generate_code()
	return code


func set_name(peer_id: int, name: String) -> void:
	peer_names[peer_id] = name


func name_of(peer_id: int) -> String:
	return str(peer_names.get(peer_id, "玩家"))


func drop_name(peer_id: int) -> void:
	peer_names.erase(peer_id)


# 开局那一刻把「这一局有哪些人」冻进房记录(role + 昵称快照)。★ 谁调:RoomManager 在每一处开局调一次。
func freeze_roster(room: RoomTypes.Room) -> void:
	var out: Array = []
	for pid in room.players:
		out.append({"role": int(room.player_role.get(pid, 0)), "name": name_of(pid)})
	room.roster = out


# 端口在拆除后多久才可复用(秒)。★ 唯一来源 = ModeRoomRules → WorkerLauncher.*_PORT_REUSE_DELAY
# (1v1 120 / 大乱斗 360 / 3v3 360);这里**不写第二份数** —— 写一份就会与 worker 侧漂。
func port_return_delay(mode: String) -> float:
	return ModeRoomRules.port_return_seconds(mode)


# 按模式构造房间列表载荷。协议字段逐字不变:1v1 / 大乱斗 / 3v3 各自带哪些键见下面两个分支。
# ★ 私密房只对持有凭据的本人列出(判据 = RejoinRegistry.owns;空 token ⇒ 与从前逐字相同的过滤)。
func list_payload(mode: String, token: String = "", rejoin: RejoinRegistry = null) -> Array:
	var now := Time.get_ticks_msec()
	var arr: Array = []
	for code in of(mode):
		var r: RoomTypes.Room = of(mode)[code]
		if not r.is_duel() and not r.is_public \
				and (rejoin == null or not rejoin.owns(token, code, now, mode)):
			continue
		if r.players.is_empty() and not r.in_match:
			continue   # 未开局的空房 = 幽灵房,不列;对局中的房照列(第三人要看得见)
		# ★ S-12:"房主 + 名单"的判据收在 ServerStatus.host_and_roster(本函数只搬字段)。
		var view := ServerStatus.host_and_roster(r.is_duel(), r.in_match, r.host_peer,
				int(r.player_role.get(r.host_peer, 0)), r.roster, r.players, r.player_role, peer_names)
		var names: Array = view["names"]
		var host := str(view["host"])
		var row := {"code": code, "players": names.size(), "names": names,
				"in_match": r.in_match, "is_public": r.is_public, "host": host, "map": r.map}
		if r.is_royale():
			row["max_players"] = r.max_players
			row["beta"] = r.beta
			row["match_time"] = r.match_time
		elif r.is_team():
			row["max_players"] = r.max_players
			row["beta"] = r.beta
			row["team_counts"] = RoomTypes.team_counts_of(r)
		arr.append(row)
	return arr


# 3v3 三档人数:{1: A 队, 2: B 队, 0: 未选边} —— 实现已挪到 `RoomTypes.team_counts_of`(纯函数,`-s` 可测;2026-10-30 S-09)
