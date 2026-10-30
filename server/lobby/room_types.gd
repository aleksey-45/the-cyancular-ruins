class_name RoomTypes
extends RefCounted

# 大厅唯一的房记录(2026-10-22 三房型合并,spec §3 方案 B):`mode` 字段 + 三种房型字段的**并集**。
# ★ 为什么合一:三张表 × 三个类 ⇒ teardown / 清扫 / 列表 / 面板五处各写一份 `is RoyaleRoom` 判定;
#   加第四个模式要改十几处,漏一处都是静默错(端口不还 / 拆错房)。判据改成 `mode` 只有一份。
# ★ 字段是并集,不是「每个模式都该用」:`is_duel() / is_royale() / is_team()` 才是"这字段归谁"的答案。
# ★ 外部(lobby_snapshot / room_manager / 探针)仍按 `LobbyRooms.Room` / `RoyaleRoom` / `TeamRoom` 标注 ——
#   那三个名字在 lobby_rooms.gd 里是本类的**别名**(同一个类,零转换)。


class Room:
	var mode: String = ""              # ModeDefs.MODE_* —— 模式的唯一真相;拆除三态读它,不再 `is`
	var code: String = ""
	var host_peer: int = 0             # 1v1 旧实现没有它(房主 = players[0]);统一后也写入,展示仍按 players[0]
	var players: Array[int] = []       # peer ids(**只表示"此刻还连在大厅这个房里的人"**)
	var player_role: Dictionary = {}   # peer id -> role(1v1:1/2;大乱斗:1..N;3v3:1..6,最小空闲号)
	var in_match := false              # 已开局(1v1 的旧名 `started` 是它的属性别名)
	var worker_port: int = 0           # 本房拉起的 worker UDP 端口(关房时归还)
# worker 进程 pid:「这一局还在不在」的唯一精确判据;0 = 还没登记(拉起中)→ 一律判没结束。
	var worker_pid: int = 0
	var roster: Array = []             # 开局那一刻冻结的 [{role, name}](转连 worker 后 players 会空)
	var created_at: float = 0.0        # 创建时间戳(unix 秒;超龄清理用)
	var is_public := true
	var invite_code := ""              # 私密房凭此码进入
	var team_of: Dictionary = {}       # 3v3: role(int) -> 1/2(**选边前不在表里**)
	var max_players := 0               # 1v1 = 2;大乱斗建房页上限(2..16);3v3 = TEAM_ROLES
	var beta := false                  # 时间玩法房:与普通房互不可进/互不可见
	var time_rules: Dictionary = {}    # TimeRules.to_dict(),开局前 from_dict + clamp 再消费
	# (S-11 2026-10-30:原 `options` 是只写不读的死字段,已删 —— 真正生效的对局选项走 player_options → _claim_opts → MatchHost)
	var map := ""                      # 房主上报的地图(仅列表展示);与真正定图的 player_options.map 是两个真值
	var match_time := 0                # 大乱斗一局限时(仅列表展示)

	# 1v1 的旧字段名:lobby_snapshot / rejoin_probe 读它、room_manager 写它。同一份值,不是第二份真相。
	var started: bool:
		get:
			return in_match
		set(value):
			in_match = value

	func is_duel() -> bool:
		return mode == ModeDefs.MODE_PVP

	func is_royale() -> bool:
		return mode == ModeDefs.MODE_ROYALE

	func is_team() -> bool:
		return mode == ModeDefs.MODE_TEAM


# ── 3v3 的纯判据(2026-10-30 S-09:从 LobbyRooms 挪来;本类纯 RefCounted ⇒ `-s` 可测)──
# 入参形状统一是 `{1: [role, …], 2: [role, …]}`(由 by_team 产出,单一来源)。
# ★ 原注释写「静态:-s 可测」但宿主是 `LobbyRooms(Node,引 NetBus)` ⇒ 那句断言根本不成立;挪到这里才成立。

# 两队是否都满员(满 6 人才允许开局)。★ 4v2 也算 6 人,但那不是 3v3。
static func team_ready(by_team: Dictionary, size: int = ModeDefs.TEAM_SIZE) -> bool:
	return (by_team.get(1, []) as Array).size() == size \
			and (by_team.get(2, []) as Array).size() == size


static func team_can_join(by_team: Dictionary, team: int, size: int = ModeDefs.TEAM_SIZE) -> bool:
	return (by_team.get(team, []) as Array).size() < size


# 最小空闲 role 号(有人退房留下的空洞会被复用)。★ 不能写成「人数 + 1」:那是「编号恒连续」的假设 ——
# 房里有 {1,3} 时按人数推会算出 3,撞上仍在房里的高号玩家、同一个 role 双份占用。
static func team_next_role(used_roles: Array) -> int:
	var role := 1
	while used_roles.has(role):
		role += 1
	return role


# {队号: [role, …]} —— 判据的入参形状(单一来源,别在 handler 里另算一遍)。
static func by_team(room: Room) -> Dictionary:
	var out := {1: [], 2: []}
	for role in room.team_of:
		var t := int(room.team_of[role])
		if out.has(t):
			(out[t] as Array).append(int(role))
	return out


# 这个房能不能开局(RoomManager.team_start / team_match_probe 都问它)。
static func team_room_ready(room: Room) -> bool:
	return team_ready(by_team(room))


# 列表载荷里的三档人数。★ 键**必须**是字符串:客户端 `room_list.gd` 按 `"1"/"2"/"0"` 读(读取契约;
# RPC 的 Variant 编码保不住 int 键)—— 从 room_registry 挪来的同一份实现。
static func team_counts_of(room: Room) -> Dictionary:
	var counts := {"1": 0, "2": 0, "0": 0}
	for role in room.player_role.values():
		var t := int(room.team_of.get(int(role), 0))
		var k := str(t if t == 1 or t == 2 else 0)
		counts[k] = int(counts[k]) + 1
	return counts


# 日志里的房型文案(拆除 / 超时清理 / 房主转移共用):合并前这三处各写一遍三元表达式。
static func kind_text(room: Room) -> String:
	match room.mode:
		ModeDefs.MODE_ROYALE:
			return "大乱斗房"
		ModeDefs.MODE_TEAM:
			return "3v3 房"
	return "房间"
