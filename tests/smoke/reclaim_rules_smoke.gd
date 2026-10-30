extends SceneTree
# 局内闪断重连(reclaim)拒绝判据守卫(G-01:`_on_reclaim` 的三条拒绝分支零自动断言)。
# 守卫对象 = ReclaimRules(纯逻辑:无 autoload / 无 Node ⇒ 本文件能 `-s` 跑):
#   reject_reason(match_started, host_ready, role_in_grace, token_ok) 返回 ""=放行,否则 = 逐字拒绝理由。
# 三条拒绝一条都不能少:没开局(含 host 未就绪)/ 该 role 不在宽限期 / 令牌空或不符;任一条不满足都踢连接。
# ★ 顺序也钉住:多处同时不满足时理由按旧 if/elif 链的顺序报(别调换分支 —— 日志里的"为什么被踢"会变)。
# 去掉什么才红:删 `role_in_grace` 分支 ⇒ ③ 红;token_matches 恒 true 或删空串判据 ⇒ ④ 红;
#   把宽限/令牌两支对调 ⇒ ③ 的优先级子断言红;`not match_started or not host_ready` 拆丢一支 ⇒ ①② 红。
# 测不到什么:① server_main 是否真的调用本模块(要真 worker);② 踢人、(重)换输入源、`_ack_seq`/`_stepped_seq`
#   复位、match_start 应答 —— 那些是行为,不是纯判据。真链路(rejoin_probe)覆盖路径乙(回大厅重连),不是这条。
# 跑法:"$GODOT" --headless --path . -s res://tests/smoke/reclaim_rules_smoke.gd;通过 = RECLAIM RULES OK(n 条断言)。

const EXPECTED_CHECKS := 5

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	# ★ 空载守卫(仓规):load() 失败还往下走会在 null 上抛错,而 `-s` 抛错走不到 quit() ⇒ 进程永久挂起。
	if load("res://core/net/reclaim_rules.gd") == null:
		print("RECLAIM RULES FAILED: load(reclaim_rules.gd) 返回 null(-s 空载守卫:不 quit 会挂死)")
		quit(1)
		return

	# ① 没开局:match_started=false ⇒ 拒;且「多处不满足」时理由仍是这条(链序:开局 → 宽限 → 令牌)
	_chk(ReclaimRules.reject_reason(false, true, true, true) == "尚未开局"
			and ReclaimRules.reject_reason(false, false, false, false) == "尚未开局",
			"没开局必须拒绝,且理由优先级最高(实得 %s)" % ReclaimRules.reject_reason(false, true, true, true))

	# ② 没开局 + host 未就绪:旧的 `_host == null` 独立拒绝分支(与 ① 合并成同一条理由)
	_chk(ReclaimRules.reject_reason(true, false, true, true) == "尚未开局",
			"host 未就绪必须拒绝(旧的 _host == null 分支;实得 %s)"
			% ReclaimRules.reject_reason(true, false, true, true))

	# ③ 该 role 不在宽限期:拒;且它排在令牌之前(若先判令牌,没报 token 的人会拿到错理由)
	_chk(ReclaimRules.reject_reason(true, true, false, true) == "该 role 不在宽限期"
			and ReclaimRules.reject_reason(true, true, false, false) == "该 role 不在宽限期",
			"不在宽限期必须拒绝且理由排在令牌之前(实得 %s / %s)" % [
				ReclaimRules.reject_reason(true, true, false, true),
				ReclaimRules.reject_reason(true, true, false, false)])

	# ④ 令牌空或不符必须拒绝(空串不能当成"两边都空 ⇒ 对上";这是免检通行证)
	_chk(ReclaimRules.reject_reason(true, true, true, false) == "令牌不匹配"
			and not ReclaimRules.token_matches("", "")
			and not ReclaimRules.token_matches("tok", "")
			and not ReclaimRules.token_matches("tok", "other")
			and ReclaimRules.token_matches("tok", "tok"),
			"令牌空 / 不符必须拒绝,只有非空且相等才匹配")

	# ⑤ 四条全满足 ⇒ 放行(返回空串)
	_chk(ReclaimRules.reject_reason(true, true, true, true) == "",
			"四条全满足必须放行(实得「%s」)" % ReclaimRules.reject_reason(true, true, true, true))

	# 判词:计数闸(条数不符也红 —— 防断言被静默跳过)
	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("RECLAIM RULES OK(%d 条断言):没开局 · host 未就绪 · 不在宽限 · 令牌空/不符 · 全满足放行(含理由优先级)"
				% _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("RECLAIM RULES FAILED: %d 处" % _fails.size())
		quit(1)
