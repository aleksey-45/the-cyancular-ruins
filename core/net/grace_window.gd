class_name GraceWindow
extends RefCounted

# 掉线宽限期表(纯逻辑;时间由调用方传入 ms)。到期判据是 `now >= until`(含边界);重复 enter 是刷新。
# `DEFAULT_SECONDS` 是时长的唯一入口 —— 改它会同时动"重连重试预算"与"按宽限期算出来的测试窗口"。
# 到点后做什么是纯分派:大乱斗 / 3v3 移出对局,1v1 收场;调用方不得再抄一遍 if/else(抄过 ⇒ 3v3 整局退进程)。

const DEFAULT_SECONDS := 60.0

const ACTION_REMOVE := 0
const ACTION_TEARDOWN := 1


static func expire_action(is_royale: bool, is_team: bool) -> int:
	return ACTION_REMOVE if (is_royale or is_team) else ACTION_TEARDOWN

var _until: Dictionary = {}     # role(int) -> 到期时刻 ms


func enter(role: int, now_ms: int, seconds: float = DEFAULT_SECONDS) -> void:
	_until[int(role)] = now_ms + int(seconds * 1000.0)


func has(role: int) -> bool:
	return _until.has(int(role))


func leave(role: int) -> void:
	_until.erase(int(role))


# 按 role 升序;调用方拿到后自己 `leave()`。已到期的 role 在 `remaining()` 里仍报 0.0(省略会闪回「无掉线」)。
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


# 非空才带键,且就地改 `data`(免得有人忘了接返回值)。
static func merge_into(data: Dictionary, remaining_map: Dictionary) -> void:
	if not remaining_map.is_empty():
		data["grace"] = remaining_map


# 钳到 0(否则 HUD 会念「剩余 -3s」);键原样保留 —— 1.0 与 1 在 GDScript 字典里是两个键。
static func tick_display(display: Dictionary, delta: float) -> Dictionary:
	var out := {}
	for r in display.keys():
		out[r] = maxf(0.0, float(display[r]) - delta)
	return out


func size() -> int:
	return _until.size()
