class_name EasyTierLink
extends RefCounted

# 一键联机的 EasyTier 内核链路(P1,2026-09-28)。零 autoload、零场景依赖,`-s` 探针可直接用。
#
# ★ 分工(与 MCTier/陶瓦联机同款思路,代码无关):
#   - 本类只管"虚拟网卡起没起、邀请码编解码、内核子进程的生与死"。
#   - 提权/防火墙在 `tools/easytier/et_elevate.ps1` + `et_helper.ps1`(纯 ASCII,见 AGENTS.md 编码纪律):
#     游戏本体**不提权**;helper 经 UAC 拉起内核并守护——stop.flag / 游戏退出 / 内核死亡,三者任一即收摊。
#   - 游戏服务器(同目录 Server.exe)的启停仍归 `LocalServer`,本类不碰。
#
# ★ 运行期布局(user:// 下,导出包里 res://tools/easytier/* 是原样只读的,必须先解出来才能执行):
#   user://easytier/easytier-core.exe + wintun.dll + 两个 ps1   ← 二进制,按尺寸变化才重写
#   user://easytier/<会话>/session.json|core.log|core.err.log|core.pid|stop.flag
#   生产固定用 s0;探针用 s0/s1 起双节点(单机自测组网,免第二台机器)。
#
# ★ 地址约定:EasyTier 默认 DHCP 池就是 10.126.126.0/24(MCTier 同款),房主手动固定 .1、
#   朋友 --dhcp 自动取号,落在同一网段。启动前预检"**别的**网卡已占本网段"(用户手动开的
#   EasyTier GUI/MCTier 常驻 10.126.126.1)→ 直接报错请用户先停旧网,别让两张网卡撞同 IP。
#
# ★ 会合节点:官方公共节点域名 public.easytier.top 实测**不存在**(NXDOMAIN,别再用);
#   默认双协议回落海波公共节点 us01.225284.xyz:11010(udp+tcp,2026-09-28 实测可达,MCTier 默认节点)。
#   邀请码里带节点列表 → 朋友零配置。自建会合点一条命令即可,见 AGENTS.md。

const DEV_NAME := "cyr_et"           # 生产网卡名(探针传自己的);ipconfig 里按它找段
const SUBNET_PREFIX := "10.126.126." # 生产网段前缀(EasyTier 默认 DHCP 池)
const HOST_IP := "10.126.126.1"      # 房主固定 IP → 朋友的「服务器地址」永不变
const DEFAULT_PEERS: Array[String] = [
	"udp://us01.225284.xyz:11010",
	"tcp://us01.225284.xyz:11010",
]
const CODE_PREFIX := "CYR1-"
const ET_RES_DIR := "res://tools/easytier"
const SYS32 := "C:/Windows/System32"
const RPC_PORT := 12777              # 内核 RPC 门户(错开默认 15888,防与用户自开的 EasyTier 撞)
const START_TIMEOUT := 60.0          # 含 UAC 用户反应时间的总超时(秒)
const DHCP_TIMEOUT := 25.0           # 朋友 --dhcp 等号时长;超时改随机手动 IP 重试
const RANDOM_CHARS := "abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789"

static var _active := false          # 本会话是否已拉起过生产内核(s0)
static var _my_ip := ""              # 生产网卡当前 IP(空=没起来)
static var _code := ""               # 房主邀请码(重复点「一键开网」时复用,不换网)


## ── 对外三口(房主 / 加入 / 停)────────────────────────────────────────

## 房主:建网(随机网络名+密码,固定 HOST_IP)。协程;成功返回 {ok, code, ip}。
static func host_start() -> Dictionary:
	print("[ET] host_start: 开始(_active=%s _my_ip=%s)" % [str(_active), _my_ip])
	if _active and _my_ip != "":
		return {"ok": true, "code": _code, "ip": _my_ip, "reuse": true}
	var occupant := _foreign_subnet_owner()
	print("[ET] host_start: 网段预检='%s'" % occupant)
	if occupant != "":
		return {"ok": false, "err": "本机已有其它虚拟网占用 %s\n请先停掉手动开的 EasyTier/MCTier 网络,再点一键开网" % occupant}
	var net := "cyr-" + _rand_hex(6)
	var secret := _rand_str(24)
	_code = encode_code({"v": 1, "n": net, "s": secret, "p": DEFAULT_PEERS, "h": HOST_IP})
	print("[ET] host_start: 邀请码已生成(len=%d)" % _code.length())
	var sdir := _start_node("s0", net, secret, HOST_IP, DEFAULT_PEERS, [], true, DEV_NAME, RPC_PORT)
	print("[ET] host_start: _start_node 返回='%s'" % sdir)
	if sdir == "":
		return {"ok": false, "err": "内核文件缺失(tools/easytier 未打进导出包?开发模式跑则检查 res:// 目录)"}
	var ip := await _wait_adapter_ip(DEV_NAME, START_TIMEOUT)
	print("[ET] host_start: 网卡等待返回='%s'" % ip)
	if ip == "":
		return {"ok": false, "err": _start_fail_hint(sdir)}
	_active = true
	_my_ip = ip
	print("[ET] host_start: 成功 ip=%s" % ip)
	return {"ok": true, "code": _code, "ip": ip}


## 朋友:粘邀请码入网(--dhcp 自动取号;超时回退随机手动 IP 一次)。协程;成功返回 {ok, host_ip, my_ip}。
static func join(code_text: String) -> Dictionary:
	var d := decode_code(code_text)
	if d.is_empty():
		return {"ok": false, "err": "邀请码无效(应为 %s 开头的一串字符,找房主要完整复制)" % CODE_PREFIX}
	if _active and _my_ip != "":
		return {"ok": true, "host_ip": str(d["h"]), "my_ip": _my_ip, "reuse": true}
	var occupant := _foreign_subnet_owner()
	if occupant != "":
		return {"ok": false, "err": "本机已有其它虚拟网占用 %s\n请先停掉手动开的 EasyTier/MCTier 网络,再加入" % occupant}
	var peers: Array = d["p"]
	var sdir := _start_node("s0", str(d["n"]), str(d["s"]), "", peers, [], false, DEV_NAME, RPC_PORT)
	if sdir == "":
		return {"ok": false, "err": "内核文件缺失(tools/easytier 未打进导出包?开发模式跑则检查 res:// 目录)"}
	var ip := await _wait_adapter_ip(DEV_NAME, DHCP_TIMEOUT)
	if ip == "":
		# dhcp 没号(内核 allocator 没醒/被安全软件拖慢):改随机手动 IP 重来一次
		var fallback := SUBNET_PREFIX + str(2 + (randi() % 249))
		_request_stop("s0")
		await _sleep(2.5)
		sdir = _start_node("s0", str(d["n"]), str(d["s"]), fallback, peers, [], false, DEV_NAME, RPC_PORT)
		if sdir == "":
			return {"ok": false, "err": "重试入网失败(内核文件缺失)"}
		ip = await _wait_adapter_ip(DEV_NAME, START_TIMEOUT - DHCP_TIMEOUT)
		if ip == "":
			return {"ok": false, "err": _start_fail_hint(sdir)}
	_active = true
	_my_ip = ip
	return {"ok": true, "host_ip": str(d["h"]), "my_ip": ip}


## 停网(写 stop.flag,helper ≤1.5s 内杀内核)。不阻塞。
static func stop() -> void:
	_request_stop("s0")
	_active = false
	_my_ip = ""


## 生产网卡是否活着(有 IP 即算)
static func is_active() -> bool:
	return _active and _my_ip != ""


## 当前邀请码(房主面板回显用;空=没开过网)
static func current_code() -> String:
	return _code


## ── 邀请码 ────────────────────────────────────────────────────────

## {v,n,s,p,h} → "CYR1-" + base64(json)。自包含:网络名/密码/会合节点/房主IP 全在里面,
## 朋友粘码即零配置(节点列表随码同步,防跨节点组不上网——MCTier 同款设计)。
static func encode_code(d: Dictionary) -> String:
	return CODE_PREFIX + Marshalls.utf8_to_base64(JSON.stringify(d))


## 解码;不合法返回空字典(不报错,调用方给文案)。
static func decode_code(text: String) -> Dictionary:
	var t := text.strip_edges()
	if not t.begins_with(CODE_PREFIX):
		return {}
	var json := Marshalls.base64_to_utf8(t.substr(CODE_PREFIX.length()))
	if json == "":
		return {}
	var parsed = JSON.parse_string(json)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var d: Dictionary = parsed
	for k in ["n", "s", "p", "h"]:
		if not d.has(k) or str(d[k]) == "":
			return {}
	if not (d["p"] is Array) or (d["p"] as Array).is_empty():
		return {}
	return d


## ── 内核落盘与拉起 ────────────────────────────────────────────────

## 解包内核到 user://easytier(尺寸相同则跳过,24MB 别每次都拷)。返回绝对目录,失败空串。
static func ensure_runtime() -> String:
	print("[ET] ensure_runtime: 开始解包检查")
	var dir := DirAccess.open("user://")
	if dir == null:
		return ""
	dir.make_dir_recursive("easytier")
	var et := "user://easytier"
	# ★ 五件套缺一不可:core 的 Windows 加载器**静态依赖** Packet.dll/WinDivert64.sys
	#   (缺了不报错,进程直接 exit 127 秒退——P1 实测踩坑),wintun.dll 是 TUN 网卡的驱动接口。
	for fname: String in ["easytier-core.exe", "wintun.dll", "Packet.dll", "WinDivert64.sys",
			"et_elevate.ps1", "et_helper.ps1"]:
		var src := ET_RES_DIR + "/" + fname
		var src_f := FileAccess.open(src, FileAccess.READ)
		if src_f == null:
			push_error("EasyTierLink: 缺资源 " + src)
			print("[ET] ensure_runtime: 缺资源 ", src)
			return ""
		var src_size := src_f.get_length()
		src_f.close()
		var dst := et + "/" + fname
		if FileAccess.file_exists(dst):
			var dst_f := FileAccess.open(dst, FileAccess.READ)
			var dst_size := dst_f.get_length() if dst_f != null else -1
			if dst_f != null:
				dst_f.close()
			if dst_size == src_size:
				continue
		var buf := FileAccess.get_file_as_bytes(src)
		var f := FileAccess.open(dst, FileAccess.WRITE)
		if f == null:
			push_error("EasyTierLink: 写不出 " + dst)
			return ""
		f.store_buffer(buf)
		f.close()
	print("[ET] ensure_runtime: 完成 -> %s" % et)
	return ProjectSettings.globalize_path(et)


## 拉一个内核节点(生产/探针共用)。listeners 空 = --no-listener;ip "" = --dhcp。
## 返回会话目录绝对路径;失败空串。**不等待网卡**(调用方自己 _wait_adapter_ip)。
static func _start_node(sub: String, net: String, secret: String, ip: String,
		peers: Array, listeners: Array, host_mode: bool, dev_name: String,
		rpc_port: int) -> String:
	var et := ensure_runtime()
	if et == "":
		return ""
	var sdir := et.path_join(sub)
	DirAccess.make_dir_recursive_absolute(sdir)
	# 组内核参数(顺序无关;数组逐项传给 Start-Process,免引号地狱)
	var args: Array[String] = ["--network-name", net, "--network-secret", secret, "--dev-name", dev_name]
	if ip == "":
		args.append("--dhcp")
	else:
		args += ["--ipv4", ip]
	for p in peers:
		args += ["--peers", str(p)]
	if listeners.is_empty():
		args.append("--no-listener")
	else:
		for l in listeners:
			args += ["--listeners", str(l)]
	args += ["--rpc-portal", "127.0.0.1:%d" % rpc_port]
	# 会话配置(helper 的唯一输入;ps1 参数只传两个路径,防嵌套引号)
	var cfg := {
		"core_path": et.path_join("easytier-core.exe"),
		"core_args": args,
		"game_pid": OS.get_process_id(),
		"host_mode": 1 if host_mode else 0,
	}
	var f := FileAccess.open(sdir.path_join("session.json"), FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(JSON.stringify(cfg))
	f.close()
	var sf := sdir.path_join("stop.flag")
	if FileAccess.file_exists(sf):
		DirAccess.remove_absolute(sf)
	# 提权链:游戏 → et_elevate(未提权) → UAC → et_helper(提权) → 内核
	# powershell 用全路径:精简 PATH 环境下 powershell.exe 不一定在搜索路径里
	var pid := OS.create_process(SYS32 + "/WindowsPowerShell/v1.0/powershell.exe", PackedStringArray([
		"-NoProfile", "-ExecutionPolicy", "Bypass",
		"-File", et.path_join("et_elevate.ps1"),
		"-HelperPath", et.path_join("et_helper.ps1"),
		"-SessionDir", sdir,
	]))
	if pid <= 0:
		push_error("EasyTierLink: 起提权垫片失败(powershell)")
		return ""
	return sdir


## 写 stop.flag(helper 见到即杀内核)。
static func _request_stop(sub: String) -> void:
	var et := ProjectSettings.globalize_path("user://easytier")
	var sf := et.path_join(sub).path_join("stop.flag")
	var f := FileAccess.open(sf, FileAccess.WRITE)
	if f != null:
		f.store_string("stop")
		f.close()


## 轮询 ipconfig,直到指定网卡(dev_name)拿到指定网段(prefix)的 IP;超时返回 ""。
## prefix 是参数不是常量:探针用独立网段(10.147.147.x)避开生产网段与用户手动开的网。
static func _wait_adapter_ip(dev_name: String, timeout: float, prefix := SUBNET_PREFIX) -> String:
	var waited := 0.0
	while waited < timeout:
		await _sleep(0.7)
		waited += 0.7
		for ip in _adapter_ips(dev_name, prefix):
			return ip
	return ""


## ipconfig 的适配器段头判定:以冒号结尾**且不含字段行的 ". ." 点串**。
## ★ 只看冒号不够(P1 实测踩坑):每个段的第一行字段"连接特定的 DNS 后缀 . . . . . . . :"
##   同样以冒号结尾(中英文系统皆然),会把段标记当场翻掉 → IPv4 行被跳过 →
##   网卡明明就绪却"等 IP 超时"。点串是 ipconfig 的固定排版,与语言无关,可作判别。
static func _is_adapter_header(t: String) -> bool:
	return t.ends_with(":") and not t.contains(". .")


## 从 ipconfig 字段行提取指定网段的 IPv4。**纯字符串解析,禁用 RegEx**——
## 裁剪版导出模板没编 regex 模块,导出包里 `RegEx` 未声明 → 整个脚本解析失败 →
## host_start 无声返回 null(P1 实测踩坑:编辑器全绿、exe 必炸,且日志只有
## 启动期一行 Parse Error)。行形如 "IPv4 地址 . . . : 10.126.126.1":
## IP 恒在**最后一个**冒号之后,是 ASCII,与语言无关。
static func _ip_after_colon(line: String, prefix: String) -> String:
	var idx := line.rfind(":")
	if idx < 0:
		return ""
	var s := line.substr(idx + 1).strip_edges()
	if not s.begins_with(prefix):
		return ""
	var rest := s.substr(prefix.length())
	for ch in rest:   # 尾巴必须全是数字(中文"(首选)"之类的后缀在此自然落空)
		if ch < "0" or ch > "9":
			return ""
	return s


## ipconfig 解析:标题行含 dev_name 的段内,收集 prefix 网段的 IPv4(本地化无关——
## 标题行冒号结尾+无点串,IP 是 ASCII)。
static func _adapter_ips(dev_name: String, prefix: String) -> Array[String]:
	var out: Array = []
	var ips: Array[String] = []
	OS.execute(SYS32 + "/ipconfig.exe", PackedStringArray(), out, false, false)
	var text := "\n".join(PackedStringArray(out))
	var in_sec := false
	for line in text.split("\n"):
		var t := line.strip_edges()
		if _is_adapter_header(t):
			in_sec = t.contains(dev_name)
			continue
		if not in_sec:
			continue
		var ip := _ip_after_colon(t, prefix)
		if ip != "":
			ips.append(ip)
	return ips


## 预检:**别的**网卡(不含本类 cyr_et)已占本网段 → 返回占用 IP;干净返回 ""。
## 撞网段的后果是两张网卡同 IP、路由混乱,必须提前拦。
## ★ 段头判定同样走 _is_adapter_header(见其注释):冒号结尾的字段行会把
##   本类网卡的 IPv4 误认成"别人的占用",把自己刚建好的网拦在门外。
static func _foreign_subnet_owner() -> String:
	var out: Array = []
	OS.execute(SYS32 + "/ipconfig.exe", PackedStringArray(), out, false, false)
	var text := "\n".join(PackedStringArray(out))
	var in_sec := false
	for line in text.split("\n"):
		var t := line.strip_edges()
		if _is_adapter_header(t):
			in_sec = not t.contains(DEV_NAME)
			continue
		if not in_sec:
			continue
		var ip := _ip_after_colon(t, SUBNET_PREFIX)
		if ip != "":
			return ip
	return ""


## 启动失败的提示:内核日志尾部 + 常见原因(没点 UAC / 没提权)。
static func _start_fail_hint(sdir: String) -> String:
	var hint := "虚拟网卡未就绪(超时)。常见原因:① UAC 弹窗没点「是」;② 本机安全软件拦截内核。\n"
	var f := FileAccess.open(sdir.path_join("core.err.log"), FileAccess.READ)
	if f != null:
		var tail := f.get_as_text().substr(maxi(0, f.get_length() - 600))
		f.close()
		if tail != "":
			hint += "内核日志尾部:\n" + tail
	return hint


## ── 小工具 ────────────────────────────────────────────────────────

static func _rand_hex(n: int) -> String:
	var s := ""
	for i in range(n):
		s += "%x" % (randi() % 16)
	return s


static func _rand_str(n: int) -> String:
	var s := ""
	for i in range(n):
		s += RANDOM_CHARS[randi() % RANDOM_CHARS.length()]
	return s


static func _sleep(sec: float) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		await tree.create_timer(sec).timeout
