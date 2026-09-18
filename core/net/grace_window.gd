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

# ── 宽限期**到点之后**该做什么:纯分派(无 autoload、无副作用、可 `-s` 测)──
# 三个模式的答案就在这里,由 tests/grace_window_smoke 逐个钉住;调用方只做一次比较,
# **不得**再抄一遍 if/else —— 那种写法出过一次真事故:原先 server_main 只有"大乱斗 / 其余"
# 两支,`else` 把 1v1 **和 3v3** 一起吞了,于是 3v3 里第一个宽限到期的人会带着整局退进程
# (用户裁定是"该队少人继续打"),而它当时不可达只因大厅还没有起 team worker 的入口。
const ACTION_REMOVE := 0     # 移出对局(身体销毁),其余人继续打 —— 大乱斗 / 3v3
const ACTION_TEARDOWN := 1   # 收场退进程 —— 1v1(对手走了就没人可打)


# is_royale / is_team 直接来自 worker 的模式开关。两者任一为真都走"移出对局":
# 大乱斗的自由混战与 3v3 的团队对抗都是"少一个人照样打得下去";1v1 少一个人就不成局。
static func expire_action(is_royale: bool, is_team: bool) -> int:
	return ACTION_REMOVE if (is_royale or is_team) else ACTION_TEARDOWN

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
