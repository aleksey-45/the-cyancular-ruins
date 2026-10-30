extends RefCounted

# 预测接触判据 / 动态容差的纯函数(无 autoload、无 SceneTree ⇒ `-s` 可测)。
#
# 为什么要这一层:客户端预测撞的"对手身体"是幽灵体 = **最新快照**(滞后 ≈ 单程 + 0~1 tick 发包间隔;
# 跑速 700 时 0~12px),而服务器裁决用自己此刻的位置。旧实现:①幽灵体直接吃最新快照、不外推;
# ②"是否贴身"用客户端自己的碰撞结果 `touching_player()` 判 ⇒ 追人时幽灵滞后让你预测穿过去、
# 判不到贴身 ⇒ 仍按 2px 容差,每 60Hz 验证点挨一次回滚。这里给两件事:
#   - `rect_gap`:用"预测身位到幽灵 AABB 的间隙"判贴身(不依赖本帧是否真的撞上);
#   - `contact_tol`:贴身容差按"相对速度 × 滞后"动态抬高,封顶 48px(约 0.6 身位,不掩盖真分歧)。

const CONTACT_GAP := 12.0      # 预测身位 AABB 间隙 ≤ 此值视为"贴身区"(px)
const MAX_LAG_S := 0.05        # 幽灵滞后估计上限(单程 + 半个 60Hz 间隔,封顶 50ms = 3 tick)
const BASE_CONTACT_TOL := 8.0  # 与 PredictionRollback.DEFAULT_CONTACT_POS_TOL 同值(旧行为下限)
const MAX_CONTACT_TOL := 48.0


# 两个 AABB 的最小间隙(相交 = 0,角对角 = 欧氏距离)。
static func rect_gap(a: Rect2, b: Rect2) -> float:
	var dx := maxf(0.0, maxf(a.position.x - b.end.x, b.position.x - a.end.x))
	var dy := maxf(0.0, maxf(a.position.y - b.end.y, b.position.y - a.end.y))
	return sqrt(dx * dx + dy * dy)


# 幽灵滞后估计(秒):单程 ≈ RTT/2,再 + 半个 60Hz 发包间隔(最新包本身已 0~16.7ms 旧)。
static func ghost_horizon_s(ping_ms: int) -> float:
	var one_way := float(maxi(ping_ms, 0)) / 2000.0
	return clampf(one_way + 0.5 / 60.0, 0.0, MAX_LAG_S)


# 贴身容差(px):下限 8(旧行为),随"相对速度 × 滞后"增长,封顶 48。
static func contact_tol(rel_speed: float, horizon_s: float) -> float:
	var drift := absf(rel_speed) * clampf(horizon_s, 0.0, MAX_LAG_S)
	return clampf(BASE_CONTACT_TOL + drift, BASE_CONTACT_TOL, MAX_CONTACT_TOL)


# 预测身位与幽灵体的间隙是否进入贴身区。
static func is_contact(gap: float) -> bool:
	return gap <= CONTACT_GAP
