class_name GraceWindow
extends RefCounted

# 掉线宽限期表(纯逻辑、无 autoload、`-s` 可测)。
#
# 语义:某 role 掉线后 `enter`;宽限内它可以被 `reclaim_role` 重连;`expired` 报出到期仍未
# 回来的 role,由调用方走既有的"移出对局"语义。`leave` 是"这件事结束了"的完成信号
# (重连成功 / 主动移出 / 服务端收场,三处都调)。
#
# ★ **时间由调用方传入(ms),本类不读时钟** —— 否则冒烟只能靠 sleep。
# ★ 到期判据是 `now >= until`(**含边界**):取 > 会让"正好到点"永不算到期,
#   而时长取 0 时那条分支永不触发(同 CombatFeedback.ATTRIB_WINDOW_MS 的注释)。
# ★ 重复 enter 是**刷新**到期时刻,不叠加 —— 掉线两次不该得到两倍宽限。

const DEFAULT_SECONDS := 30.0   # ★ 宽限期时长的唯一入口(改时长只改这里)

var _until: Dictionary = {}     # role(int) -> 到期时刻 ms


# 进入宽限。seconds 默认走常量;重复调用刷新到期时刻。
func enter(role: int, now_ms: int, seconds: float = DEFAULT_SECONDS) -> void:
	_until[int(role)] = now_ms + int(seconds * 1000.0)


func has(role: int) -> bool:
	return _until.has(int(role))


# "这件事结束了":重连成功 / 主动移出 / 收场,三处都调它。
func leave(role: int) -> void:
	_until.erase(int(role))


# 已到期的 role,**按 role 升序**(字典迭代顺序不保证,排序是为了确定性)。
# 调用方拿到后应自行 `leave()` —— 本类不改调用方的对局状态。
func expired(now_ms: int) -> Array[int]:
	var out: Array[int] = []
	for r in _until:
		if now_ms >= int(_until[r]):
			out.append(int(r))
	out.sort()
	return out


func size() -> int:
	return _until.size()
