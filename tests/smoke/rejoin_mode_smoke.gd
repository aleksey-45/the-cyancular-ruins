extends SceneTree
# 回局凭据模式维度守卫(BUG-14:三张注册表房号空间重叠 ⇒ 只比房间号会让持 3v3 凭据的玩家

const EXPECTED_CHECKS := 4

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	var r := RejoinRegistry.new()
	r.grant("tk", "1234", 1, 7800, 4242, 1000, "team")
	var e := r.lookup("tk", 1000)

	# ① 凭据里存了 mode;同模式放行(去掉 grant 的 mode ⇒ mode 读成空串,这里红)
	_chk(str(e.get("mode", "")) == "team" and RejoinRegistry.decision(e, "1234", true, "team") == "",
			"凭据必须带 mode;同模式回局放行")

	# ② 同号跨模式必须拒绝(去掉 decision 的 mode 比较 ⇒ 放行,红)
	_chk(RejoinRegistry.decision(e, "1234", true, "royale") != "",
			"同号跨模式必须拒绝(否则点别的模式的同号房会被放行)")

	# ③ 列表过滤同样按(房间号, 模式):去掉 owns 的 mode 比较 ⇒ royale 侧误判为自己那间,红
	_chk(r.owns("tk", "1234", 1000, "team") and not r.owns("tk", "1234", 1000, "royale"),
			"owns 必须按(房间号, 模式)判 —— 跨模式同号不进列表")

	# ④ 回归:同模式下原有的三条判据不变(worker 死活 / TTL 过期 / 房号不符)
	var r2 := RejoinRegistry.new()
	r2.grant("t2", "9", 2, 7801, 1, 1000, "pvp")
	var e2 := r2.lookup("t2", 1000)
	_chk(RejoinRegistry.decision(e2, "9", false, "pvp") == "对局已结束"
			and RejoinRegistry.decision(e2, "8", true, "pvp") == "房间号与凭据不符"
			and r2.lookup("t2", 1000000000).is_empty(),
			"同模式下:worker 死 / 房号不符 / TTL 过期三条判据不回归")

	# 判词:计数闸(条数不符也红 —— 防断言被静默跳过)
	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("REJOIN MODE OK(%d 条断言):凭据带 mode · 跨模式拒绝 · 列表过滤按模式 · 原有判据不回归" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("REJOIN MODE FAILED: %d 处" % _fails.size())
		quit(1)