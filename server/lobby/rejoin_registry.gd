class_name RejoinRegistry
extends RefCounted

const TOKEN_TTL_SECONDS := 3600.0


static func new_token() -> String:
	return "%08x%08x" % [randi(), randi()]

var _by_token: Dictionary = {}


func grant(token: String, code: String, role: int, worker_port: int, worker_pid: int,
		now_ms: int, mode: String) -> void:
	_by_token[token] = {
		"code": code,
		"mode": mode,
		"role": int(role),
		"worker_port": int(worker_port),
		"worker_pid": int(worker_pid),
		"expires_at": now_ms + int(TOKEN_TTL_SECONDS * 1000.0),
	}


func lookup(token: String, now_ms: int) -> Dictionary:
	if not _by_token.has(token):
		return {}
	var e: Dictionary = _by_token[token]
	if now_ms >= int(e.get("expires_at", 0)):
		return {}
	return e


# "" = 放行,否则是给玩家看的拒绝理由。★ 顺序有意义:凭据不存在时先报"凭据失效",报"房间号不符"会把人引向错的排查方向。
# ★ BUG-14:房间号相同时必须再比 mode(同号跨模式是允许的) —— 否则点另一模式里同号的房也会被当成自己那间。
static func decision(entry: Dictionary, code: String, worker_alive: bool, mode: String) -> String:
	if entry.is_empty():
		return "凭据已失效(对局可能已结束)"
	if str(entry.get("code", "")) != code:
		return "房间号与凭据不符"
	if str(entry.get("mode", "")) != mode:
		return "该凭据属于其他模式"
	if not worker_alive:
		return "对局已结束"
	return ""


func owns(token: String, code: String, now_ms: int, mode: String) -> bool:
	if token.is_empty():
		return false
	var e := lookup(token, now_ms)
	return not e.is_empty() and str(e.get("code", "")) == code and str(e.get("mode", "")) == mode


func drop_token(token: String) -> void:
	_by_token.erase(token)


func drop_port(worker_port: int) -> int:

	if worker_port <= 0:
		return 0
	var n := 0
	for tk in _by_token.keys():
		if int((_by_token[tk] as Dictionary).get("worker_port", 0)) == worker_port:
			_by_token.erase(tk)
			n += 1
	return n



func prune(now_ms: int) -> int:
	var n := 0
	for tk in _by_token.keys():
		if now_ms >= int((_by_token[tk] as Dictionary).get("expires_at", 0)):
			_by_token.erase(tk)
			n += 1
	return n
