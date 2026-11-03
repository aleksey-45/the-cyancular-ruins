extends RefCounted

# 预测接触判据 / 动态容差的纯函数(无 autoload、无 SceneTree ⇒ `-s` 可测)。

const CONTACT_GAP := 12.0      # 预测身位 AABB 间隙 ≤ 此值视为"贴身区"(px)
const MAX_LAG_S := 0.05        # 幽灵滞后估计上限(单程 + 半个 60Hz 间隔,封顶 50ms = 3 tick)
const BASE_CONTACT_TOL := 8.0  # 与 PredictionRollback.DEFAULT_CONTACT_POS_TOL 同值(旧行为下限)
const MAX_CONTACT_TOL := 48.0
# 贴身容差的**迟滞**(秒):离开贴身区后仍按贴身容差放行一小段。★ 测因:尸体/挡住后的脱离那一瞬,
# 速度差还没收敛(实测 vel_err 100~350 持续 5~10 个 ack),而 `in_contact` 已翻 false ⇒ 容差瞬间掉回 2/20px
# ⇒ 每个 ack 一次回滚(soak 里非接触 pos 失败多半是这一档)。150ms ≈ 9 tick,比幽灵滞后(≤3 tick)留 3 倍余量。
const CONTACT_GRACE_S := 0.15


# 迟滞计时(纯函数,冒烟可测):贴身当帧刷新为 CONTACT_GRACE_S,否则按 delta 递减到 0。
static func grace_after(left_s: float, delta: float, contact_now: bool) -> float:
	if contact_now:
		return CONTACT_GRACE_S
	return maxf(0.0, left_s - maxf(delta, 0.0))


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
const TOL_MODEL_FACTOR := 2.0

static func contact_tol(rel_speed: float, anchor_speed: float, horizon_s: float) -> float:
	var h := clampf(horizon_s, 0.0, MAX_LAG_S)
	var drift := maxf(absf(rel_speed), absf(anchor_speed)) * h * TOL_MODEL_FACTOR
	return clampf(BASE_CONTACT_TOL + drift, BASE_CONTACT_TOL, MAX_CONTACT_TOL)


# 预测身位与幽灵体的间隙是否进入贴身区。
static func is_contact(gap: float) -> bool:
	return gap <= CONTACT_GAP
