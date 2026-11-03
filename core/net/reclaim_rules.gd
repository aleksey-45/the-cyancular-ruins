class_name ReclaimRules
extends RefCounted

# 宽限期重连(reclaim)的拒绝判据(纯逻辑:无 autoload / 无 Node ⇒ 本文件能被 `-s` 冒烟直接驱动)。


## 令牌判据:`token` = 客户端本次报上来的,`stored` = claim 后立刻归档的那份。
## ★ 空串一律不算匹配 —— role 没报过 token 时 `_tokens.get(role, "")` 也是空串,两边都空**不能**当成"对上了"
##   (否则"没带令牌"变成免检通行证)。
static func token_matches(stored: String, token: String) -> bool:
	return token != "" and stored == token


## 返回 ""=放行;非空 = 拒绝理由(逐字沿用旧 server_main 的打印文案,判据/日志都别改)。
static func reject_reason(match_started: bool, host_ready: bool, role_in_grace: bool, token_ok: bool) -> String:
	if not match_started or not host_ready:
		return "尚未开局"
	if not role_in_grace:
		return "该 role 不在宽限期"
	if not token_ok:
		return "令牌不匹配"
	return ""
