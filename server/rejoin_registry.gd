class_name RejoinRegistry
extends RefCounted

# 大厅侧的**回局凭据表**(spec §3 第 2 条):token → 这一局是哪个 worker 的、给谁的。
#
# ★★ 为什么它必须独立于房对象:原先 token 存在 `Room.tokens` / `RoyaleRoom.tokens` /
#   `TeamRoom.tokens`,而那三个字典随 `teardown_room` 一起消失。回局的查询要**在大厅侧活过拆除**
#   —— 客户端从主菜单回来时,房可能已经因为对局结束被回收了(见 RoomManager._reclaim_finished_matches)
#   → 查询落到一张**独立**的表上,答案才是一个明确的"这局没了",而不是"房找不到 → 什么都不知道"。
#   ★ 那三处字段与 room_manager 的四处写入点**已随 Task 4(2026-09-21)整体删除**
#   (`grep -rn "\.tokens" server/ scenes/ core/ tests/ --include=*.gd` → 0 命中)。
#   ★ 由此得到的一条纪律:本表里**只留"哪一局"的键,不留"哪一间房"的键** —— 三张注册表的房号
#   空间重叠,按 code 反查会误伤同号的另一间房(见 `drop_port` 的注释)。
#
# ★ 纯逻辑、不引 autoload、**不读时钟**(now 由调用方传入)⇒ `-s` 可测(同 GraceWindow)。
# ★ 键是 token 本身(16 位 hex,来自 `LobbyRooms.new_token()`);value 是一份**自足**的小字典
#   —— 回局**不需要**再问房对象(房可能已经没了)。
#
# ★ TTL 只是**表的 GC 上界**,不是"这一局还能不能回去"的判据:真正的判据是 worker 进程还活着吗
#   (`decision()` 的 `worker_alive` 入参)。分开的理由:"一局打多久"三种模式各不同、且没有可读
#   常量(见 room_manager.TEAM_MATCH_ESTIMATE 的注释),而"worker 退了吗"是精确且与模式无关的。
#   TTL 取 1h:长到覆盖任何一局 + 玩家在菜单里发呆的时间,短到表不会无限长大。
const TOKEN_TTL_SECONDS := 3600.0

var _by_token: Dictionary = {}   # token(String) -> {code, role, worker_port, worker_pid, expires_at}


# 登记一份回局凭据。★ **必须在 worker 拉起成功之后调**(要它的 pid 才能判"这局还在不在")
# —— 见 RoomManager 四个 spawn 点(它们先发 `session_token`、再 spawn、最后登记)。
func grant(token: String, code: String, role: int, worker_port: int, worker_pid: int,
		now_ms: int) -> void:
	_by_token[token] = {
		"code": code,
		"role": int(role),
		"worker_port": int(worker_port),
		"worker_pid": int(worker_pid),
		"expires_at": now_ms + int(TOKEN_TTL_SECONDS * 1000.0),
	}


# 查一份凭据。过期的**当作不存在**(返回空字典)。★ 本函数**不改表**(GC 走 `prune`)——
# "查一次顺手删一条"会让同一个查询在不同调用点有不同副作用,而这张表有两个读者(大厅的
# 回局 handler 与回收梯的 GC)。
func lookup(token: String, now_ms: int) -> Dictionary:
	if not _by_token.has(token):
		return {}
	var e: Dictionary = _by_token[token]
	if now_ms >= int(e.get("expires_at", 0)):
		return {}
	return e


# 回局请求的**纯判据**:返回 "" = 放行,否则是给玩家看的拒绝理由。
# ★ 三种拒绝各有各的成因,合并不了,而且**顺序有意义**:凭据根本不存在时先报"凭据失效"
#   (那才是玩家该知道的事;报"房间号不符"会把人引向"房间号填错了"这个错方向)。
# ★ 做成静态纯函数是为了可测:`-s` 冒烟把四种组合逐个钉住,而生产侧只有一次调用、一次比较。
static func decision(entry: Dictionary, code: String, worker_alive: bool) -> String:
	if entry.is_empty():
		return "凭据已失效(对局可能已结束)"
	if str(entry.get("code", "")) != code:
		return "房间号与凭据不符"
	if not worker_alive:
		return "对局已结束"
	return ""


func drop_token(token: String) -> void:
	_by_token.erase(token)


# 某一局(某一间房)的全部凭据(房被拆除时调,见 LobbyRooms.teardown_room)。
# ★★ 键是 **worker 端口**,不是房间号(2026-09-21 修,控制器并进来的那一项):三张注册表
#   (`rooms` / `royale_rooms` / `team_rooms`)的房号空间是**重叠的** —— 三处都只用
#   `LobbyRooms._generate_code()` 的 4 位号、且 `has(code)` 各查各的表,所以"1v1 的 1234"
#   与"大乱斗的 1234"**可以同时存在**(`teardown_room` 自己的注释就点名了这件事,它选 `is`
#   而不是拿 code 撞库,正是为了躲同一个坑)。按 code 作废 ⇒ 拆掉**无关**的一间房会把另一间
#   **同号**房的玩家的凭据一起清掉:损坏有界(那位玩家只会看到「凭据已失效」),但它是错的,
#   而且**一行日志都没有**。
#   ★ 端口**每间房独占**(`WorkerLauncher.pick_port` 的唯一递增 + 占用集合)⇒ 在那张表上它是
#   唯一可用的键。★ 房自己那份记录(`tokens`)已随 Task 4 删除:同一件事只留一处。
#   ★ 别把按 code 的版本加回来当"另一个入口":它就是上面那个坑,而今天没有任何调用方要它。
# 返回值是清掉的条数(调用方只在日志里用)。
func drop_port(worker_port: int) -> int:
	# ★ 端口 <= 0 一律**什么都不清**:凭据只在 spawn 成功之后登记,那时端口必然 > 0
	#   (见 RejoinRegistry.grant 的注释),故 0 不可能是任何一条凭据的键 —— 而把它当成
	#   "通配"就会一次清光整张表。
	if worker_port <= 0:
		return 0
	var n := 0
	for tk in _by_token.keys():
		if int((_by_token[tk] as Dictionary).get("worker_port", 0)) == worker_port:
			_by_token.erase(tk)
			n += 1
	return n


# 清掉已过期的条目,返回清掉的条数(调用点 = RoomManager 的回收梯,30s 一次)。
func prune(now_ms: int) -> int:
	var n := 0
	for tk in _by_token.keys():
		if now_ms >= int((_by_token[tk] as Dictionary).get("expires_at", 0)):
			_by_token.erase(tk)
			n += 1
	return n


func size() -> int:
	return _by_token.size()
