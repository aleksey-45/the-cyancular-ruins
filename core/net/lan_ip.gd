class_name LanIp
extends RefCounted


const SYS32 := "C:/Windows/System32"

static var _cache: Array = []


static func lan_ip_candidates() -> Array:
	if OS.has_feature("web"):
		return []
	if not _cache.is_empty():
		return _cache.duplicate()
	var out: Array = []
	var from_file := _read_ip_file_best()
	if from_file != "":
		out.append(from_file)
	if out.is_empty():
		var raw: Array = []
		OS.execute(SYS32 + "/netstat.exe", PackedStringArray(["-rn"]), raw, false, false)
		var parts := PackedStringArray()
		for chunk in raw:
			parts.append(str(chunk))
		for s in parse_default_routes("\n".join(parts)):
			if _priv_score(s) >= 2 and not out.has(s):
				out.append(s)
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


static func parse_default_routes(text: String) -> Array[String]:
	var hits: Array = []
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


static func rank_private(ips: Array) -> Array[String]:
	var out: Array[String] = []
	for score in [4, 3, 2, 1]:
		for a in ips:
			var s := str(a)
			if _priv_score(s) == score:
				out.append(s)
	return out


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


static func lan_ip_hint() -> String:
	var ips := lan_ip_candidates()
	if ips.is_empty():
		return "未检测到局域网 IP(网络未连接?)"
	var text := "本机局域网 IP: %s(朋友在「服务器地址」里填它)" % str(ips[0])
	if ips.size() > 1:
		text += "(不通就换: %s)" % ", ".join(ips.slice(1, mini(ips.size(), 3)))
	return text


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
