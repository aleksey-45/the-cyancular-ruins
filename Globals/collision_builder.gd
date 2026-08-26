class_name CollisionBuilder
extends RefCounted

# 碰撞层构建(独立于场景,便于 -s 探针直接调用;不引用 autoload GameParameters)。
# 思路:
# - 从 125×75 网格展开成 250×150 的 32px 子格(每 64px 格 → 2×2),只保留有实体碰撞的格。
# - 永久墙(不可破坏)建一个整图节点,贪心合并一次建好、之后不动。
# - 可破坏层(树叶/树干)按「分块」存节点:块边长 = 地图边长开根号(√125≈11 → 取 12 格),
#   瓦片被摧毁时只重建所在块,重建成本 O(块面积) 与整图无关。
#   块间不做跨块合并 → 块边界矩形不再合并(形状数略增,但物理层可接受)。
# - 每块矩形按 9 个环面副本偏移实例化(3×3 覆盖,玩家/子弹/敌人才能跨接缝),共享同一 shape。

const SUB_TS: int = 32        # 32px 子格(64px 格 → 2×2 子格)
const TILE_TS: int = 64       # 64px 格边长(SUB_TS×2,不引 autoload GameParameters)
const CHUNK_CELLS: int = 12   # 块边长(64px 格)≈ √地图边长(125)
const LEDGE_THICKNESS: int = 6  # 攀爬结构基座薄碰撞条厚度(px)

# 64px 格坐标 → 所在块(格坐标/块边长,整除)。
static func chunk_of(cell: Vector2i) -> Vector2i:
	return Vector2i(cell.x / CHUNK_CELLS, cell.y / CHUNK_CELLS)


# 从网格提取 250×150 的 32px 子格。only_destructible=false 只收永久墙;true 只收可破坏。
# 通道/液体/气体无实体碰撞(可走/可爬),不进子格。
static func build_sub(grid: Array[Array], only_destructible: bool) -> Array[Array]:
	var cols = grid[0].size()   # 125
	var rows = grid.size()      # 75
	var sub: Array[Array] = []
	for _r in range(rows * 2):
		var srow: Array[int] = []
		srow.resize(cols * 2)
		srow.fill(MazeGenerator.EMPTY)
		sub.append(srow)
	for y in range(rows):
		for x in range(cols):
			var v: int = grid[y][x]
			var shape: int = MazeGenerator.shape_of(v)
			if shape == 0:
				continue
			var tex: int = MazeGenerator.texture_of(v)
			if TileDefs.type_of(tex) != "wall":
				continue  # 通道/液体/气体无实体碰撞(可走/可爬)
			var destr: bool = TileDefs.bullet_destroyable(tex) or TileDefs.explosion_destroyable(tex)
			if destr != only_destructible:
				continue
			for qy in range(2):
				for qx in range(2):
					if shape & (1 << (qy * 2 + qx)):
						sub[y * 2 + qy][x * 2 + qx] = MazeGenerator.SOLID
	return sub


# 对 sub 的 sub_rect 区域做一次贪心合并(先横向扩展、再纵向扩展、标记已访问)。
# 只在该区域内扩展/标记 → 矩形不跨区域边界合并。返回每块 [RectangleShape2D, 中心副本位置]。
static func _greedy_region(sub: Array[Array], sub_rect: Rect2i, ts: int) -> Array:
	var x0 := maxi(sub_rect.position.x, 0)
	var y0 := maxi(sub_rect.position.y, 0)
	var x1 := mini(sub_rect.position.x + sub_rect.size.x, sub[0].size())
	var y1 := mini(sub_rect.position.y + sub_rect.size.y, sub.size())
	var w := x1 - x0
	var used: Array[Array] = []
	for _r in range(y0, y1):
		var urow: Array[bool] = []
		urow.resize(w)
		urow.fill(false)
		used.append(urow)
	var rects: Array = []
	for y in range(y0, y1):
		for x in range(x0, x1):
			if sub[y][x] == MazeGenerator.EMPTY or used[y - y0][x - x0]:
				continue
			# 横向扩展整行连续墙段
			var x2 := x
			while x2 + 1 < x1 and sub[y][x2 + 1] != MazeGenerator.EMPTY and not used[y - y0][x2 + 1 - x0]:
				x2 += 1
			# 纵向扩展:要求下行整段都是未访问的墙
			var y2 := y
			while y2 + 1 < y1:
				var can := true
				for cx in range(x, x2 + 1):
					if sub[y2 + 1][cx] == MazeGenerator.EMPTY or used[y2 + 1 - y0][cx - x0]:
						can = false
						break
				if not can:
					break
				y2 += 1
			# 标记该矩形覆盖的格子已访问
			for ry in range(y, y2 + 1):
				for rx in range(x, x2 + 1):
					used[ry - y0][rx - x0] = true
			var shape := RectangleShape2D.new()
			shape.size = Vector2((x2 - x + 1) * ts, (y2 - y + 1) * ts)
			rects.append([shape, Vector2((x + x2 + 1) * 0.5 * ts, (y + y2 + 1) * 0.5 * ts)])
	return rects


# 把 rects 实例化到 parent 下名为 node_name 的 StaticBody2D:每块矩形按 9 个环面副本
# 偏移(tx*cols*ts, ty*rows*ts),9 副本共享同一 RectangleShape2D。返回总 shape 数。
static func _instantiate(rects: Array, parent: Node, node_name: String, cols: int, rows: int, ts: int) -> int:
	var existing := parent.get_node_or_null(node_name)
	if existing != null:
		existing.free()
	var walls := StaticBody2D.new()
	walls.name = node_name
	parent.add_child(walls)
	var total := 0
	for r in rects:
		var shape: RectangleShape2D = r[0]
		var pos: Vector2 = r[1]
		for ty in range(-1, 2):
			for tx in range(-1, 2):
				var col := CollisionShape2D.new()
				col.shape = shape
				col.position = pos + Vector2(tx * cols * ts, ty * rows * ts)
				walls.add_child(col)
				total += 1
	return total


# 建永久墙整图碰撞节点(整图一次贪心,建一次不动)。返回 shape 数。
static func build_permanent(sub: Array[Array], parent: Node, node_name: String) -> int:
	var cols = sub[0].size()
	var rows = sub.size()
	var rects := _greedy_region(sub, Rect2i(0, 0, cols, rows), SUB_TS)
	var total := _instantiate(rects, parent, node_name, cols, rows, SUB_TS)
	print("[CollisionBuilder] %s shapes: %d" % [node_name, total])
	return total


# 建可破坏层所有分块节点。返回总 shape 数。
static func build_destructible_chunks(sub: Array[Array], parent: Node) -> int:
	var total := 0
	for chy in range(ceili(sub.size() / float(CHUNK_CELLS * 2))):
		for chx in range(ceili(sub[0].size() / float(CHUNK_CELLS * 2))):
			total += rebuild_chunk(sub, Vector2i(chx, chy), parent)
	return total


# 重建指定块(块坐标 = 格坐标/CHUNK_CELLS)。返回该块 shape 数。
static func rebuild_chunk(sub: Array[Array], chunk: Vector2i, parent: Node) -> int:
	var cols = sub[0].size()
	var rows = sub.size()
	var srect := Rect2i(chunk.x * CHUNK_CELLS * 2, chunk.y * CHUNK_CELLS * 2,
			CHUNK_CELLS * 2, CHUNK_CELLS * 2)
	var rects := _greedy_region(sub, srect, SUB_TS)
	return _instantiate(rects, parent, _chunk_node_name(chunk), cols, rows, SUB_TS)


static func _chunk_node_name(chunk: Vector2i) -> String:
	return "DestructibleChunk_%d_%d" % [chunk.x, chunk.y]


# 攀爬结构基座薄碰撞条(仅锁链顶/底;梯子顶端不加——薄条会挡住从下方爬上梯顶,
# 梯顶"停留"由玩家攀附机制解决,见 player._update_climb)。
# - 锁链顶端:纹理 12 → 顶边薄条(全宽 × LEDGE_THICKNESS)。
# - 锁链底端:纹理 14 → 底边薄条。
# 复用 _instantiate 做 9 环面副本偏移,节点名 "ClimbLedges"。返回 shape 数。
static func build_climb_ledges(grid: Array[Array], parent: Node) -> int:
	var cols = grid[0].size()
	var rows = grid.size()
	var rects: Array = []
	var thin := RectangleShape2D.new()
	thin.size = Vector2(TILE_TS, LEDGE_THICKNESS)
	for y in range(rows):
		for x in range(cols):
			var v: int = grid[y][x]
			if v == 0:
				continue
			var tex: int = v / 16
			var top := Vector2(x * TILE_TS + TILE_TS * 0.5, y * TILE_TS + LEDGE_THICKNESS * 0.5)
			var bottom := Vector2(x * TILE_TS + TILE_TS * 0.5, y * TILE_TS + TILE_TS - LEDGE_THICKNESS * 0.5)
			if tex == 12:
				# 锁链顶端基座:顶边薄条 → 爬到链顶被挡停
				rects.append([thin, top])
			elif tex == 14:
				# 锁链底端基座:底边薄条 → 下到链底可落脚
				rects.append([thin, bottom])
	return _instantiate(rects, parent, "ClimbLedges", cols, rows, TILE_TS)
