class_name GraceWindow
extends RefCounted


const DEFAULT_SECONDS := 60.0

const ACTION_REMOVE := 0
const ACTION_TEARDOWN := 1


static func expire_action(is_royale: bool, is_team: bool) -> int:
	return ACTION_REMOVE if (is_royale or is_team) else ACTION_TEARDOWN

var _until: Dictionary = {}


func enter(role: int, now_ms: int, seconds: float = DEFAULT_SECONDS) -> void:
	_until[int(role)] = now_ms + int(seconds * 1000.0)


func has(role: int) -> bool:
	return _until.has(int(role))


func leave(role: int) -> void:
	_until.erase(int(role))


func expired(now_ms: int) -> Array[int]:
	var out: Array[int] = []
	for r in _until:
		if now_ms >= int(_until[r]):
			out.append(int(r))
	out.sort()
	return out


func remaining(now_ms: int) -> Dictionary:
	var roles: Array[int] = []
	for r in _until:
		roles.append(int(r))
	roles.sort()
	var out := {}
	for r in roles:
		var left_ms := int(_until[r]) - now_ms
		out[r] = 0.0 if left_ms <= 0 else float(left_ms) / 1000.0
	return out


static func merge_into(data: Dictionary, remaining_map: Dictionary) -> void:
	if not remaining_map.is_empty():
		data["grace"] = remaining_map


static func tick_display(display: Dictionary, delta: float) -> Dictionary:
	var out := {}
	for r in display.keys():
		out[r] = maxf(0.0, float(display[r]) - delta)
	return out


func size() -> int:
	return _until.size()
