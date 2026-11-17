extends SceneTree

const EXPECTED_CHECKS := 5

const UDP_LINE := "  UDP    0.0.0.0:7777         *:*                                    1234  "
const UDP_LINE_V6 := "  UDP    [::]:7777            *:*                                    4321  "
const TCP_LINE := "  TCP    0.0.0.0:7777        0.0.0.0:0       LISTENING       5678  "
const TCP_REMOTE := "  TCP    10.0.0.5:50123       10.1.2.3:7777    ESTABLISHED     6789  "

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	_chk(ProcUtil._pid_of_udp_line(UDP_LINE, 7777) == 1234
			and ProcUtil._pid_of_udp_line(UDP_LINE_V6, 7777) == 4321,
			"netstat 的 UDP 行(4 列,IPv4/IPv6)必须解析出属主 pid")

	# ── ② TCP 行不得命中:UDP 端口探测只看 UDP(否则「本机客户端连着远端 7777」会假报"端口被占")──
	# 去掉什么才红:删 `cols[0] != "UDP"` 判据 ⇒ 这条红。
	_chk(ProcUtil._pid_of_udp_line(TCP_LINE, 7777) == -1
			and ProcUtil._pid_of_udp_line(TCP_REMOTE, 7777) == -1,
			"TCP 行(TCP LISTENING / 对端 7777)不算 UDP 端口属主")

	var addr_line := "  UDP    0.0.0.0:17777        *:*                                    9999  "
	_chk(ProcUtil._pid_of_udp_line(addr_line, 7777) == -1,
			":17777 不得被当成 :7777(端口按冒号后整段解析,不做前缀匹配)")

	var c_bad := ModeContext.from_args(PackedStringArray(["--worker", "--port", "abc"]), 7777)
	var c_missing := ModeContext.from_args(PackedStringArray(["--worker", "--port"]), 7777)
	var c_zero := ModeContext.from_args(PackedStringArray(["--worker", "--port", "0"]), 7777)
	var c_big := ModeContext.from_args(PackedStringArray(["--worker", "--port", "70000"]), 7777)
	_chk(not bool(c_bad["ok"]) and not bool(c_missing["ok"])
			and not bool(c_zero["ok"]) and not bool(c_big["ok"]),
			"--port 非整数 / 缺值 / 0 / 70000 都必须 ok=false(拒绝启动)")

	var c_ok := ModeContext.from_args(PackedStringArray(["--worker", "--port", "8123"]), 7777)
	_chk(bool(c_ok["ok"]) and int(c_ok["port"]) == 8123 and (c_ok["roles"] as Array) == [1, 2],
			"合法 --port 8123 原样进 ctx,且 1v1 的 role 兜底 [1, 2] 不受影响")

	# 判词:计数闸(条数不符也红 —— 防断言被静默跳过)
	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("NET ARGV OK(%d 条断言):UDP 行解析 · TCP 不误命中 · 端口整段匹配 · --port 校验" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("NET ARGV FAILED: %d 处" % _fails.size())
		quit(1)
