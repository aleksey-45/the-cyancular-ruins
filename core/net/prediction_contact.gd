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
# ★ 2026-10-31:drift 取「相对速度」与「幽灵锚点自身速度」的**大者** —— 本地玩家是被**幽灵所在位置**挡住/推开的,
#   所以即使双方同速同向(相对速度≈0),预测位置与服务器仍差 |v_ghost|×horizon(跑速 700 ⇒ 35px);
#   只按相对速度算会让这一档恒用 8px ⇒ 每 5~6 个 ack 回滚一次(实测 3 客户端 soak:接触期 pos 分歧 p50≈10~26px)。
# ★ TOL_MODEL_FACTOR:实测残差 = pos_err / 计算容差,p50≈1.1~1.5、p90≈1.7~2.0 ⇒ 模型系统性偏紧一倍;
#   乘 2 后 pos 类回滚剩 ~9~12%(仍被 48px 封顶兜住,不会无限放宽)。
const TOL_MODEL_FACTOR := 2.0

static func contact_tol(rel_speed: float, anchor_speed: float, horizon_s: float) -> float:
	var h := clampf(horizon_s, 0.0, MAX_LAG_S)
	var drift := maxf(absf(rel_speed), absf(anchor_speed)) * h * TOL_MODEL_FACTOR
	return clampf(BASE_CONTACT_TOL + drift, BASE_CONTACT_TOL, MAX_CONTACT_TOL)


# 预测身位与幽灵体的间隙是否进入贴身区。
static func is_contact(gap: float) -> bool:
	return gap <= CONTACT_GAP
