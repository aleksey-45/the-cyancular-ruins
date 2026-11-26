class_name LanDiscovery
extends RefCounted

# 监听 LanBeacon 发出的局域网房间广播，按房间号去重并移除过期条目。

const PORT := 7788
const INTERVAL := 1.0
const TTL := 3.0
const MAX_PACKET := 1024
const VERSION := 1
# 限制每次轮询处理的数据报数量，避免广播流量过高时占用整帧。
const MAX_PACKETS := 64

var _rooms: Dictionary = {}
var _socket: PacketPeerUDP = null


static func encode_room(info: Dictionary) -> PackedByteArray:
	return JSON.stringify(info.merged({"v": VERSION, "t": "room"})).to_utf8_buffer()


static func decode_room(packet: PackedByteArray) -> Dictionary:
	if packet.is_empty() or packet.size() > MAX_PACKET:
		return {}
	var text := packet.get_string_from_utf8()
	var json := JSON.new()
	if json.parse(text) != OK:
		return {}
	var parsed: Variant = json.data
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	var data: Dictionary = parsed
	if data.get("v") != VERSION or data.get("t") != "room": return {}
	if not data.get("code") is String or not RoomSummary.valid_code(data["code"]): return {}
	if not RoomOptions.MODE_FIELDS.has(data.get("mode")): return {}
	if not data.get("in_match") is bool or not data.get("beta") is bool: return {}
	var maximum := _int_field(data, "max", 0, RoomOptions.ROYALE_PLAYERS.y)
	var players := _int_field(data, "players", 0, maximum)
	var port := _int_field(data, "port", 1024, 65535)
	if players < 0 or port < 0: return {}
	return {"code": data["code"], "mode": data["mode"], "players": players, "max": maximum,
		"in_match": data["in_match"], "beta": data["beta"], "port": port}

## 读取整数字段。缺失、非整数或超出范围时返回 -1。
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


## 每份公告都刷新地址和有效期，只有大厅可见的摘要变化时才返回 true。
func update(info: Dictionary, source_ip: String, now: float) -> bool:
	var code: String = info["code"]
	var summary := info.duplicate()
	summary.erase("port")
	var changed: bool = not _rooms.has(code) or _rooms[code].summary != summary
	_rooms[code] = {"summary": summary, "endpoint": {"ip": source_ip, "port": info.port}, "last_seen": now}
	return changed


func rooms() -> Array[RoomSummary]:
	var codes := _rooms.keys()
	codes.sort()
	var result: Array[RoomSummary] = []
	for code: String in codes:
		result.append(RoomSummary.new(_rooms[code].summary))
	return result

func endpoint(code: String, now: float) -> Dictionary:
	var entry: Dictionary = _rooms.get(code, {})
	if entry.is_empty() or now - entry.last_seen > TTL: return {}
	return entry.endpoint


## 移除过期房间，返回列表是否有变化。
func expire(now: float) -> bool:
	var removed := false
	for code in _rooms.keys():
		if now - float(_rooms[code]["last_seen"]) > TTL:
			_rooms.erase(code)
			removed = true
	return removed


## 绑定 0.0.0.0:PORT 接收广播。绑定失败时返回错误码。
func listen() -> Error:
	stop()
	var socket := PacketPeerUDP.new()
	var error := socket.bind(PORT, "0.0.0.0")
	if error != OK:
		return error
	_socket = socket
	return OK


## 停止监听并释放端口。可以重复调用。
func stop() -> void:
	_rooms.clear()
	if _socket == null:
		return
	_socket.close()
	_socket = null


## 接收广播并更新房间列表。列表变化时返回 true，未监听时返回 false。
func poll(now: float) -> bool:
	if _socket == null:
		return false
	var changed := expire(now)
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
