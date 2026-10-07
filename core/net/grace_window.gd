class_name GraceWindow
extends RefCounted

# 断线重连宽限期记录表（纯逻辑数据结构，无 Autoload 与场景依赖）。
#
# 核心职责：
# - 玩家掉线后调用 enter() 记录到期时刻；
# - 在宽限期内可通过 reclaim_role() 重新认领角色；
# - 调用 expired() 检出到期未重连的角色，由外部调用方将其移出对局；
# - 调用 leave() 结束该角色的宽限记录（重连成功、主动移出或对局结束均会调用）。
#
# - 时间由调用方传入毫秒时间戳，本类不直接读取系统时钟，便于单元测试；

# 宽限期默认时长（秒）：1v1、3v3 与大乱斗模式统一为 60 秒。
const DEFAULT_SECONDS := 60.0

# 宽限期超时处置策略
const ACTION_REMOVE := 0     # 将离线玩家移出对局（角色销毁），其余玩家继续——用于大乱斗与 3v3
const ACTION_TEARDOWN := 1   # 结束对局并退出进程——用于 1v1（双人单挑中一方离线则对局终止）


## 根据当前对局模式判定宽限期到期后的处置方式
static func expire_action(is_royale: bool, is_team: bool) -> int:
	return ACTION_REMOVE if (is_royale or is_team) else ACTION_TEARDOWN

var _until: Dictionary = {}     # role(int) -> 到期时刻 ms


## 进入宽限期。seconds 默认使用 DEFAULT_SECONDS，重复调用刷新到期时间。
func enter(role: int, now_ms: int, seconds: float = DEFAULT_SECONDS) -> void:
	_until[int(role)] = now_ms + int(seconds * 1000.0)


func has(role: int) -> bool:
	return _until.has(int(role))


## 移除角色的宽限期记录（重连成功、超时移除或对局结束时调用）。
func leave(role: int) -> void:
	_until.erase(int(role))


## 获取所有已超时的角色列表，按角色 ID 升序排序返回。
## 调用方获取列表后应自行调用 leave() 并处理玩家移除逻辑。
func expired(now_ms: int) -> Array[int]:
	var out: Array[int] = []
	for r in _until:
		if now_ms >= int(_until[r]):
			out.append(int(r))
	out.sort()
	return out


## 服务端计算当前各离线角色的剩余宽限秒数字典，键为角色编号，值为剩余秒数浮点值。
## 已到期但尚未 leave 的角色保留并返回 0.0，避免客户端瞬间丢失倒计时显示。
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


## 将宽限期数据合并入网络广播载荷。仅在存在掉线角色时写入 "grace" 字段，避免空载荷浪费带宽。
static func merge_into(data: Dictionary, remaining_map: Dictionary) -> void:
	if not remaining_map.is_empty():
		data["grace"] = remaining_map


## 客户端每帧推进 HUD 宽限期倒计时显示。数值下限限制为 0.0，避免出现负数显示。
static func tick_display(display: Dictionary, delta: float) -> Dictionary:
	var out := {}
	for r in display.keys():
		out[r] = maxf(0.0, float(display[r]) - delta)
	return out


func size() -> int:
	return _until.size()
