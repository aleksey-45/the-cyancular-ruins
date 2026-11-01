class_name StepJump
extends RefCounted

# 自动跳跃判据(2026-11-01 用户要求:「小于等于一格会自动跳跃」)。
# 纯逻辑:把"脚底前方那一列、从脚底往上连续有多少个实体 16px 子格"当作台阶高度;
# 高度 1..4 子格(= ≤1 格 64px)⇒ 允许自动起跳;0 = 没挡路;>1 格 ⇒ 不跳(交给玩家自己按跳)。
# ★★ 判据的数据源必须是**两端同一份**:客户端预测与服务器重放要做出同一个决定,所以只看
#   cyrm v4 的 16px 子格纹理(经 `TileDefs.type_id_of` 判 wall),不看碰撞体/射线这类可能两端漂的物理状态。
# ★ 为什么用子格而不是 64px 格:碰撞是 16px 子格级的,台阶可能只有 16/32/48px 高 —— 只按整格判会漏掉矮台阶。
const SUB_PER_CELL := 4                    # 一格 = 4×4 个 16px 子格(与 cyrm v4 一致)
const MAX_STEP_SUBCELLS := SUB_PER_CELL    # "≤1 格" = 最多 4 个子格
const WALK_UP_MAX_SUBCELLS := 2            # ≤2 子格(32px)直接迈上去,不跳


# 返回前方台阶高度(子格数):
#   0  = 前方没挡路(照常走)
#   1..4 = ≤1 格高的台阶 ⇒ 调用方应自动起跳
#   -1 = 再往上还是实体(墙高于一格)⇒ 不自动跳
# solid_at: Callable(Vector2i 子格坐标) -> bool(该子格是否有碰撞)。
static func low_step_height(feet_sub: Vector2i, dir: int, solid_at: Callable) -> int:
	if dir == 0:
		return 0
	var ahead_x := feet_sub.x + dir
	var h := 0
	for k in MAX_STEP_SUBCELLS:
		if not bool(solid_at.call(Vector2i(ahead_x, feet_sub.y - k))):
			break
		h += 1
	if h == 0:
		return 0
	# 第 5 个子格还是实体 ⇒ 高度 > 1 格(2 格及以上的墙不该自动跳,否则玩家会对着墙反复起跳)
	if bool(solid_at.call(Vector2i(ahead_x, feet_sub.y - MAX_STEP_SUBCELLS))):
		return -1
	return h


# 矮台阶直接"迈上去"、不跳。★ 2026-11-01:连续上台阶抖动(用户第三轮)的根源是每级台阶都触发一次自动跳:
# 起跳→上升→落地→再起跳,人一直在上下颠。≤2 子格(32px)的台阶脚一抬就上得去 ⇒ 直接抬起身体(保留横移),
# 只有 3~4 子格(48/64px)才起跳。返回 true = 走上去。
static func is_walk_up_step(height_subcells: int) -> bool:
	return height_subcells > 0 and height_subcells <= WALK_UP_MAX_SUBCELLS


# 跳到指定高度所需的上跳初速度:峰值高度 = h ⇔ v = -sqrt(2·g·h)。
# ★ 2026-11-01 用户裁定「跳跃高度应该和墙高度相同」:自动跳要用**刚好越过高台**的速度,
#   而不是整段满力跳(满力跳 ≈ 3 格,撞 16px 台阶会莫名其妙窜很高)。g 必须是两端同一个常量
#   (player.gd 的 `gravity` = PlayerParams.gravity0),否则预测/重放会算出不同速度。
static func jump_velocity_for_height(height_px: float, gravity: float) -> float:
	if gravity <= 0.0 or height_px <= 0.0:
		return 0.0
	return -sqrt(2.0 * gravity * height_px)
