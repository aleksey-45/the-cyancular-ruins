class_name LanDiscovery
extends RefCounted

# 局域网房间发现:广播包的编解码 + 接收端注册表(TTL/去重) + 客户端 UDP 监听。
# 房主侧每秒广播一次(见 LanBeacon),客户端侧监听同一 UDP 端口(见 docs/netplay.md)。
# 编解码与注册表保持纯逻辑,方便测试;UDP 监听不参与自动测试。

const PORT := 7788
const INTERVAL := 1.0
const TTL := 3.0
const MAX_PACKET := 1024
const VERSION := 1
const MODES := ["pvp", "team", "royale"]
# 单次 poll 最多处理的包数,避免广播风暴占满一帧。
const MAX_PACKETS := 64

var _rooms: Dictionary = {}
var _socket: PacketPeerUDP = null


static func encode_room(info: Dictionary) -> PackedByteArray:
	var room := {
		"v": VERSION,
		"t": "room",
		"code": str(info.get("code", "")),
		"mode": str(info.get("mode", "")),
		"players": int(info.get("players", 0)),
		"max": int(info.get("max", 0)),
		"in_match": bool(info.get("in_match", false)),
		"beta": bool(info.get("beta", false)),
		"port": int(info.get("port", 0)),
	}
	return JSON.stringify(room).to_utf8_buffer()


static func decode_room(packet: PackedByteArray) -> Dictionary:
	if packet.is_empty() or packet.size() > MAX_PACKET:
		return {}
	var text := packet.get_string_from_utf8()
	if text.is_empty():
		return {}
	var json := JSON.new()
	if json.parse(text) != OK:
		return {}
	var parsed: Variant = json.data
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var data: Dictionary = parsed
	if not is_valid_room(data):
		return {}
	return data


## 校验广播包字段;编码前与接收后共用同一套判据。
static func is_valid_room(data: Dictionary) -> bool:
	if data.has("v") and int(data["v"]) != VERSION:
		return false
	if data.has("t") and str(data["t"]) != "room":
		return false
	if not valid_code(str(data.get("code", ""))):
		return false
	if not MODES.has(str(data.get("mode", ""))):
		return false
	var players := _int_field(data, "players", 0, 16)
	var maximum := _int_field(data, "max", 0, 16)
	if players < 0 or maximum < 0 or players > maximum:
		return false
	if _int_field(data, "port", 1024, 65535) < 0:
		return false
	if not data.has("in_match") or not data.has("beta"):
		return false
	return true


static func valid_code(code: String) -> bool:
	if code.length() != 8:
		return false
	for i in code.length():
		if code[i] < "0" or code[i] > "9":
			return false
	return true


## 读整数字段;缺失/非整数/越界返回 -1。
static func _int_field(data: Dictionary, key: String, low: int, high: int) -> int:
	var value: Variant = data.get(key, null)
	if value == null or not (value is float or value is int):
		return -1
	var number := float(value)
	if number != floor(number):
		return -1
	var result := int(number)
	if result < low or result > high:
		return -1
	return result


## 收到一包:刷新注册表;返回信息是否有变化(用于刷新 UI)。
func update(info: Dictionary, source_ip: String, now: float) -> bool:
	var code := str(info.get("code", ""))
	if not is_valid_room(info):
		return false
	var previous: Dictionary = _rooms.get(code, {})
	var changed := previous.is_empty() or str(previous.get("ip", "")) != source_ip \
			or not _same_room(previous["info"], info)
	_rooms[code] = {"info": info.duplicate(true), "ip": source_ip, "last_seen": now}
	return changed


## 当前仍有效的房间(按房号排序);过期条目顺带清掉。
func rooms(now: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for code in _rooms.keys():
		var entry: Dictionary = _rooms[code]
		if now - float(entry["last_seen"]) > TTL:
			_rooms.erase(code)
			continue
		var room: Dictionary = entry["info"].duplicate(true)
		room["ip"] = entry["ip"]
		out.append(room)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["code"]) < str(b["code"]))
	return out


## 清掉过期房间;返回是否有条目被移除。
func expire(now: float) -> bool:
	var removed := false
	for code in _rooms.keys():
		if now - float(_rooms[code]["last_seen"]) > TTL:
			_rooms.erase(code)
			removed = true
	return removed


func clear() -> void:
	_rooms.clear()


## 绑定 0.0.0.0:PORT 开始接收广播;端口被占用等失败时返回错误,不崩溃。
func listen() -> Error:
	stop()
	var socket := PacketPeerUDP.new()
	var error := socket.bind(PORT, "0.0.0.0")
	if error != OK:
		return error
	_socket = socket
	return OK


## 停止监听并释放端口;未监听时无操作。
func stop() -> void:
	if _socket == null:
		return
	_socket.close()
	_socket = null


## 收取已到达的广播并刷新注册表;返回注册表是否有变化。未监听时直接返回 false。
func poll(now: float) -> bool:
	if _socket == null:
		return false
	var changed := false
	for _i in MAX_PACKETS:
		if _socket.get_available_packet_count() <= 0:
			break
		var packet := _socket.get_packet()
		var source_ip := _socket.get_packet_ip()
		var info := decode_room(packet)
		if info.is_empty():
			continue
		if update(info, source_ip, now):
			changed = true
	return changed


static func _same_room(a: Dictionary, b: Dictionary) -> bool:
	return str(a.get("mode", "")) == str(b.get("mode", "")) \
			and int(a.get("players", 0)) == int(b.get("players", 0)) \
			and int(a.get("max", 0)) == int(b.get("max", 0)) \
			and bool(a.get("in_match", false)) == bool(b.get("in_match", false)) \
			and bool(a.get("beta", false)) == bool(b.get("beta", false)) \
			and int(a.get("port", 0)) == int(b.get("port", 0))
