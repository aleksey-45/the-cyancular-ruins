extends SceneTree

# 重连协议的**源码级**契约冒烟:
#   ① 三条新 RPC 必须住在 NetBusExt,**且 NetBus 里一个都不许有**(放错节点 = 静默 no-op)
#   ② 三者的 **@rpc 注解**必须逐字正确(注解错了 = RPC 静默不通,与放错节点同款静默)
#   ③ PvpSession 的两个新字段在位(重连要靠它们)
#   ④ `reset()` 必须把这两个字段一起清掉(否则换模式带着上一局的 token)
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

# 这三条各自的 @rpc 注解(**逐字**要求)—— 决定它能不能被路由的那一行。
# ★ 节点归属对了、注解错了,冒烟照样恒绿而功能坏掉:
#   `report_token` 若写成 `authority`,客户端上行会被直接拒(authority = 只许服务器调),
#   症状是"重连时 token 永远报不上去"且一行错都不打 —— 正是本文件要拦的那类静默 no-op。
#   session_token 反向同理:写成 any_peer = 任何人都能伪造 token 下发。
const N_EXT_RPC_ANN := {
	"session_token": "@rpc(\"authority\", \"reliable\")",
	"report_token": "@rpc(\"any_peer\", \"reliable\")",
	"reclaim_role": "@rpc(\"any_peer\", \"reliable\")",
}

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


# `func <name>(` **上方紧邻的非空行** = 它的注解。
# 注解与 func 之间可能夹空行/注释行(注释行已被 `_code` 打成空行),故向前跳过空行。
# 若这行注解被删掉,返回的就是上一行的代码文本 —— 与期望串不等,照样红(不是静默恒绿)。
func _rpc_ann(code: String, name: String) -> String:
	var lines := code.split("\n")
	for i in lines.size():
		if lines[i].strip_edges().begins_with("func %s(" % name):
			var j := i - 1
			while j >= 0 and lines[j].strip_edges().is_empty():
				j -= 1
			return lines[j].strip_edges() if j >= 0 else ""
	return ""


# 某个 func 的函数体(到下一个顶层 `func ` 为止;照 ScanUtil.func_body 的形状)
func _func_body(code: String, name: String) -> String:
	var i := code.find("func %s(" % name)
	if i < 0:
		return ""
	var j := code.find("\nfunc ", i + 1)
	return code.substr(i, (j - i) if j > 0 else code.length() - i)


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

	# ★ 注解:节点归属对了还不够 —— 决定 RPC 能不能被路由的就是这一行
	for n in N_EXT_RPC_ANN:
		var ann := _rpc_ann(ext, n)
		_check(ann == N_EXT_RPC_ANN[n],
				"★ `%s` 的 @rpc 注解必须逐字是 `%s`,实为 `%s`(注解错了 = RPC 静默不通)" %
				[n, N_EXT_RPC_ANN[n], ann])

	# PvpSession 两个字段:必须 `static var`(本类全是静态)
	for f in ["token", "worker_port"]:
		_check(ses.contains("static var %s" % f), "PvpSession 缺 `static var %s`" % f)

	# ★ 光有字段还不够:`reset()` 必须把这两个一起清掉,否则**换模式时带着上一局的 token**
	#   (静默陈旧态,本仓最在意的那类 bug)。同款先例 = kh_l1_probe:80-84 钉的
	#   "reset() 未清 map_path";照它的形状写。
	var reset_body := _func_body(ses, "reset")
	_check(not reset_body.is_empty(), "PvpSession 里找不到 func reset()")
	_check(reset_body.contains("token = \"\""),
			"★ PvpSession.reset() 未清 token(换模式会带着上一局的 token 去连)")
	_check(reset_body.contains("worker_port = 0"),
			"★ PvpSession.reset() 未清 worker_port(重连会拿着上一局的端口直连)")

	if _fail == 0:
		print("RECONNECT SMOKE OK")
		quit(0)
	else:
		print("RECONNECT SMOKE FAILED: %d" % _fail)
		quit(1)
