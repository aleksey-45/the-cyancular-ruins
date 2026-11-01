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
