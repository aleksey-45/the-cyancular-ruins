class_name ReclaimRules
extends RefCounted



static func token_matches(stored: String, token: String) -> bool:
	return token != "" and stored == token


static func reject_reason(match_started: bool, host_ready: bool, role_in_grace: bool, token_ok: bool) -> String:
	if not match_started or not host_ready:
		return "尚未开局"
	if not role_in_grace:
		return "该 role 不在宽限期"
	if not token_ok:
		return "令牌不匹配"
	return ""
