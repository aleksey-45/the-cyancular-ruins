extends SceneTree

const EXPECTED_CHECKS := 5

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	if load("res://core/net/reclaim_rules.gd") == null:
		print("RECLAIM RULES FAILED: load(reclaim_rules.gd) 返回 null(-s 空载守卫:不 quit 会挂死)")
		quit(1)
		return

	_chk(ReclaimRules.reject_reason(false, true, true, true) == "尚未开局"
			and ReclaimRules.reject_reason(false, false, false, false) == "尚未开局",
			"没开局必须拒绝,且理由优先级最高(实得 %s)" % ReclaimRules.reject_reason(false, true, true, true))

	_chk(ReclaimRules.reject_reason(true, false, true, true) == "尚未开局",
			"host 未就绪必须拒绝(旧的 _host == null 分支;实得 %s)"
			% ReclaimRules.reject_reason(true, false, true, true))

	_chk(ReclaimRules.reject_reason(true, true, false, true) == "该 role 不在宽限期"
			and ReclaimRules.reject_reason(true, true, false, false) == "该 role 不在宽限期",
			"不在宽限期必须拒绝且理由排在令牌之前(实得 %s / %s)" % [
				ReclaimRules.reject_reason(true, true, false, true),
				ReclaimRules.reject_reason(true, true, false, false)])

	_chk(ReclaimRules.reject_reason(true, true, true, false) == "令牌不匹配"
			and not ReclaimRules.token_matches("", "")
			and not ReclaimRules.token_matches("tok", "")
			and not ReclaimRules.token_matches("tok", "other")
			and ReclaimRules.token_matches("tok", "tok"),
			"令牌空 / 不符必须拒绝,只有非空且相等才匹配")

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
