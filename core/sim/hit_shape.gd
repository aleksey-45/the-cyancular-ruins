extends RefCounted

# 受击判定几何的唯一入口:子弹 / 敌弹 / 激光 / 爆炸 / 客户端 cull / 服务器裁决都走这里。
# ★ 受击面与移动碰撞箱分离:物理碰撞箱只负责移动,受击面由目标 hurt_rect() 给(玩家=当前姿态箱,敌人=活动箱)。
# ★ 纯静态、不引 autoload(环面 w/h 由调用方传)⇒ -s 冒烟里 autoload 未实例化也能跑。

const HURT_MARGIN: float = 0.0   # 受击面外扩(px):默认 0 不改变平衡,要调手感只动这一个数
const FALLBACK_HALF: float = 18.0   # 无碰撞体实体按 ±18px 半身兜底(与旧激光兜底一致)

## 活动碰撞箱的世界 AABB(只并启用中的箱;无碰撞体回退兜底框)。
static func rect_of(node: Node2D) -> Rect2:
	if node == null:
		return Rect2()
	if CollisionAabb.has_any(node):
		return CollisionAabb.world_rect(node)
	var half := Vector2(FALLBACK_HALF, FALLBACK_HALF)
	return Rect2(node.global_position - half, half * 2.0)

## 受击面 = rect_of + 统一 margin;伤害判定只许读本函数,不许各自再 grow。
static func hurt_rect_of(node: Node2D) -> Rect2:
	var r := rect_of(node)
	return r if is_zero_approx(HURT_MARGIN) else r.grow(HURT_MARGIN)

## 能否被打中:collision_layer=0 的实体(回溯保留的隐藏尸体)已无可碰撞面,不该吃判定。
static func hurtable(node: Node) -> bool:
	if node == null:
		return false
	if node.has_method("is_hurtable"):
		return bool(node.call("is_hurtable"))
	var co := node as CollisionObject2D
	return co == null or co.collision_layer != 0

## 把矩形平移到离 anchor 最近的环面副本(整幅平移,形状不变)。
static func rect_at(rect: Rect2, anchor: Vector2, w: float, h: float) -> Rect2:
	var c := rect.get_center()
	var off := Vector2.ZERO
	if w > 0.0:
		off.x = w * roundf((anchor.x - c.x) / w)
	if h > 0.0:
		off.y = h * roundf((anchor.y - c.y) / h)
	return Rect2(rect.position + off, rect.size)

## 宽相位 AABB 粗筛:线段 a→b 的轴对齐扫掠框,与受击面的**最近环面副本**是否可能相交。
## ★ 只许「放过」不许「漏」:精确判中的必须返回 true(多余的 true 只是白跑一次精确,结果仍由 segment_hits_rect 定)。
## ★ 比较必须含边界:segment_hits_rect 贴边/相切算中,而 Rect2.intersects 默认排斥边界、Rect2.encloses 更强 ⇒ 两者都会漏。
## ★ grow 必须算:擦边命中靠子弹体积外扩(见 bullet_base.hit_grow),漏掉它会把真命中筛掉。
static func sweep_may_hit(a: Vector2, b: Vector2, rect: Rect2, torus_w: float = 0.0, torus_h: float = 0.0,
		grow: Vector2 = Vector2.ZERO) -> bool:
	var r := rect_at(rect, a, torus_w, torus_h)
	if not grow.is_zero_approx():
		r = Rect2(r.position - grow, r.size + grow * 2.0)
	var lo := Vector2(minf(a.x, b.x), minf(a.y, b.y))
	var hi := Vector2(maxf(a.x, b.x), maxf(a.y, b.y))
	return lo.x <= r.end.x and hi.x >= r.position.x and lo.y <= r.end.y and hi.y >= r.position.y

## 线段 vs 矩形(Liang-Barsky)。命中返回 t∈[0,1](起点在框内=0,贴边/相切算中);未中返回 -1。grow = 子弹体积外扩(世界轴半展)。
static func segment_hits_rect(a: Vector2, b: Vector2, rect: Rect2, torus_w: float = 0.0, torus_h: float = 0.0,
		grow: Vector2 = Vector2.ZERO) -> float:
	var r := rect_at(rect, a, torus_w, torus_h)
	if not grow.is_zero_approx():
		r = Rect2(r.position - grow, r.size + grow * 2.0)
	var d := b - a
	var t0 := 0.0
	var t1 := 1.0
	for axis in 2:
		if absf(d[axis]) < 1e-9:
			if a[axis] < r.position[axis] or a[axis] > r.end[axis]:
				return -1.0
			continue
		var inv := 1.0 / d[axis]
		var ta := (r.position[axis] - a[axis]) * inv
		var tb := (r.end[axis] - a[axis]) * inv
		if ta > tb:
			var tmp := ta
			ta = tb
			tb = tmp
		t0 = maxf(t0, ta)
		t1 = minf(t1, tb)
		if t0 > t1:
			return -1.0
	return t0

## 单个候选(一个受击面)的最终判定 = AABB 粗筛 → 精确。exact_only=true 是「直接精确」旧路径,只给等价性守卫用。
## ★ 两条路径必须逐例同判:粗筛是纯门(gate),不把任何数值喂给精确那一步 ⇒ 命中结果与命中顺序逐位不变。
static func candidate_hits(a: Vector2, b: Vector2, rect: Rect2, w: float, h: float,
		grow: Vector2, exact_only: bool = false) -> bool:
	if not exact_only and not sweep_may_hit(a, b, rect, w, h, grow):
		return false
	return segment_hits_rect(a, b, rect, w, h, grow) >= 0.0

## 线段与矩形相交的入射点(未中返回 (INF,0))。
static func segment_entry_point(a: Vector2, b: Vector2, rect: Rect2) -> Vector2:
	var t := segment_hits_rect(a, b, rect)
	return Vector2(INF, 0.0) if t < 0.0 else a + (b - a) * t

## 点到矩形的最短距离(框内 = 0)。
static func distance_px_to_rect(p: Vector2, rect: Rect2) -> float:
	var dx := maxf(maxf(rect.position.x - p.x, p.x - rect.end.x), 0.0)
	var dy := maxf(maxf(rect.position.y - p.y, p.y - rect.end.y), 0.0)
	return sqrt(dx * dx + dy * dy)

## 同上,先把矩形锚到离 anchor 最近的环面副本(爆炸这类点口径用)。
static func distance_px_to_rect_at(p: Vector2, rect: Rect2, anchor: Vector2, w: float, h: float) -> float:
	return distance_px_to_rect(p, rect_at(rect, anchor, w, h))

## 多矩形取最早命中:返回 {t, index};全不中返回空字典。
static func first_hit(a: Vector2, b: Vector2, rects: Array[Rect2], anchor: Vector2, w: float, h: float) -> Dictionary:
	var best_t := INF
	var best_i := -1
	for i in rects.size():
		var t := segment_hits_rect(a, b, rects[i], w, h)
		if t >= 0.0 and t < best_t:
			best_t = t
			best_i = i
	if best_i < 0:
		return {}
	return {"t": best_t, "index": best_i}
