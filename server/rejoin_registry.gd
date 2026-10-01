class_name RejoinRegistry
extends RefCounted

# 大厅侧的**回局凭据表**:token → 这一局是哪个局、给谁的、还在不在。
#
# ★★ 为什么它必须独立于房对象:原先 token 存在 `Room.tokens` / `RoyaleRoom.tokens` /
#   `TeamRoom.tokens`,而那三个字典随 `teardown_room` 一起消失。回局的查询要**在大厅侧活过拆除**
#   —— 客户端从主菜单回来时,房可能已经因为对局结束被回收了 → 查询落到一张**独立**的表上,
#   答案才是一个明确的"这局没了",而不是"房找不到 → 什么都不知道"。
#   ★ 那三处字段与 room_manager 的四处写入点**已随 Task 4(2026-09-21)整体删除**。
#
# ★★ 键是 `match_id`(**局号**),不是房号、也不是端口。两条历史教训都指向这里:
#   · 房号:三张注册表(`rooms`/`royale_rooms`/`team_rooms`)的房号空间**重叠**(共用
#     `LobbyRooms._generate_code()`),按房号作废会误伤**同号**的另一间房里那位玩家的凭据;
#   · 端口:那是"每局一个 worker 子进程"时代的产物,单进程单端口之后端口不再标识任何一局。
#   局号由 `RoomManager` 唯一递增分配,**永不复用**,在任何一张表上都唯一。
#
# ★ 纯逻辑、不引 autoload、**不读时钟**(now 由调用方传入)⇒ `-s` 可测(同 GraceWindow)。
# ★ 键是 token 本身(16 位 hex,来自 `LobbyRooms.new_token()`);value 是一份**自足**的小字典
#   —— 回局**不需要**再问房对象(房可能已经没了)。故 `alive` 也记在条目上,而不是回局时
#   现问"那一局还在吗"。
#
# ★ TTL 只是**表的 GC 上界**,不是"这一局还能不能回去"的判据:真正的判据是条目上的 `alive`
#   (由 `RoomManager` 在"对局结束"那一刻翻成 false —— 那是唯一知道这件事的地方)。
const TOKEN_TTL_SECONDS := 3600.0

var _by_token: Dictionary = {}   # token(String) -> {code, role, match_id, alive, expires_at}


# 登记一份回局凭据。★ 登记时 `alive = true`(调用点在开局那一刻,那一局当然还活着),
# 之后只有 `end_match` 会翻它。
func grant(token: String, code: String, role: int, match_id: int, now_ms: int) -> void:
	_by_token[token] = {
		"code": code,
		"role": int(role),
		"match_id": int(match_id),
		"alive": true,
		"expires_at": now_ms + int(TOKEN_TTL_SECONDS * 1000.0),
	}


# 查一份凭据。过期的**当作不存在**(返回空字典)。★ 本函数**不改表**(GC 走 `prune`)——
# "查一次顺手删一条"会让同一个查询在不同调用点有不同副作用,而这张表有两个读者(大厅的
# 回局 handler 与 GC 梯)。
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
static func decision(entry: Dictionary, code: String, alive: bool) -> String:
	if entry.is_empty():
		return "凭据已失效(对局可能已结束)"
	if str(entry.get("code", "")) != code:
		return "房间号与凭据不符"
	if not alive:
		return "对局已结束"
	return ""


## 某一局结束了 → 它的凭据全部作废。**唯一的调用点**是 `RoomManager._on_session_finished`
## (会话自己说"我结束了"的那一刻)。
## ★ 返回清掉的条数(调用方只在日志里用)。★ 局号 <= 0 一律**什么都不动**:0 只出现在"还没开局"
##   的房上,把它当"通配"就会一次翻掉整张表。
func end_match(match_id: int) -> int:
	if match_id <= 0:
		return 0
	var n := 0
	for tk in _by_token.keys():
		var e: Dictionary = _by_token[tk]
		if int(e.get("match_id", 0)) == match_id:
			e["alive"] = false
			n += 1
	return n


func drop_token(token: String) -> void:
	_by_token.erase(token)


# 清掉已过期的条目,返回清掉的条数(调用点 = RoomManager 的 GC 梯,30s 一次)。
func prune(now_ms: int) -> int:
	var n := 0
	for tk in _by_token.keys():
		if now_ms >= int((_by_token[tk] as Dictionary).get("expires_at", 0)):
			_by_token.erase(tk)
			n += 1
	return n


func size() -> int:
	return _by_token.size()
