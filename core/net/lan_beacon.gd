class_name LanBeacon
extends RefCounted

# Windows 的网卡 API 提供实际 IPv4 掩码。macOS 的 ifconfig 直接给出广播地址。
const WINDOWS_BROADCASTS := """
foreach ($nic in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
	if ($nic.OperationalStatus -ne 'Up' -or $nic.NetworkInterfaceType -eq 'Loopback') { continue }
	foreach ($u in $nic.GetIPProperties().UnicastAddresses) {
		if ($u.Address.AddressFamily -ne 'InterNetwork') { continue }
		$ip = $u.Address.GetAddressBytes()
		$mask = $u.IPv4Mask.GetAddressBytes()
		if ($mask[3] -ge 254) { continue }
		$octets = for ($i = 0; $i -lt 4; $i++) { $ip[$i] -bor (255 -bxor $mask[$i]) }
		'broadcast ' + ($octets -join '.')
	}
}
"""

var _peer := PacketPeerUDP.new()
var _targets := PackedStringArray(["255.255.255.255"])
var _room_info: Callable
var _next_at := 0.0

func _init(room_info: Callable) -> void:
	_room_info = room_info
	_peer.bind(0)
	_peer.set_broadcast_enabled(true)
	var output := []
	match OS.get_name():
		"Windows": OS.execute("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", WINDOWS_BROADCASTS], output)
		"macOS": OS.execute("/sbin/ifconfig", ["-a", "inet"], output)
	var pattern := RegEx.create_from_string(r"\bbroadcast ([0-9.]+)")
	for entry in pattern.search_all("".join(output)):
		var target := entry.get_string(1)
		if not _targets.has(target): _targets.append(target)

func tick(now: float) -> void:
	if now < _next_at: return
	_next_at = now + LanDiscovery.INTERVAL
	var packet := LanDiscovery.encode_room(_room_info.call())
	for target in _targets:
		if _peer.set_dest_address(target, LanDiscovery.PORT) == OK:
			_peer.put_packet(packet)
