class_name ModeRoomRules
extends RefCounted

# 房间规则表(纯函数、不引 autoload ⇒ `-s` 可测)。

## 端口在 teardown 后多久才可复用(秒)。
static func port_return_seconds(mode: String) -> float:
	match mode:
		ModeDefs.MODE_PVP: return WorkerLauncher.WORKER_PORT_REUSE_DELAY
		ModeDefs.MODE_ROYALE: return WorkerLauncher.ROYALE_PORT_REUSE_DELAY
		ModeDefs.MODE_TEAM: return WorkerLauncher.TEAM_PORT_REUSE_DELAY
	return WorkerLauncher.WORKER_PORT_REUSE_DELAY