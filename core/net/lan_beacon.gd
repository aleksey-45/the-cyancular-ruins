class_name LanBeacon
extends RefCounted

# 建房后，服务器按 LanDiscovery 定义的格式向 UDP 7788 端口广播房间信息。
# 每轮向 IPv4 受限广播地址和按 /24 推算的广播地址分别发送，失败时等下一轮重试。
# 客户端从 UDP 数据报的源地址取得服务器 IP。

const PORT := LanDiscovery.PORT
const INTERVAL := LanDiscovery.INTERVAL
const BROADCAST := "255.255.255.255"

var _peer := PacketPeerUDP.new()
var _targets: PackedStringArray = []
var _room_info := Callable()
var _next_at := 0.0
var _running := false

## 开始广播。每轮发送前调用 room_info，取得 LanDiscovery.encode_room 所需的字段。
## 广播已启动时直接返回。每次重新启动时，根据当前本机地址计算广播目标。
func start(room_info: Callable) -> void:
	if _running:
		return
	_peer = PacketPeerUDP.new()
	_peer.bind(0)
	_peer.set_broadcast_enabled(true)
	_room_info = room_info
	_targets = _broadcast_targets()
	_next_at = 0.0
	_running = true

## 停止广播并释放套接字。
func stop() -> void:
	if not _running:
		return
	_running = false
	_peer.close()
	_targets.clear()
	_room_info = Callable()

func is_running() -> bool:
	return _running

## 到达发送时间后，向每个目标地址发送一个广播包。now 与 RoomSession 使用相同的时间基准，单位为秒。
func tick(now: float) -> void:
	if not _running or now < _next_at or not _room_info.is_valid():
		return
	_next_at = now + INTERVAL
	var info: Dictionary = _room_info.call()
	var packet := LanDiscovery.encode_room(info)
	for address in _targets:
		if _peer.set_dest_address(address, PORT) == OK:
			_peer.put_packet(packet)

## 返回 IPv4 受限广播地址，以及将本机 IPv4 地址按 /24 推算得到的广播地址（x.y.z.255）。
func _broadcast_targets() -> PackedStringArray:
	var targets := PackedStringArray([BROADCAST])
	var seen := {BROADCAST: true}
	for address in IP.get_local_addresses():
		var octets := address.split(".")
		if octets.size() != 4 or not address.is_valid_ip_address():
			continue
		var broadcast := "%s.%s.%s.255" % [octets[0], octets[1], octets[2]]
		if seen.has(broadcast):
			continue
		seen[broadcast] = true
		targets.append(broadcast)
	return targets
