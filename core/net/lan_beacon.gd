class_name LanBeacon
extends RefCounted

# 房主侧局域网广播:按 LanDiscovery 的包格式,周期性把房间信息发到 UDP 7788 端口。
# 每轮向全局广播地址和每个本机 IPv4 网段的 /24 广播地址各发一次;发送失败静默,下一轮重试。
# 只发送、不监听,包体里不写 IP;接收端见 LanDiscovery 与大厅监听。

const PORT := LanDiscovery.PORT
const INTERVAL := LanDiscovery.INTERVAL
const BROADCAST := "255.255.255.255"

var _peer := PacketPeerUDP.new()
var _targets: PackedStringArray = []
var _room_info := Callable()
var _next_at := 0.0
var _running := false

## 开始广播;room_info 在每轮发包时调用,返回交给 LanDiscovery.encode_room 的字段。
## 重复调用无副作用;每次启动都按当前本机地址重新计算目标。
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

## 到达广播周期时发送一包。now 与 RoomSession 的时间基准一致(秒)。
func tick(now: float) -> void:
	if not _running or now < _next_at or not _room_info.is_valid():
		return
	_next_at = now + INTERVAL
	var info: Dictionary = _room_info.call()
	var packet := LanDiscovery.encode_room(info)
	for address in _targets:
		if _peer.set_dest_address(address, PORT) == OK:
			_peer.put_packet(packet)

## 目标地址:全局广播地址,加上每个本机 IPv4 的 /24 广播地址(x.y.z.255)。
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
