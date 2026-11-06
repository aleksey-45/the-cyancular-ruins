extends RefCounted


const SUB_TS: float = 32.0

static func trace(origin: Vector2, dir: Vector2, max_len: float, max_bounces: int) -> Dictionary:
	var grid := MazeGenerator.current_grid
	var pts := PackedVector2Array([origin])
	var cells: Array = []
	var hit_pts := PackedVector2Array()
	if grid.is_empty():
		pts.append(origin + dir.normalized() * max_len)
		return {"points": pts, "contacts": cells, "hit_points": hit_pts}
	var cols := grid[0].size()
	var rows := grid.size()
	var sub_cols := cols * 2
	var sub_rows := rows * 2
	var p := origin
	var d := dir.normalized()
	if d == Vector2.ZERO:
		d = Vector2.RIGHT
	var traveled := 0.0
	var bounces := 0
	var guard := 0
	while guard < 10000:
		guard += 1
		var remaining := max_len - traveled
		if remaining <= 0.0:
			break
		var sx := floori(p.x / SUB_TS)
		var sy := floori(p.y / SUB_TS)
		var tx := INF
		var ty := INF
		if d.x > 0.0:
			tx = ((sx + 1) * SUB_TS - p.x) / d.x
		elif d.x < 0.0:
			tx = (sx * SUB_TS - p.x) / d.x
		if d.y > 0.0:
			ty = ((sy + 1) * SUB_TS - p.y) / d.y
		elif d.y < 0.0:
			ty = (sy * SUB_TS - p.y) / d.y
		var t := minf(tx, ty)
		if is_inf(t):
			pts.append(p + d * remaining)
			break
		if t <= 1e-9:
			p += d * 0.25
			continue
		if t > remaining:
			pts.append(p + d * remaining)
			break
		var q := p + d * t
		var cross_x := tx <= ty
		var nsx := sx
		var nsy := sy
		if cross_x:
			nsx = sx + (1 if d.x > 0.0 else -1)
		else:
			nsy = sy + (1 if d.y > 0.0 else -1)
		var gx := posmod(nsx, sub_cols)
		var gy := posmod(nsy, sub_rows)
		var cell := Vector2i(gx / 2, gy / 2)
		var solid := false
		var v: int = grid[cell.y][cell.x]
		if v != 0 and TileDefs.is_blocked(v):
			var shape := MazeGenerator.shape_of(v)
			if shape & (1 << (gy % 2 * 2 + gx % 2)):
				solid = true
		if not solid:
			p = q
			traveled += t
			continue
		pts.append(q)
		cells.append(cell)
		hit_pts.append(q)
		traveled += t
		if bounces < max_bounces:
			bounces += 1
			if cross_x:
				d.x = -d.x
			else:
				d.y = -d.y
			p = q + d * 0.5
		else:
			break
	return {"points": pts, "contacts": cells, "hit_points": hit_pts}
