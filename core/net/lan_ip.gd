class_name LanIp
extends RefCounted

# 本机局域网候选 IP 发现(只用于「朋友填哪个地址」的提示,不承载联机逻辑)。纯静态、无 autoload 依赖。
# 候选顺序:local_ip.txt(秒回)→ netstat -rn 默认路由网卡(按 metric 升序)→ 其余私有地址;查询失败 / 非 Windows / Web 只剩私有排序(不保证第一个是真网卡)。
# ★ 默认路由优先是为了排除 WSL / Hyper-V / Docker / VMware 虚拟网卡的地址(看着像局域网、对端不可达)。
# ★ 用 netstat 而不是 PowerShell(实测冷启动 2.5 秒会卡大厅页);也别改成工作线程:进程退出时会偶发原生访问违例。
# 守卫:tests/smoke/lan_ip_smoke.gd 钉住三个纯解析与转发壳同源;测不到真网卡上哪条默认路由是真的。

const SYS32 := "C:/Windows/System32"

static var _cache: Array = []


## 局域网候选 IP(第一个最可能是朋友能连上的地址)。Web 版返回空;结果缓存到进程结束。
static func lan_ip_candidates() -> Array:
	if OS.has_feature("web"):
		return []
	if not _cache.is_empty():
		return _cache.duplicate()
	var out: Array = []
	# ⓪ 服务端刚落盘的 local_ip.txt 已按默认路由算好 ⇒ 秒回,免得每次开大厅都查一次路由表。
	var from_file := _read_ip_file_best()
	if from_file != "":
		out.append(from_file)
	# ① 默认路由网卡:netstat -rn 里 0.0.0.0 0.0.0.0 <网关> <本机IP> <metric> 的行,按 metric 升序。
	if out.is_empty():
		var raw: Array = []
		OS.execute(SYS32 + "/netstat.exe", PackedStringArray(["-rn"]), raw, false, false)
		var parts := PackedStringArray()
		for chunk in raw:
			parts.append(str(chunk))
		for s in parse_default_routes("\n".join(parts)):
			if _priv_score(s) >= 2 and not out.has(s):
				out.append(s)
	# ② 补充其余私有地址(只用于第一候选不通时换一个试)
	var rest: Array = []
	for a in IP.get_local_addresses():
		var s := str(a)
		if ":" in s or s.begins_with("127.") or s.begins_with("169.254."):
			continue
		if _priv_score(s) >= 2 and not out.has(s) and not rest.has(s):
			rest.append(s)
	out.append_array(rank_private(rest))
	_cache = out
	return out.duplicate()


## 解析 netstat -rn 文本里的默认路由行:只留点分 IPv4 网卡地址、同网卡去重(留首次出现的 metric)、按 metric 升序。
## 行形如 `0.0.0.0 0.0.0.0 <网关> <本机IP> <metric>`;多播 / on-link / 表头等噪行一律跳过。
static func parse_default_routes(text: String) -> Array[String]:
	var hits: Array = []   # [metric:int, iface:String]
	for line in text.split("\n"):
		var cols := line.strip_edges().split(" ", false)
		if cols.size() < 5 or cols[0] != "0.0.0.0" or cols[1] != "0.0.0.0":
			continue
		var iface := str(cols[3])
		if not _is_dotted_ipv4(iface):
			continue
		var dup := false
		for h in hits:
			if str(h[1]) == iface:
				dup = true
				break
		if not dup:
			hits.append([int(cols[cols.size() - 1]), iface])
	hits.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) < int(b[0]))
	var out: Array[String] = []
	for h in hits:
		out.append(str(h[1]))
	return out


## 按私有网段优先级稳定排序:192.168.* > 10.* > 172.16~31.* > 其它,同档保持输入顺序。
static func rank_private(ips: Array) -> Array[String]:
	var out: Array[String] = []
	for score in [4, 3, 2, 1]:
		for a in ips:
			var s := str(a)
			if _priv_score(s) == score:
				out.append(s)
	return out


## 从 local_ip.txt 首行(如「本机局域网 IP: 10.0.0.5(其它候选: …)」)抽出点分 IPv4;没有 IP: 前缀或值非法 ⇒ 返回 ""。
## ★ 旧实现从 IP: 后直接按分隔符截断,而 server_main 落盘是「IP: 10.0.0.5」(冒号后一个空格)⇒ 每次都在第 0 个空格
##   截成空串、local_ip.txt 快回路径从未命中 —— 所以这里先 strip 再截分隔符。
static func parse_ip_file_line(line: String) -> String:
	var idx := line.find("IP:")
	if idx < 0:
		return ""
	var rest := line.substr(idx + 3).strip_edges()
	for sep in ["(", ",", " ", "\t", "，"]:
		var at := rest.find(sep)
		if at >= 0:
			rest = rest.substr(0, at)
	var ip := rest.strip_edges()
	return ip if _is_dotted_ipv4(ip) else ""


# 读同机服务端写的 local_ip.txt 首行,并校验该 IP 仍是本机当前地址(防网络切换后的陈旧文件);读不到/失效返回 ""。
# 落盘位置与 server_main._write_ip_file 一致:导出版 = exe 同目录,开发态 = res://;再兜底 user://。
static func _read_ip_file_best() -> String:
	var dir := OS.get_executable_path().get_base_dir()
	if not OS.has_feature("template"):
		dir = ProjectSettings.globalize_path("res://")
	var f := FileAccess.open(dir + "/local_ip.txt", FileAccess.READ)
	if f == null:
		f = FileAccess.open("user://local_ip.txt", FileAccess.READ)
	if f == null:
		return ""
	var first := f.get_line()
	f.close()
	var ip := parse_ip_file_line(first)
	if ip == "":
		return ""
	for a in IP.get_local_addresses():
		if str(a) == ip:
			return ip
	return ""


# 点分十进制 IPv4 判定(不用 RegEx:本文件会进导出包,裁剪模板删掉了 RegEx 模块)。
static func _is_dotted_ipv4(s: String) -> bool:
	var parts := s.split(".")
	if parts.size() != 4:
		return false
	for p in parts:
		if p == "" or not p.is_valid_int():
			return false
		var v := int(p)
		if v < 0 or v > 255:
			return false
	return true


# 本机 IP 提示(服务器与客户端同机):直接展示客户端自己的地址,免手动 ipconfig;多个候选时把"不通就换"也印出来。
static func lan_ip_hint() -> String:
	var ips := lan_ip_candidates()
	if ips.is_empty():
		return "未检测到局域网 IP(网络未连接?)"
	var text := "本机局域网 IP: %s(朋友在「服务器地址」里填它)" % str(ips[0])
	if ips.size() > 1:
		text += "(不通就换: %s)" % ", ".join(ips.slice(1, mini(ips.size(), 3)))
	return text


# 私有网段分档(排序与"是否私有"共用):192.168.*=4 > 10.*=3 > 172.16~31.*=2 > 其它=1。
static func _priv_score(ip: String) -> int:
	if ip.begins_with("192.168."):
		return 4
	if ip.begins_with("10."):
		return 3
	if ip.begins_with("172."):
		var parts := ip.split(".")
		if parts.size() > 1:
			var o2 := int(parts[1])
			if o2 >= 16 and o2 <= 31:
				return 2
	return 1
