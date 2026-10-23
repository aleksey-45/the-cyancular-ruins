class_name ModeRoomRules
extends RefCounted

# 房间规则表(纯函数、不引 autoload ⇒ `-s` 可测)。
#
# 为什么收在这里:三个模式的"人数上下限 / 队伍 / 开始条件 / 端口归还延迟"此前散在
# `LobbyRooms` 的三个房型类与 `room_sweep_lint` 的字面量里;新增或调整规则要同时改多处,
# 漏一处不报错(典型:3v3 降级开局、端口 120s/360s 混用)。
#
# ★ 数值来源(改这里必须同步):
#   · 人数上限只认 `ModeDefs.ROLE_MAX`(16)与 `ModeDefs.TEAM_SIZE × TEAM_COUNT`(=6);
#   · 端口归还延迟只认 `WorkerLauncher.*_PORT_REUSE_DELAY`(120/360/360)—— 不在这里写第二份数;
#   · 大乱斗默认房间人数 4 属于 UI 默认值,不放这里(Task 9 房型合并时再定归属)。

static func min_players(mode: String) -> int:
	match mode:
		ModeDefs.MODE_PVP: return 2
		ModeDefs.MODE_ROYALE: return 2
		ModeDefs.MODE_TEAM: return ModeDefs.TEAM_SIZE * ModeDefs.TEAM_COUNT
	return 0


static func max_players(mode: String) -> int:
	match mode:
		ModeDefs.MODE_PVP: return 2
		ModeDefs.MODE_ROYALE: return ModeDefs.ROLE_MAX
		ModeDefs.MODE_TEAM: return ModeDefs.TEAM_SIZE * ModeDefs.TEAM_COUNT
	return 0


static func team_size(mode: String) -> int:
	return ModeDefs.TEAM_SIZE if mode == ModeDefs.MODE_TEAM else 0


static func needs_teams(mode: String) -> bool:
	return mode == ModeDefs.MODE_TEAM


## 大厅侧"可以点开始"的判据。3v3 = 两队各满员(不降级);大乱斗/1v1 = 到最低人数即可。
## ★ 大乱斗的"20s 仍收不齐按已到人数开局"是 worker 的降级梯,不在大厅判据里 —— 见 degraded_start_allowed。
static func start_allowed(mode: String, humans: int, team_counts: Dictionary = {}) -> bool:
	if not ModeDefs.is_mode(mode):
		return false   # 未知模式一律拒绝(不静默当 1v1;min_players 返回 0 会让它"天然可开")
	if humans < min_players(mode):
		return false
	if mode == ModeDefs.MODE_TEAM:
		return int(team_counts.get(1, 0)) >= ModeDefs.TEAM_SIZE \
				and int(team_counts.get(2, 0)) >= ModeDefs.TEAM_SIZE
	return true


## worker 是否允许"收不齐也开"(大乱斗专用;3v3/1v1 都不许)。
static func degraded_start_allowed(mode: String) -> bool:
	return mode == ModeDefs.MODE_ROYALE


## 端口在 teardown 后多久才可复用(秒)。唯一来源 = WorkerLauncher 的三个常量。
static func port_return_seconds(mode: String) -> float:
	match mode:
		ModeDefs.MODE_PVP: return WorkerLauncher.WORKER_PORT_REUSE_DELAY
		ModeDefs.MODE_ROYALE: return WorkerLauncher.ROYALE_PORT_REUSE_DELAY
		ModeDefs.MODE_TEAM: return WorkerLauncher.TEAM_PORT_REUSE_DELAY
	return WorkerLauncher.WORKER_PORT_REUSE_DELAY


## 对局中的房是否仍出现在列表里(三模式都是:活到 worker 退出;见 modes.md §对局中的房)。
static func visible_in_match(mode: String) -> bool:
	return mode in ModeDefs.MODE_IDS


## 开局那一刻是否把名单冻结进房记录(转连 worker 后靠它渲染列表)。
static func freeze_roster(mode: String) -> bool:
	return mode in ModeDefs.MODE_IDS
