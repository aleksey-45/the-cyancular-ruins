class_name ModeRoomRules
extends RefCounted

# 房间规则表(纯函数、不引 autoload ⇒ `-s` 可测)。
#
# ★ 2026-10-30(S-10,01 审查):本文件原先还有 8 个"人数上下限 / 队伍 / 开始条件 / 列表可见性 /
#   冻结名单"的规则函数 —— 全仓**零调用点**,而同一批量又在 `LobbyRooms` 的常量里各写一份(两份真相)。
#   已删零调用函数;房间侧直接引 `ModeDefs`(上限/队伍的唯一来源)。这里只保留真正被消费的端口归还延迟。
#
# ★ 端口归还延迟的唯一来源 = `WorkerLauncher.*_PORT_REUSE_DELAY`(120/360/360),本文件只转发、不写第二份数。

## 端口在 teardown 后多久才可复用(秒)。
static func port_return_seconds(mode: String) -> float:
	match mode:
		ModeDefs.MODE_PVP: return WorkerLauncher.WORKER_PORT_REUSE_DELAY
		ModeDefs.MODE_ROYALE: return WorkerLauncher.ROYALE_PORT_REUSE_DELAY
		ModeDefs.MODE_TEAM: return WorkerLauncher.TEAM_PORT_REUSE_DELAY
	return WorkerLauncher.WORKER_PORT_REUSE_DELAY