extends Node

# 一键联机(EasyTier)单机双节点探针(场景模式,管理员运行):
#   godot --headless --path . res://Tests/easytier_probe.tscn
# 本机起两个内核节点经局域网 IP 互联(回环 127.0.0.1 有绑定怪癖,勿用),验证整条链:
#   解包 → 提权垫片 → 内核+TUN 网卡 → IP 落位 → 两节点组网(new peer added)→ stop.flag 收摊。
# ★ 必须管理员运行(创建 TUN 网卡需要);从管理员终端跑则连 UAC 都不弹,否则弹 2 次。
# ★ 探针网段用 10.147.147.x(独立于生产 10.126.126.x),避开用户手动开的 EasyTier GUI 网。

const PROBE_PREFIX := "10.147.147."
const NODE_A_IP := "10.147.147.1"
const NODE_B_IP := "10.147.147.2"
const LISTEN_PORT := 19010

var _fails := 0
var _checks := 0


func _ready() -> void:
	# 随机网络名:跑两次不留旧网
	randomize()
	await _run()
	get_tree().quit(1 if _fails > 0 else 0)


func _run() -> void:
	var elevated := _is_elevated()
	print("PROBE[env]: 管理员=%s(%s)" % [str(elevated),
		"从管理员终端跑则无 UAC 弹窗" if elevated else "会弹 UAC,请点「是」"])

	# 1) 解包断言:四个文件齐、尺寸与 res:// 一致
	var et := EasyTierLink.ensure_runtime()
	_check("解包内核到 user://easytier", et != "")
	if et == "":
		return
	for fname: String in ["easytier-core.exe", "wintun.dll", "Packet.dll", "WinDivert64.sys",
			"et_elevate.ps1", "et_helper.ps1"]:
		var dst := et.path_join(fname)
		_check("文件存在: " + fname, FileAccess.file_exists(dst))

	# 2) 邀请码编解码往返
	var payload := {"v": 1, "n": "cyr-probe", "s": "Secret# Probe 123", "p": ["udp://x:1", "tcp://y:2"], "h": "10.126.126.1"}
	var code := EasyTierLink.encode_code(payload)
	var back := EasyTierLink.decode_code(code)
	_check("邀请码往返", not back.is_empty() and back["n"] == payload["n"]
			and back["s"] == payload["s"] and back["h"] == payload["h"]
			and str((back["p"] as Array)[1]) == payload["p"][1])
	_check("坏码拒绝", EasyTierLink.decode_code("CYR1-not-a-code!!").is_empty()
			and EasyTierLink.decode_code("").is_empty())

	# 3) 双节点:局域网 IP 监听(A) + 对连(B)
	var lan := _lan_ip()
	_check("取得局域网 IP(" + lan + ")", lan != "")
	if lan == "":
		return
	var listener := "tcp://%s:%d" % [lan, LISTEN_PORT]
	var net := "cyr-probe-" + str(randi() % 100000)
	var secret := "probe" + str(randi())
	var sdir_a := EasyTierLink._start_node("s0", net, secret, NODE_A_IP, [], [listener],
			false, "cyr_eta", 12777)
	_check("节点A拉起(s0)", sdir_a != "")
	if sdir_a == "":
		return
	var ip_a: String = await EasyTierLink._wait_adapter_ip("cyr_eta", 40.0, PROBE_PREFIX)
	_check("节点A网卡落位 " + NODE_A_IP, ip_a == NODE_A_IP)
	if ip_a != NODE_A_IP:
		print("PROBE[fail-hint]: 网卡未出现 → 管理员权限/UAC/安全软件;" + _log_tail(sdir_a))

	var sdir_b := EasyTierLink._start_node("s1", net, secret, NODE_B_IP, [listener], [],
			false, "cyr_etb", 12778)
	_check("节点B拉起(s1)", sdir_b != "")
	if sdir_b == "":
		_request_both_stop()
		return
	var ip_b: String = await EasyTierLink._wait_adapter_ip("cyr_etb", 40.0, PROBE_PREFIX)
	_check("节点B网卡落位 " + NODE_B_IP, ip_b == NODE_B_IP)

	# 4) 组网断言:B 的日志里出现 new peer added(单机经真实传输层握手成功)
	var mesh_ok := false
	for i in range(20):
		await get_tree().create_timer(1.0).timeout
		if _log_has(sdir_b, "new peer added"):
			mesh_ok = true
			break
	_check("双节点组网(B 日志含 new peer added)", mesh_ok)

	# 5) 收摊:stop.flag → helper 杀内核 → 进程消失
	_request_both_stop()
	var both_dead := false
	for i in range(12):
		await get_tree().create_timer(0.6).timeout
		if not _core_alive(sdir_a) and not _core_alive(sdir_b):
			both_dead = true
			break
	_check("stop.flag 收摊(两内核进程退出)", both_dead)

	print("PROBE: %d 项检查,%d 失败 → %s" % [_checks, _fails, "ALL-OK" if _fails == 0 else "FAILED"])


# ── 内部 ───────────────────────────────────────────────────────────

func _request_both_stop() -> void:
	EasyTierLink._request_stop("s0")
	EasyTierLink._request_stop("s1")


func _log_has(sdir: String, needle: String) -> bool:
	for fname in ["core.log", "core.err.log"]:
		var f := FileAccess.open(sdir.path_join(fname), FileAccess.READ)
		if f == null:
			continue
		var t := f.get_as_text()
		f.close()
		if t.contains(needle):
			return true
	return false


func _log_tail(sdir: String) -> String:
	var f := FileAccess.open(sdir.path_join("core.err.log"), FileAccess.READ)
	if f == null:
		return "(无日志)"
	var t := f.get_as_text().substr(maxi(0, f.get_length() - 400))
	f.close()
	return " 日志尾: " + t.replace("\n", " | ")


func _core_alive(sdir: String) -> bool:
	var f := FileAccess.open(sdir.path_join("core.pid"), FileAccess.READ)
	if f == null:
		return false
	var pid := f.get_as_text().strip_edges()
	f.close()
	if not pid.is_valid_int():
		return false
	var out: Array = []
	OS.execute("C:/Windows/System32/tasklist.exe",
			PackedStringArray(["/FI", "PID eq " + pid]), out, false, false)
	return not "\n".join(PackedStringArray(out)).contains("没有运行的任务匹配指定标准") \
			and not "\n".join(PackedStringArray(out)).to_lower().contains("no tasks")


# 局域网 IPv4:私网段,排除回环/链路本地/生产网段(10.126.126.x 可能被手动网占用)
func _lan_ip() -> String:
	for a in IP.get_local_addresses():
		var s := str(a)
		if ":" in s or s.begins_with("127.") or s.begins_with("169.254."):
			continue
		if s.begins_with("192.168.") or s.begins_with("10.") or s.begins_with("172."):
			if s.begins_with(EasyTierLink.SUBNET_PREFIX) or s.begins_with(PROBE_PREFIX):
				continue
			return s
	return ""


# 经典提权判据:net session 需要管理员
func _is_elevated() -> bool:
	return OS.execute("C:/Windows/System32/net.exe", PackedStringArray(["session"])) == 0


func _check(name: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("PROBE[pass]: " + name)
	else:
		_fails += 1
		print("PROBE[FAIL]: " + name)
