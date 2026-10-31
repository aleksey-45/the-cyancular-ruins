class_name SpawnChooser
extends RefCounted

# 出生点的**唯一随机选格实现**(1v1 / 大乱斗 / 对抗模式共用):纯静态、不引 autoload / Node ⇒ `-s` 可测。
# ★ 输入是「本局可用的点名列表」—— 由地图 meta 的 `# respawn <side> <col> <row>` 行提供(MapFormat 解析),本类**不生成**候选:
#   点合理不合理是地图数据的责任(规则侧由 tools/map_spawn_meta.gd 与 map_spawn_data_probe 校验)。
# 约束分两层:
#   · exclude(绝不选中的格,如"本 role 上一次出生点")= 硬约束;若整个列表都被排除,按"宁可退化也别回 (-1,-1)"让位。
#   · min_dist(与 anchors 各格的环面距离)= 软约束:每轮按 RELAX_STEP 放宽,直到 0 —— 点不够是地图数据的边界,不该把人甩到墙角。
# ★ 随机源 = 调用方传的 RandomNumberGenerator(rng == null 用全局 RNG,生产路径;测试传定 seed 的 rng 才能复现)。

const RELAX_STEP := 5   # 最小间距的逐级放宽步长(与大乱斗散点 / 单机铺点的既有步长一致)

# ── 阵营半区(侧)定义 ── 1v1 / 对抗按侧出生:侧 1 = 左半(x < cols/2)、侧 2 = 右半(x >= cols/2)。
# ★ 环面世界:左右接缝在 x=0,所以两半在接缝两侧也相邻 —— 这是世界几何的固有边界,不改变"各占半区"的定义。
# ★ 大乱斗无阵营 ⇒ 用两侧列表的并集(全图散布),不走 side_of。
const SIDE_LEFT := 1
const SIDE_RIGHT := 2
# 数据规则(工具/探针用,运行时选点不需要):复活点离本侧的两条边界(接缝 / 半区中线)至少这么多格。
# ★ 环面上"两半"在接缝与中线两处都相邻 —— 贴边的点会让对面半区的点落在几格内。
const SIDE_EDGE_MARGIN := 10


static func side_of(cell: Vector2i, dims: Vector2i) -> int:
	if dims.x <= 0:
		return SIDE_LEFT
	return SIDE_LEFT if cell.x < dims.x / 2 else SIDE_RIGHT


# 该侧的 x 起点(左半 0 / 右半 cols/2);"是否在自己半区"与 3×3 桶划分都用它。
static func side_offset(side: int, dims: Vector2i) -> int:
	return 0 if side == SIDE_LEFT else dims.x / 2


# 数据规则(工具/探针用,运行时选点不需要):点要离本侧的**两条边界** —— 环面接缝(x=0 / x=cols)与半区中线
# (x=cols/2)—— 都 ≥ `SIDE_EDGE_MARGIN` 格。理由:环面上"两半"在接缝与中线两处都相邻,贴边的点会让对面半区的
# 点落在几格内("各占半区"就只在名字上成立),队间/两人也可能开局贴脸。
static func side_inside_margin(cell: Vector2i, side: int, dims: Vector2i) -> bool:
	var half := dims.x / 2
	if side == SIDE_LEFT:
		return cell.x >= SIDE_EDGE_MARGIN and cell.x < half - SIDE_EDGE_MARGIN
	return cell.x >= half + SIDE_EDGE_MARGIN and cell.x < dims.x - SIDE_EDGE_MARGIN


# 半区内的 3×3 "均匀散布"桶(返回 0..8;列以半区宽度为范围、行以整幅地图高度为范围)。
# ★ 工具 `--check` 与探针的"每桶 ≥1"都读这一份划分,不各自再算一遍。
static func bucket_of(cell: Vector2i, side: int, dims: Vector2i) -> int:
	var half := maxi(dims.x / 2, 1)
	var rel := cell.x - side_offset(side, dims)
	var bx := clampi(int(rel * 3 / half), 0, 2)
	var by := clampi(int(cell.y * 3 / maxi(dims.y, 1)), 0, 2)
	return by * 3 + bx


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
