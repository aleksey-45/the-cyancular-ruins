extends SceneTree

# ModeContext 守卫:worker argv 解析与三条启动校验(互斥 / roles-teams 等长 / role 上界)。
# 通过 = MODE CONTEXT OK(n 条断言);判据 grep 文本。
# ★ 去掉什么才会红:
#   ① 把 role 上界改回字面量 8 ⇒ ③ 红(16 人房第 9 号被丢 = X1 回归);
#   ② 把越界改回"静默丢" ⇒ ④ 红;
#   ③ 去掉互斥/等长校验 ⇒ ①/② 红。
# ⚠ -s 脚本套外层 timeout。

const EXPECTED_CHECKS := 9

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _ctx(argv: Array) -> Dictionary:
	return ModeContext.from_args(PackedStringArray(argv))


func _initialize() -> void:
	# ① 模式互斥:--royale + --team 必须拒启动
	var a := _ctx(["--worker", "--royale", "--team", "--roles", "1,2"])
	_chk(not bool(a["ok"]) and str(a["error"]).contains("互斥"), "--royale 与 --team 同时为真必须拒启动")

	# ② 3v3:--roles 与 --teams 不等长必须拒启动
	var b := _ctx(["--worker", "--team", "--roles", "1,2", "--teams", "1"])
	_chk(not bool(b["ok"]) and str(b["error"]).contains("等长"), "3v3 的 --roles 与 --teams 不等长必须拒启动")

	# ③ X1 回归:role 16 必须被保留(旧实现是 <=8)
	var roles16: Array = []
	for i in range(1, 17):
		roles16.append(str(i))
	var c := _ctx(["--worker", "--royale", "--roles", ",".join(roles16)])
	_chk(bool(c["ok"]) and (c["roles"] as Array).size() == 16 and int((c["roles"] as Array)[15]) == 16,
			"role 16 必须保留(16 人上限;旧实现静默丢 9~16)")

	# ④ 越界必须**报错**,不许静默丢
	var d := _ctx(["--worker", "--royale", "--roles", "0,17"])
	_chk(not bool(d["ok"]) and str(d["error"]).contains("越界"), "role 0/17 必须报错而不是静默丢")

	# ⑤ 1v1 手工兜底:无 --roles 且非 royale/team ⇒ [1,2]
	var e := _ctx(["--worker"])
	_chk(bool(e["ok"]) and bool(e["worker"]) and (e["roles"] as Array) == [1, 2],
			"1v1 worker 无 --roles 时必须兜底 [1,2]")

	# ⑥ 3v3 队伍表:同序配对
	var f := _ctx(["--worker", "--team", "--roles", "1,2,3,4,5,6", "--teams", "1,1,1,2,2,2"])
	_chk(bool(f["ok"]) and (f["team_of"] as Dictionary) == {1: 1, 2: 1, 3: 1, 4: 2, 5: 2, 6: 2},
			"3v3 team_of 必须按 --roles/--teams 同序配对")

	# ⑦ ai role 上界同样放宽到 ROLE_MAX
	var g := _ctx(["--worker", "--royale", "--roles", "1,2", "--ai-roles", "9,10"])
	_chk(bool(g["ok"]) and (g["ai_roles"] as Array) == [9, 10], "AI role 9/10 必须保留(与 --roles 同界)")

	# ⑧ --port 解析 + 默认值
	var h := _ctx(["--worker", "--port", "7999"])
	_chk(int(h["port"]) == 7999 and int(_ctx(["--worker"])["port"]) == 7777,
			"--port 必须生效;缺省必须回 default_port")

	# ⑨ 大厅(非 worker)不校验这些,也不把 worker 置真
	var i := _ctx(["--royale", "--roles", "1,2"])
	_chk(not bool(i["worker"]) and bool(i["ok"]), "大厅分支不校验 worker 参数")

	if _checks < EXPECTED_CHECKS:
		_fails.append("断言条数不足(%d/%d)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("MODE CONTEXT OK(%d 条断言)" % _checks)
	else:
		for f2 in _fails:
			print("  FAIL %s" % f2)
		print("MODE CONTEXT FAIL(%d/%d)" % [_fails.size(), _checks])
	quit(0)
