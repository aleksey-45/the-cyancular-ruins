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
	var options: Dictionary = {}       # 大乱斗房主对局选项(禁武器/回合回血)
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


# 日志里的房型文案(拆除 / 超时清理 / 房主转移共用):合并前这三处各写一遍三元表达式。
static func kind_text(room: Room) -> String:
	match room.mode:
		ModeDefs.MODE_ROYALE:
			return "大乱斗房"
		ModeDefs.MODE_TEAM:
			return "3v3 房"
	return "房间"
