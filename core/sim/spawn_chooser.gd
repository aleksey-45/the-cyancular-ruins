class_name SpawnChooser
extends RefCounted

# 出生点的**唯一随机选格实现**(1v1 / 大乱斗 / 团队模式共用):纯静态、不引 autoload / Node ⇒ `-s` 可测。
# ★ 输入是「本局可用的点名列表」—— 由地图 meta 的 `# spawn` / `# teamspawn` 行提供(MapFormat 解析),本类**不生成**候选:
#   点合理不合理是地图数据的责任(规则侧由 tools/map_spawn_meta.gd 与 map_spawn_data_probe 校验)。
# 约束分两层:
#   · exclude(绝不选中的格,如"本 role 上一次出生点")= 硬约束;若整个列表都被排除,按"宁可退化也别回 (-1,-1)"让位。
#   · min_dist(与 anchors 各格的环面距离)= 软约束:每轮按 RELAX_STEP 放宽,直到 0 —— 点不够是地图数据的边界,不该把人甩到墙角。
# ★ 随机源 = 调用方传的 RandomNumberGenerator(rng == null 用全局 RNG,生产路径;测试传定 seed 的 rng 才能复现)。

const RELAX_STEP := 5   # 最小间距的逐级放宽步长(与大乱斗散点 / 单机铺点的既有步长一致)


# 在 candidates 里随机挑一个满足约束的格;candidates 为空 → Vector2i(-1, -1)。
# exclude: 硬排除(上一次位置);anchors: 已占格(不与它们同格,且尽量与它们保持 min_dist);dims = (cols, rows)。
# min_dist <= 0 / dims 非正 / anchors 空 ⇒ 只做排除。四档退化:严格 → 逐级放宽 → 忽略间距 → 连 exclude 也让位。
static func pick(candidates: Array, exclude: Array = [], rng: RandomNumberGenerator = null,
		min_dist: int = 0, anchors: Array = [], dims: Vector2i = Vector2i.ZERO) -> Vector2i:
	if candidates.is_empty():
		return Vector2i(-1, -1)
	var usable: Array = []
	for c in candidates:
		if exclude.has(c) or anchors.has(c):
			continue
		usable.append(c)
	if usable.is_empty():
		for c in candidates:
			if not anchors.has(c):
				usable.append(c)
	if usable.is_empty():
		return Vector2i(-1, -1)
	if min_dist > 0 and not anchors.is_empty() and dims.x > 0 and dims.y > 0:
		var relaxed := min_dist
		while relaxed > 0:
			var far: Array = []
			for c in usable:
				if _far_from_all(c, anchors, relaxed, dims):
					far.append(c)
			if not far.is_empty():
				return _sample(far, rng)
			relaxed -= RELAX_STEP
	return _sample(usable, rng)


# 一次挑 count 个互不相同的格:逐个 pick,已选的格既进 exclude(不再重复)也进 anchors(保持 min_dist)。
# ★ 列表不足 count 时返回能挑到的全部(不凭空造格);调用方按返回值.size() 决定是否回退其它来源。
static func pick_many(candidates: Array, count: int, rng: RandomNumberGenerator = null,
		min_dist: int = 0, dims: Vector2i = Vector2i.ZERO, exclude: Array = []) -> Array:
	var out: Array = []
	if count <= 0:
		return out
	var banned: Array = exclude.duplicate()
	while out.size() < count:
		var c := pick(candidates, banned, rng, min_dist, out, dims)
		if c.x < 0:
			break
		out.append(c)
		banned.append(c)
	return out


static func _far_from_all(c: Vector2i, anchors: Array, min_dist: int, dims: Vector2i) -> bool:
	for a in anchors:
		if GridPathfinder.toroidal_dist(c, a, dims.x, dims.y) < min_dist:
			return false
	return true


static func _sample(pool: Array, rng: RandomNumberGenerator) -> Vector2i:
	var i: int
	if rng != null:
		i = rng.randi_range(0, pool.size() - 1)
	else:
		i = randi_range(0, pool.size() - 1)
	return pool[i]
