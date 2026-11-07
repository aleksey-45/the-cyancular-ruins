class_name CollisionBuilder
extends RefCounted


const SUB_TS: int = 16
const TILE_TS: int = GameParameters.TILE_SIZE
const CHUNK_CELLS: int = 12
const LEDGE_THICKNESS: int = 6

static func chunk_of(cell: Vector2i) -> Vector2i:
	return Vector2i(cell.x / CHUNK_CELLS, cell.y / CHUNK_CELLS)


# 单个 16px 子格纹理 → 可破坏层碰撞值(EMPTY / SOLID)。★ build_sub 与「增量换局复位」共用这一条判据,别抄第二份:
# 判据 = 墙类型 + 可被子弹/爆炸破坏(与 build_sim 建局时的可破坏分块完全同源)。
static func destructible_value(tex: int) -> int:
	if tex == 0:
		return MazeGenerator.EMPTY
	if TileDefs.type_id_of(tex) != TileDefs.TYPE_WALL:
		return MazeGenerator.EMPTY
	if not (TileDefs.bullet_destroyable(tex) or TileDefs.explosion_destroyable(tex)):
		return MazeGenerator.EMPTY
	return MazeGenerator.SOLID


static func build_sub(grid: Array[Array], only_destructible: bool) -> Array[Array]:
	var sgrid: Array[Array] = MazeGenerator.current_subgrid
	if sgrid.is_empty():
		sgrid = MapFormat.expand_cells_to_subgrid(grid)
	var cols = sgrid[0].size()
	var rows = sgrid.size()
	var sub: Array[Array] = []
	for _r in rows:
		var srow: Array[int] = []
		srow.resize(cols)
		srow.fill(MazeGenerator.EMPTY)
		sub.append(srow)
	for y in rows:
		var srow: Array = sgrid[y]
		for x in cols:
			var tex: int = srow[x]
			if tex == 0:
				continue
			if TileDefs.sub_cols != 0 and not TileDefs.sub_alive(Vector2i(x, y)):
				continue
			if TileDefs.type_id_of(tex) != TileDefs.TYPE_WALL:
				continue
			var destr: bool = destructible_value(tex) != MazeGenerator.EMPTY
			if destr != only_destructible:
				continue
			sub[y][x] = MazeGenerator.SOLID
	return sub


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
			var x2 := x
			while x2 + 1 < x1 and sub[y][x2 + 1] != MazeGenerator.EMPTY and not used[y - y0][x2 + 1 - x0]:
				x2 += 1
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
			for ry in range(y, y2 + 1):
				for rx in range(x, x2 + 1):
					used[ry - y0][rx - x0] = true
			var shape := RectangleShape2D.new()
			shape.size = Vector2((x2 - x + 1) * ts, (y2 - y + 1) * ts)
			rects.append([shape, Vector2((x + x2 + 1) * 0.5 * ts, (y + y2 + 1) * 0.5 * ts)])
	return rects


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


static func build_permanent(sub: Array[Array], parent: Node, node_name: String) -> int:
	var cols = sub[0].size()
	var rows = sub.size()
	var rects := _greedy_region(sub, Rect2i(0, 0, cols, rows), SUB_TS)
	var total := _instantiate(rects, parent, node_name, cols, rows, SUB_TS)
	print("[CollisionBuilder] %s shapes: %d" % [node_name, total])
	return total


static func build_destructible_chunks(sub: Array[Array], parent: Node) -> int:
	var total := 0
	for chy in range(ceili(sub.size() / float(CHUNK_CELLS * 4))):
		for chx in range(ceili(sub[0].size() / float(CHUNK_CELLS * 4))):
			total += rebuild_chunk(sub, Vector2i(chx, chy), parent)
	return total


static func rebuild_chunk(sub: Array[Array], chunk: Vector2i, parent: Node) -> int:
	var cols = sub[0].size()
	var rows = sub.size()
	var srect := Rect2i(chunk.x * CHUNK_CELLS * 4, chunk.y * CHUNK_CELLS * 4,
			CHUNK_CELLS * 4, CHUNK_CELLS * 4)
	var rects := _greedy_region(sub, srect, SUB_TS)
	return _instantiate(rects, parent, _chunk_node_name(chunk), cols, rows, SUB_TS)


static func _chunk_node_name(chunk: Vector2i) -> String:
	return "DestructibleChunk_%d_%d" % [chunk.x, chunk.y]


static func build_climb_ledges(grid: Array[Array], parent: Node) -> int:
	var cols = grid[0].size()
	var rows = grid.size()
	var rects: Array = []
	var thin := RectangleShape2D.new()
	thin.size = Vector2(TILE_TS, LEDGE_THICKNESS)
	for y in rows:
		for x in cols:
			var v: int = grid[y][x]
			if v == 0:
				continue
			var tex: int = MazeGenerator.texture_of(v)
			var top := Vector2(x * TILE_TS + TILE_TS * 0.5, y * TILE_TS + LEDGE_THICKNESS * 0.5)
			var bottom := Vector2(x * TILE_TS + TILE_TS * 0.5, y * TILE_TS + TILE_TS - LEDGE_THICKNESS * 0.5)
			if tex == 12:
				rects.append([thin, top])
			elif tex == 14:
				rects.append([thin, bottom])
	return _instantiate(rects, parent, "ClimbLedges", cols, rows, TILE_TS)
