class_name RejoinRegistry
extends RefCounted

# 大厅侧的回局凭据表:token → 哪一局、哪个 worker、给谁。必须独立于房对象(查询要活过 teardown_room);
# 只留"哪一局"的键、不留房号(三张注册表房号空间重叠);TTL 只是 GC 上界,判据是 worker 还活着。
const TOKEN_TTL_SECONDS := 3600.0

var _by_token: Dictionary = {}   # token(String) -> {code, mode, role, worker_port, worker_pid, expires_at}


# ★ 必须在 worker 拉起成功之后调(要它的 pid;进程还活着才是回局的判据)。
# ★ BUG-14(2026-10-30):凭据必须带 mode —— 三张注册表的房号空间重叠(同号跨模式共存是允许的),
#   只比 code 会让持 3v3 凭据的玩家在大乱斗列表里看到无关的私密房 "1234"(names/map 泄漏)。
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


# 过期的当作不存在;★ 本函数不改表(GC 走 prune)—— 它有两个读者,查询带副作用会让两边行为不一致。
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


# ★ 身份只能靠凭据,不能靠 peer(回菜单再进大厅是一条新连接,players 已摘干净);只看 TTL、不看 worker
# 活性 —— 活性由点下去那刻的 decision() 回答。★ 空 token 早退今天只是保险带:表里不会有空键,删了行为不变。
func owns(token: String, code: String, now_ms: int, mode: String) -> bool:
	if token.is_empty():
		return false
	var e := lookup(token, now_ms)
	return not e.is_empty() and str(e.get("code", "")) == code and str(e.get("mode", "")) == mode


func drop_token(token: String) -> void:
	_by_token.erase(token)


# ★ 键是 worker 端口、不是房间号:三张注册表的房号空间重叠,按 code 作废会误伤同号那间、且一行日志都没有;
# 别把按 code 的版本加回来。★ 端口 <= 0 一律不清(它不是通配,当通配会一次清光整张表)。
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
