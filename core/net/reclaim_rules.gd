class_name ReclaimRules
extends RefCounted

# 宽限期重连(reclaim)的拒绝判据(纯逻辑:无 autoload / 无 Node ⇒ 本文件能被 `-s` 冒烟直接驱动)。
# 三条拒绝条件一条都不能少:没开局 / 该 role 不在宽限期 / token 不匹配;任一条不满足都踢连接,不能让它静默留在局里收快照。
# ★ 为什么抽出来(G-01):这三条原先只写在 server_main._on_reclaim 里,而那只在真 worker 上跑得到 ⇒ 零自动断言。
#   本模块只做「判据」;踢人 / 换输入源 / 复位 _ack_seq·_stepped_seq 仍是 server_main 的行为,不归这里证明。
# ★ 顺序即协议:理由按「尚未开局 → 不在宽限期 → 令牌不匹配」逐层报,与旧 if/elif 链**逐字等价**(别为好写调换:调换后
#   日志里的拒绝理由会变,而"为什么被踢"正是排障第一现场)。
# 测不到什么:① server_main 是否真的调用了本模块(要真 worker);② 踢人 / 输入源替换 / ack·stepped 复位。
# 变异验证:删 `role_in_grace` 分支 ⇒ reclaim_rules_smoke ③ 红;token_matches 恒 true ⇒ ④ 红;两分支对调 ⇒ ③ 红(优先级子断言)。


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
