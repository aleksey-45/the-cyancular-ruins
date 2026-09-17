extends SceneTree

# 重连协议的**源码级**契约冒烟:
#   ① 三条新 RPC 必须住在 NetBusExt,**且 NetBus 里一个都不许有**(放错节点 = 静默 no-op)
#   ② PvpSession 的两个新字段在位(重连要靠它们)
# 跑法: timeout 60 "$GODOT" --headless --path . -s res://tests/reconnect_smoke.gd
# 通过 = `RECONNECT SMOKE OK` 退出 0。
#
# ═══ 为什么是源码级 ═══
# ★ RPC 放错节点**不会报错**:原 NetBus 与原版服务端逐字节一致是硬纪律,而 NetBusExt 对
#   原版 worker 不存在 → 放错的 RPC 静默丢弃、优雅降级。症状是"重连永远失败"却一行错都不打。
#   同款先例:weapon_spawned/weapon_removed 的 node 归属由 tests/net_ground_probe 双向钉住
#   (**缺了要红、多了也要红**)。这里照抄那条纪律。

const NETBUS := "res://core/net/net_bus.gd"
const NETBUS_EXT := "res://core/net/net_bus_ext.gd"
const SESSION := "res://core/net/pvp_session.gd"

# 本次新增的三条:必须在 Ext,不得在 NetBus
const N_EXT_RPCS := ["session_token", "report_token", "reclaim_role"]

var _fail := 0


func _check(ok: bool, msg: String) -> void:
	if ok:
		return
	_fail += 1
	print("[FAIL] ", msg)


func _read(path: String) -> String:
	return FileAccess.get_file_as_string(path)


# 剥掉 `#` 注释与字符串外的空白,只留代码本体 —— 否则注释里提到的方法名会假绿
func _code(text: String) -> String:
	var out := ""
	for line in text.split("\n"):
		var i := line.find("#")
		out += (line if i < 0 else line.substr(0, i)) + "\n"
	return out


# 该文件里有没有 `func <name>(` 定义
func _defines(code: String, name: String) -> bool:
	return code.contains("func %s(" % name)


func _initialize() -> void:
	var ext := _code(_read(NETBUS_EXT))
	var bus := _code(_read(NETBUS))
	var ses := _code(_read(SESSION))
	_check(not ext.is_empty(), "读不到 %s" % NETBUS_EXT)
	_check(not bus.is_empty(), "读不到 %s" % NETBUS)
	_check(not ses.is_empty(), "读不到 %s" % SESSION)

	for n in N_EXT_RPCS:
		_check(_defines(ext, n), "★ `%s` 必须定义在 NetBusExt(放别处 = 静默 no-op)" % n)
		_check(not _defines(bus, n),
				"★ `%s` **不得**出现在 NetBus(改它的方法表会让与原版服务端的 RPC 全部失联)" % n)

	# 三个信号也要在(worker/客户端都靠信号解耦)
	for s in ["local_session_token", "token_reported", "reclaim_requested"]:
		_check(ext.contains("signal " + s), "NetBusExt 缺信号 %s" % s)

	# PvpSession 两个字段:必须 `static var`(本类全是静态)
	for f in ["token", "worker_port"]:
		_check(ses.contains("static var %s" % f), "PvpSession 缺 `static var %s`" % f)

	if _fail == 0:
		print("RECONNECT SMOKE OK")
		quit(0)
	else:
		print("RECONNECT SMOKE FAILED: %d" % _fail)
		quit(1)
