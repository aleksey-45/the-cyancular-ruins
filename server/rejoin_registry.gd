class_name RejoinRegistry
extends RefCounted

# 大厅侧的**回局凭据表**(spec §3 第 2 条):token → 这一局是哪个 worker 的、给谁的。
#
# ★★ 为什么它必须独立于房对象:原先 token 存在 `Room.tokens` / `RoyaleRoom.tokens` /
#   `TeamRoom.tokens`,而那三个字典随 `teardown_room` 一起消失。回局的查询要**在大厅侧活过拆除**
#   —— 客户端从主菜单回来时,房可能已经因为对局结束被回收了(见 RoomManager._reclaim_finished_matches)
#   → 查询落到一张**独立**的表上,答案才是一个明确的"这局没了",而不是"房找不到 → 什么都不知道"。
#   ★ 因此三个房类的 `tokens` 字段要**整体删除**(同一件事只留一处记录)。★★ 但**不是本步**:
#   本表落地时(2026-09-21)那三处字段(`lobby_rooms.gd` 的 `Room`/`RoyaleRoom`/`TeamRoom`)与
#   `room_manager.gd` 的四处写入点**都还在**,由接线的 **Task 4** 一起删。故读到上一段时别以为
#   "已经删过了" —— **grep 一遍 `.tokens`,还有命中就说明那步没做完**。
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


# 某一间房的全部凭据(房被拆除时调,见 LobbyRooms.teardown_room)。
# ★ 按 code **全等**反查,而不是让房自己记一串 token:房侧那份记录(`tokens`)届时一并删除
#   (截至本表落地**还没删**,见文件头),留着它就是第二份真相。返回值是清掉的条数(调用方只在日志里用)。
func drop_room(code: String) -> int:
	var n := 0
	for tk in _by_token.keys():
		if str((_by_token[tk] as Dictionary).get("code", "")) == code:
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
