extends SceneTree
# 端口解析守卫(netstat 行解析 + `--port` 启动参数校验)。存在理由(逐条对应真实缺陷):
#   ① `local_server._pids_on_port`(2026-10-30 已删)按 `cols.size() >= 5` 判 netstat 行 —— 而 **UDP 行只有 4 列**
#      (`UDP 0.0.0.0:7777 *:* 1234`,没有 State 列)⇒ 对 UDP 恒假:「重启本机服务器」的残留清理是空操作、
#      就绪轮询恒不成立(用户侧 = 服务器起不来)。同时 `line.contains(":7777 ")` 会命中 TCP 行的**对端**地址。
#   ② `--port` 旧实现直接 `int(args[i+1])`:`--port abc` ⇒ 0 ⇒ ENet `create_server(0)` 绑随机端口并成功
#      ⇒ worker 打印"就绪"却占一个找不到的端口,靠 30 秒报到梯才退。
# 跑法:"$GODOT" --headless --path . -s res://tests/smoke/net_argv_port_smoke.gd;通过 = "NET ARGV OK(n 条断言)"。

const EXPECTED_CHECKS := 5

# 与真机 `netstat -ano` 逐字同形(空格数不必精确 —— 解析用 split 空白的写法)。
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
	# ── ① UDP 行(含 IPv4/IPv6):必须取到最后一列的 pid ──
	# 去掉什么才红:把 `_pid_of_udp_line` 的列数判据改回 `>= 5`(UDP 只有 4 列)⇒ 这条红。
	_chk(ProcUtil._pid_of_udp_line(UDP_LINE, 7777) == 1234
			and ProcUtil._pid_of_udp_line(UDP_LINE_V6, 7777) == 4321,
			"netstat 的 UDP 行(4 列,IPv4/IPv6)必须解析出属主 pid")

	# ── ② TCP 行不得命中:UDP 端口探测只看 UDP(否则「本机客户端连着远端 7777」会假报"端口被占")──
	# 去掉什么才红:删 `cols[0] != "UDP"` 判据 ⇒ 这条红。
	_chk(ProcUtil._pid_of_udp_line(TCP_LINE, 7777) == -1
			and ProcUtil._pid_of_udp_line(TCP_REMOTE, 7777) == -1,
			"TCP 行(TCP LISTENING / 对端 7777)不算 UDP 端口属主")

	# ── ③ 端口必须按"冒号后整段"比,不能前缀匹配 ──
	# 去掉什么才红:把 `_addr_has_port` 改回 `addr.contains(":" + str(port))` ⇒ `:17777` 会命中 ⇒ 这条红。
	var addr_line := "  UDP    0.0.0.0:17777        *:*                                    9999  "
	_chk(ProcUtil._pid_of_udp_line(addr_line, 7777) == -1,
			":17777 不得被当成 :7777(端口按冒号后整段解析,不做前缀匹配)")

	# ── ④ `--port` 非法值一律拒绝启动(非法 token / 缺值 / 越界)──
	# 去掉什么才红:把 `_parse_port` 换回 `ctx["port"] = int(args[i + 1])` ⇒ `--port abc` 的 ok 变 true ⇒ 这条红。
	var c_bad := ModeContext.from_args(PackedStringArray(["--worker", "--port", "abc"]), 7777)
	var c_missing := ModeContext.from_args(PackedStringArray(["--worker", "--port"]), 7777)
	var c_zero := ModeContext.from_args(PackedStringArray(["--worker", "--port", "0"]), 7777)
	var c_big := ModeContext.from_args(PackedStringArray(["--worker", "--port", "70000"]), 7777)
	_chk(not bool(c_bad["ok"]) and not bool(c_missing["ok"])
			and not bool(c_zero["ok"]) and not bool(c_big["ok"]),
			"--port 非整数 / 缺值 / 0 / 70000 都必须 ok=false(拒绝启动)")

	# ── ⑤ 合法 `--port` 原样进 ctx,且不误伤 1v1 的默认 role 兜底 ──
	# 去掉什么才红:改 `_parse_port` 不写 ctx["port"] ⇒ 端口回落 7777 ⇒ 这条红。
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
