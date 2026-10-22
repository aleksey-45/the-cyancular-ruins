extends SceneTree

# NetDiag(结构化诊断,--diag)的最小守卫。
# 通过 = NET DIAG OK(n 条断言);判据 grep 文本,不看退出码。
#
# ★ 为什么这一支值得存在(去掉什么才会红):这一层写坏**不报错**。最危险的两种形态:
#   ① **默认关却没关住** —— 生产每次启动都落盘,玩家机器上堆日志;写坏时表现为卡顿,而不是任何报错。
#      「去掉 enabled() 那道早退」⇒ ①(默认关)红;
#   ② **开了但写出来的行不是合法 JSON** —— 事后拿它排障的人 parse 失败,等于白开。
#      「去掉 store_line 的 JSON.stringify 外壳(改成拼字符串)」⇒ ②(JSON 往返)红。
# ★ 测不到什么:真实对局里的事件**内容**是否正确(那是各调用点的责任,见 hooks 的注释);
#   跨进程时间对齐(各进程 t 是各自单调时钟,只能按事件对齐,不能相减)。
# ⚠ -s 脚本一旦解析/运行出错就走不到 quit()、进程永久挂起 ⇒ 跑它一律套外层 timeout。

const EXPECTED_CHECKS := 8

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	var path := ProjectSettings.globalize_path("user://net_diag_smoke/diag_test.jsonl")
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

	# ── ① 默认关:一行都不写、不建文件 ──
	_chk(not NetDiag.enabled(), "默认关(未带 --diag 时 enabled() 必须为 false)")
	NetDiag.log_event("should_be_dropped", {"x": 1})
	_chk(NetDiag.file_path() == "" and NetDiag.count() == 0, "未开启时不得建文件 / 不得计数")

	# ── ② 开启后:session_start + 一条业务事件,且是合法 JSON ──
	NetDiag.begin_for_test(path)
	NetDiag.log_event("probe", {"i": 7, "s": "甲乙", "f": 1.5, "arr": [1, 2], "nested": {"ok": true}})
	NetDiag.flush()
	_chk(FileAccess.file_exists(NetDiag.file_path()), "开启后必须落盘")
	var lines := FileAccess.get_file_as_string(NetDiag.file_path()).split("\n", false)
	_chk(lines.size() >= 2, "至少 session_start + probe 两行")
	var first: Dictionary = JSON.parse_string(lines[0])
	_chk(first.get("event") == "session_start" and first.has("t") and first.has("pid") and first.has("role"),
			"session_start 行必须带 t / pid / role")
	var last: Dictionary = JSON.parse_string(lines[lines.size() - 1])
	_chk(last.get("event") == "probe" and int(last["data"]["i"]) == 7 and str(last["data"]["s"]) == "甲乙"
			and bool(last["data"]["nested"]["ok"]), "data 必须原样往返(含中文 / 嵌套)")

	# ── ③ urgent:不等 close/flush 也要能立刻读到 ──
	NetDiag.log_event("urgent", {"why": "crash"}, true)
	var tail := FileAccess.get_file_as_string(NetDiag.file_path()).split("\n", false)
	var urgent: Dictionary = JSON.parse_string(tail[tail.size() - 1])
	_chk(urgent.get("event") == "urgent" and int(NetDiag.count()) == 2, "urgent 立即落盘 + 计数只数业务事件")

	NetDiag.end_for_test()
	_chk(NetDiag.file_path() == "", "end_for_test 后必须清空路径(不再写)")

	# ── 判词 ──
	if _checks < EXPECTED_CHECKS:
		_fails.append("断言条数不足(%d/%d):脚本可能中途返回" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("NET DIAG OK(%d 条断言)" % _checks)
	else:
		for f in _fails:
			print("  FAIL %s" % f)
		print("NET DIAG FAIL(%d/%d)" % [_fails.size(), _checks])
	quit(0)
