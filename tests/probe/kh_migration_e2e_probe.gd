extends Node

# ═══ 迁移后的端到端真链路冒烟(场景模式;必须用场景模式 —— 本链路全程吃 autoload)═══
#
# 跑法:
#   "$GODOT" --headless --path . --quit-after 3600 res://tests/kh_migration_e2e_probe.tscn
# 判据:末行 `MIGRATION E2E: ALL-OK`。
#
# ═══ 为什么单独写一支(与 netplay_probe 的分工)═══
# `tests/netplay_probe.gd` 是 `-s`,只覆盖**纯逻辑**(房间码生成/凭据派生/hostname 切端口/peer JSON 解析)。
# 本支补的是**真进程**那一段 —— 也就是"移植到 KH 基线之后还走不走得通"这个问题的真正答案:
#   ① 房主:启动真 `Cyancular Ruins Server.exe --port P` → 存活探测连上
#   ② 房主:在同一连接上 `create_room` → 拿到 5 位房间码
#   ③ 房主:按房间码起真 EasyTier 隧道(`--no-tun`)→ 等自己的 RPC 门户就绪
#   ④ 收摊:停隧道 + 停本机服务端(不留残留进程)
# 这四步就是「建房」按钮背后的全部内容;它们绿 = 单进程单端口 + no-tun 隧道在 KH 基线上成立。
#
# ⚠ 前提:仓库根要有 `Cyancular Ruins Server.exe` 与 EasyTier 四件套
#   (前者由 tools/build_release.py 导出;后者见 tools/fetch_easytier.py)。
#   缺了本支会明确报"缺哪个",不是静默跳过。

const LocalServer := preload("res://core/net/local_server.gd")
const Tunnel := preload("res://core/net/tunnel.gd")

var _fails: Array[String] = []
var _port := -1
var _code := ""


func _check(cond: bool, what: String) -> void:
	print(("  [OK] " if cond else "  [FAIL] ") + what)
	if not cond:
		_fails.append(what)


func _ready() -> void:
	print("═══ MIGRATION E2E(真链路)═══")
	print("服务端 exe: ", LocalServer.find_server_exe())
	print("隧道可用: ", Tunnel.available(), " / 初始节点: ", Tunnel.has_initial_peers())

	_check(not LocalServer.find_server_exe().is_empty(),
			"找得到同目录的 %s" % LocalServer.SERVER_EXE)
	_check(Tunnel.available(), "EasyTier 四件套齐(core/cli/Packet/wintun)")
	if not _fails.is_empty():
		_finish()
		return

	# ① 启动真服务端 + 存活探测(这一步内部就建好了连接)
	_port = await LocalServer.launch_and_connect()
	_check(_port > 0, "launch_and_connect() 拿到端口(实得 %d)" % _port)
	_check(NetBus.can_send_to_server(), "探活之后 ENet 连接真的可用")
	if _fails.size() > 0:
		_finish()
		return

	# ② 同一连接上建房 → 拿房间码
	var got := [false]
	NetBus.local_room_created.connect(func(c: String) -> void:
		_code = c
		got[0] = true)
	NetBus.rpc_id(1, "create_room")
	for i in range(200):
		await get_tree().process_frame
		if got[0]:
			break
	_check(got[0], "create_room 得到应答")
	_check(Tunnel.is_valid_room(_code), "房间码是 5 位数字(实得 \"%s\")" % _code)

	# ③ 按码起真隧道(房主侧)。`start_host()` 返回 bool,`wait_ready()` 等 RPC 门户。
	var ok: bool = Tunnel.start_host(_port, _code)
	_check(ok, "Tunnel.start_host() 起内核成功")
	if ok:
		var ready: bool = await Tunnel.wait_ready()
		_check(ready, "隧道 RPC 门户就绪(wait_ready)")
		_check(Tunnel.is_running(), "隧道自报在跑")

	# ④ 收摊
	Tunnel.stop()
	LocalServer.stop_owned()
	await get_tree().create_timer(1.0).timeout
	_check(not Tunnel.is_running(), "stop() 之后隧道不再在跑")
	_finish()


func _finish() -> void:
	print("MIGRATION E2E: %s" % ("ALL-OK" if _fails.is_empty() else "FAIL | %d 条: %s"
			% [_fails.size(), "; ".join(_fails)]))
	get_tree().quit(1 if not _fails.is_empty() else 0)
