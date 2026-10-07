class_name RejoinRegistry
extends RefCounted

# 大厅侧断线重连凭据注册表：记录重连令牌（token）与对局局号、房间号、角色分配及生命周期状态。
#
# 架构与设计规范：
# 1. 凭据生命周期独立于房间对象：
#    客户端在对局结束后重连或从主菜单返回大厅时，房间对象可能已被回收清理。
#    独立维护凭据注册表，确保客户端能获得明确的“对局已结束”判定，而非未知房间状态。
# 2. 以对局局号（match_id）为关联主键：
#    房间号空间在 1v1、大乱斗和 3v3 模式间可能重叠；而在单进程单端口架构下，UDP 端口不再唯一标识单场对局。
#    因此采用全局单调递增的 match_id 进行精确索引和状态变更。
# 3. 纯逻辑状态机：
#    不依赖任何 Autoload 或引擎时间，时间戳由调用方传入，具备完全可测性。
# 4. TTL 垃圾回收与对局活性解耦：
#    TTL（默认 1 小时）仅作为注册表内存垃圾回收的上限阈值；
#    对局是否处于进行中由条目内部的 alive 字段显式标记（对局终止时由 RoomManager._on_session_finished 置为 false）。
const TOKEN_TTL_SECONDS := 3600.0

var _by_token: Dictionary = {}   # token(String) -> {code, role, match_id, alive, expires_at}


# 登记客户端重连凭据。开局时登记且 alive 初始置为 true，对局终止时由 end_match 置为 false。
func grant(token: String, code: String, role: int, match_id: int, now_ms: int) -> void:
	_by_token[token] = {
		"code": code,
		"role": int(role),
		"match_id": int(match_id),
		"alive": true,
		"expires_at": now_ms + int(TOKEN_TTL_SECONDS * 1000.0),
	}


# 查询指定令牌的凭据。若凭据已过期或不存在则返回空字典（本方法不产生修改副作用，清理统一走 prune）。
func lookup(token: String, now_ms: int) -> Dictionary:
	if not _by_token.has(token):
		return {}
	var e: Dictionary = _by_token[token]
	if now_ms >= int(e.get("expires_at", 0)):
		return {}
	return e


# 校验重连请求合法性。返回空字符串表示验证通过，否则返回面向用户的明确拒绝原因。
static func decision(entry: Dictionary, code: String, alive: bool) -> String:
	if entry.is_empty():
		return "凭据已失效(对局可能已结束)"
	if str(entry.get("code", "")) != code:
		return "房间号与凭据不符"
	if not alive:
		return "对局已结束"
	return ""


# 判断指定令牌是否归属于该房间（用于私密房间列表中仅向本人展示其重连条目）。
func owns(token: String, code: String, now_ms: int) -> bool:
	if token.is_empty():
		return false
	var e := lookup(token, now_ms)
	return not e.is_empty() and str(e.get("code", "")) == code


func drop_token(token: String) -> void:
	_by_token.erase(token)


# 标记指定局号（match_id）的所有凭据为失效（alive = false）。
# 在 RoomManager._on_session_finished 监听到会话结束时调用。返回受影响的条目数。
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


# 清理已超过 TTL 的过期凭据，返回清理的条目数量（由 RoomManager 定期维护定时器调用）。
func prune(now_ms: int) -> int:
	var n := 0
	for tk in _by_token.keys():
		if now_ms >= int((_by_token[tk] as Dictionary).get("expires_at", 0)):
			_by_token.erase(tk)
			n += 1
	return n


func size() -> int:
	return _by_token.size()
