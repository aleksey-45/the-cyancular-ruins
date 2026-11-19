extends RefCounted

# 世界绘制:墙体图集、环面瓦片/水面铺贴、分帧碰撞构建、可破坏砖的回溯与换局复位。
# 世界状态(Level0 的 static 字段)与时间/碰撞账本都在 host 上,这里只放操作;依赖注入,不反向找 Level0。

# 只画真正可能出现在视口里的环带:视口 2208x1728 远小于地图,整圈 9 份全画是 5~6 倍浪费
# (贴图 24 万格 -> 4 万级;碰撞环带不在此列,见 CollisionBuilder)。中心份全画,其余按"该副本在源图里的可见条带"画。
const RING_VIEW_MARGIN_SUB := 8
const BOOT_BUDGET_US := 8000

var _host: Node = null
var _world_viewport: SubViewport = null


func setup(host: Node, world_viewport: SubViewport) -> void:
	_host = host
	_world_viewport = world_viewport


# 墙体/所有非空气砖的图集(16px 象限制,按描述符行烘:行 = 本图去重描述符,辅码颜色烘进像素)。
# 构造在 TerrainAtlas —— 主菜单背景要「真实的那个世界」,必须与这里用同一份映射(见 terrain_atlas.gd 文件头)。
func create_wall_tileset() -> Dictionary:
	var key := MazeGenerator.map_file_path()
	var built: Dictionary = _host._wall_ts_cache.get(key, {})
	if built.is_empty():
		built = TerrainAtlas.make_wall_tileset_for(collect_wall_descs())
		_host._wall_ts_cache[key] = built
	_host._desc_row = built["row_of"]
	return built


func collect_wall_descs() -> Array:
	var uniq := {}
	var sd := MazeGenerator.current_subdesc
	if sd.is_empty():
		for row in MazeGenerator.current_subgrid:
			for t in row:
				if int(t) != 0:
					uniq[MapFormatV4.neutral_descriptor(int(t))] = true
	else:
		for row in sd:
			for d in row:
				if int(d) != 0:
					uniq[int(d)] = true
	var out: Array = uniq.keys()
	out.sort()
	return out


func ring_copies() -> Array:
	var out: Array = []
	for ty in range(-1, 2):
		for tx in range(-1, 2):
			out.append(Vector2i(tx, ty))
	return out


func paint_cache_for_current_map() -> Dictionary:
	var key := MazeGenerator.map_file_path()
	var hit: Dictionary = _host._paint_cache.get(key, {})
	if not hit.is_empty():
		return hit
	var sg := MazeGenerator.current_subgrid
	var sd := MazeGenerator.current_subdesc
	var sc: int = sg[0].size()
	var sr: int = sg.size()
	var xs := PackedInt32Array()
	var ys := PackedInt32Array()
	xs.resize(sc * sr)
	ys.resize(sc * sr)
	var rows := PackedByteArray()
	rows.resize(sr)
	for y in sr:
		var row: Array = sg[y]
		var base := y * sc
		var any := false
		for x in sc:
			var tex: int = row[x]
			if tex == MazeGenerator.EMPTY or Water.is_liquid(tex):
				xs[base + x] = -1
				continue
			any = true
			xs[base + x] = (y % 4) * 4 + (x % 4)
			ys[base + x] = _host._wall_row(_host._desc_or_neutral(sd, y, x, tex))
		rows[y] = 1 if any else 0
	var out := {"x": xs, "y": ys, "rows": rows, "sc": sc, "sr": sr}
	_host._paint_cache[key] = out
	return out


func ring_visible_sub_rects() -> Array:
	var sc: int = MazeGenerator.current_subgrid[0].size()
	var sr: int = MazeGenerator.current_subgrid.size()
	var zoom := maxf(0.01, PlayerParams.cam_zoom)
	var wsub := mini(sc, ceili(float(_world_viewport.size.x) / (16.0 * zoom)) + RING_VIEW_MARGIN_SUB * 2)
	var hsub := mini(sr, ceili(float(_world_viewport.size.y) / (16.0 * zoom)) + RING_VIEW_MARGIN_SUB * 2)
	var out: Array = []
	for c: Vector2i in ring_copies():
		var x0 := 0
		var y0 := 0
		var x1 := sc
		var y1 := sr
		if c.x < 0:
			x0 = maxi(0, sc - wsub)
		elif c.x > 0:
			x1 = mini(sc, wsub)
		if c.y < 0:
			y0 = maxi(0, sr - hsub)
		elif c.y > 0:
			y1 = mini(sr, hsub)
		out.append([c, x0, y0, x1, y1])
	return out


# ★ 墙层与地形剪影层的唯一写点:漏镜像不会报错,只会让实体重新被地形受光/斜影误伤。
func set_wall_cell(cell: Vector2i, atlas: Vector2i) -> void:
	var wl: TileMapLayer = _host.wall_layer
	if wl != null:
		wl.set_cell(cell, 0, atlas)
	var tl: TileMapLayer = _host.terrain_layer
	if tl != null:
		tl.set_cell(cell, 0, atlas)


func erase_wall_cell(cell: Vector2i) -> void:
	var wl: TileMapLayer = _host.wall_layer
	if wl != null:
		wl.set_cell(cell, -1)
	var tl: TileMapLayer = _host.terrain_layer
	if tl != null:
		tl.set_cell(cell, -1)


func paint_maze_copies() -> void:
	var cache := paint_cache_for_current_map()
	var xs: PackedInt32Array = cache["x"]
	var ys: PackedInt32Array = cache["y"]
	var row_any: PackedByteArray = cache["rows"]
	var sc: int = cache["sc"]
	var sr: int = cache["sr"]
	for entry in ring_visible_sub_rects():
		var c: Vector2i = entry[0]
		var x0: int = entry[1]
		var y0: int = entry[2]
		var x1: int = entry[3]
		var y1: int = entry[4]
		var offset_x = c.x * sc
		var offset_y = c.y * sr
		for y in range(y0, y1):
			if row_any[y] == 0:
				continue
			var base := y * sc
			var oy: int = y + offset_y
			for x in range(x0, x1):
				var tx := xs[base + x]
				if tx < 0:
					continue
				set_wall_cell(Vector2i(x + offset_x, oy), Vector2i(tx, ys[base + x]))


func paint_water_copies(grid: Array[Array]) -> void:
	var ts := GameParameters.TILE_SIZE
	var cols := grid[0].size()
	var rows := grid.size()
	var surf: Node2D = _host.water_surface_layer
	var surface_by_desc: Dictionary = {}   # 描述符 → 该描述符下的所有液体格
	var wzoom := maxf(0.01, PlayerParams.cam_zoom)
	var x_limit := mini(cols, ceili(float(_world_viewport.size.x) / (float(ts) * wzoom)) + RING_VIEW_MARGIN_SUB / 4 + 1)
	var y_limit := mini(rows, ceili(float(_world_viewport.size.y) / (float(ts) * wzoom)) + RING_VIEW_MARGIN_SUB / 4 + 1)
	for entry in ring_visible_sub_rects():
		var c: Vector2i = entry[0]
		var x0: int = entry[1] / 4
		var y0: int = entry[2] / 4
		var x1: int = mini(cols, ceili(float(entry[3]) / 4.0))
		var y1: int = mini(rows, ceili(float(entry[4]) / 4.0))
		if c.x < 0:
			x0 = maxi(x0, cols - x_limit)
		elif c.x > 0:
			x1 = mini(x1, x_limit)
		if c.y < 0:
			y0 = maxi(y0, rows - y_limit)
		elif c.y > 0:
			y1 = mini(y1, y_limit)
		var ox := c.x * cols
		var oy := c.y * rows
		for y in range(y0, y1):
			var row: Array = grid[y]
			for x in range(x0, x1):
				var v: int = row[x]
				if v == MazeGenerator.EMPTY:
					continue
				if not Water.is_liquid(MazeGenerator.texture_of(v)):
					continue
				# ★ 所有液体格都进**同一条管线**(合批):水面砖 / 水体砖只是图集里不同的 UV 行,
				#   同色、同 alpha、同条纹、同起伏 —— 不存在"两层对不齐"的接缝。
				var above: int = grid[posmod(y - 1, rows)][x]
				var is_surface := above == 0 or not Water.is_liquid(MazeGenerator.texture_of(above))
				var d: int = _host._water_desc_of(v, x, y)
				if not surface_by_desc.has(d):
					surface_by_desc[d] = []
				(surface_by_desc[d] as Array).append({
					"pos": Vector2((x + ox) * ts + ts * 0.5, (y + oy) * ts + ts),
					"phase": (x + ox) * 1.7 + (y + oy) * 2.3,
					"surface": is_surface,
					"weight": 1.0 if is_surface else 0.0,   # ★ 只有水面格起伏
				})

	# ★ 按**描述符分桶**:每桶用自己的 tint 砖。水面若恒用中性砖,而水体按辅码 tint 过,
	#   两层就会有色差(registered-debt 里那条"水面合批不消费辅码")。
	for d in surface_by_desc:
		var cells: Array = surface_by_desc[d]
		if cells.is_empty():
			continue
		var tex := ImageTexture.create_from_image(make_water_atlas(ts, int(d)))
		var batch := WaterSurfaceBatch.new()
		batch.setup(cells, tex, ts)
		surf.add_child.call_deferred(batch)


func build_world_progressive(grid: Array[Array]) -> void:
	var t := Time.get_ticks_usec()
	LoadingScreen.set_progress(0.68, "碰撞:永久墙")
	var perm := CollisionBuilder.build_sub(grid, false)
	CollisionBuilder.build_permanent(perm, _world_viewport, "WallCollision")
	await _host.get_tree().process_frame
	t = Time.get_ticks_usec()
	LoadingScreen.set_progress(0.72, "碰撞:可破坏层")
	var sub := CollisionBuilder.build_sub(grid, true)
	var cw := ceili(sub[0].size() / float(CollisionBuilder.CHUNK_CELLS * 4))
	var ch := ceili(sub.size() / float(CollisionBuilder.CHUNK_CELLS * 4))
	var total := cw * ch
	var n := 0
	for chy in ch:
		for chx in cw:
			CollisionBuilder.rebuild_chunk(sub, Vector2i(chx, chy), _world_viewport)
			n += 1
			LoadingScreen.set_progress(0.72 + 0.26 * float(n) / float(maxi(total, 1)),
					"碰撞块 %d/%d" % [n, total])
			if Time.get_ticks_usec() - t >= BOOT_BUDGET_US:
				await _host.get_tree().process_frame
				t = Time.get_ticks_usec()
	CollisionBuilder.build_climb_ledges(grid, _world_viewport)
	_host._destructible_sub = sub
	LoadingScreen.set_progress(1.0, "完成")
	await _host.get_tree().process_frame
	_host.get_tree().paused = false
	await _host.get_tree().process_frame
	LoadingScreen.hide_loading()


func on_tile_destroyed(cell: Vector2i) -> void:
	TileDefs.destroy_cell(cell)


func on_sub_destroyed(sub: Vector2i, pre_hp: int, _owner: Node = null) -> void:
	_host._damaged_subs[sub] = true
	if _host._tile_ledger != null and TimeField.current != null \
			and not TimeField.current.is_rewinding() and _host.wall_layer != null:
		_host._tile_pending.append({"sub": sub, "hp": pre_hp})
	if _host.wall_layer != null:
		var sc: int = MazeGenerator.current_subgrid[0].size()
		var sr: int = MazeGenerator.current_subgrid.size()
		for ty in range(-1, 2):
			for tx in range(-1, 2):
				erase_wall_cell(Vector2i(sub.x + tx * sc, sub.y + ty * sr))
	if not _host._destructible_sub.is_empty():
		_host._destructible_sub[sub.y][sub.x] = MazeGenerator.EMPTY
		_host._dirty_chunks[CollisionBuilder.chunk_of(Vector2i(sub.x / 4, sub.y / 4))] = true


# PvP 换局复位(增量,2026-10-24):只还原「被拆过的 16px 子格」—— 全量重铺 9 环面副本实测 ~0.86s、整层碰撞重建 ~0.48s
func reset_destructibles() -> void:
	if _host._pristine_grid.is_empty() or _host._pristine_subgrid.is_empty():
		return
	var sc: int = (_host._pristine_subgrid[0] as Array).size()
	var sr: int = _host._pristine_subgrid.size()
	var subs: Dictionary = _host._damaged_subs.duplicate()
	var grid := MazeGenerator.current_grid
	for cy in grid.size():
		var row: Array = grid[cy]
		var prow: Array = _host._pristine_grid[cy]
		for cx in row.size():
			if row[cx] == prow[cx]:
				continue
			row[cx] = prow[cx]
			for sy in 4:
				for sx in 4:
					subs[Vector2i(cx * 4 + sx, cy * 4 + sy)] = true
	var chunks: Dictionary = {}
	var cells: Dictionary = {}
	for key in subs:
		var sub: Vector2i = key
		if sub.x < 0 or sub.y < 0 or sub.x >= sc or sub.y >= sr:
			continue
		var tex: int = int(_host._pristine_subgrid[sub.y][sub.x])
		TileDefs.restore_sub(sub, TileDefs.hp_of(tex) if tex != 0 else 0)
		if not _host._destructible_sub.is_empty():
			_host._destructible_sub[sub.y][sub.x] = CollisionBuilder.destructible_value(tex)
		if tex != 0:
			var atlas := Vector2i((sub.y % 4) * 4 + (sub.x % 4),
					_host._wall_row(_host._desc_or_neutral(_host._pristine_subdesc, sub.y, sub.x, tex)))
			for ty in range(-1, 2):
				for tx in range(-1, 2):
					set_wall_cell(Vector2i(sub.x + tx * sc, sub.y + ty * sr), atlas)
		var cell := Vector2i(sub.x / 4, sub.y / 4)
		chunks[CollisionBuilder.chunk_of(cell)] = true
		cells[cell] = true
	for cell in cells:
		TileDefs.set_hp_grid(cell, TileDefs.hp_of(MazeGenerator.texture_of(int(_host._pristine_grid[cell.y][cell.x]))))
	for ch in chunks:
		CollisionBuilder.rebuild_chunk(_host._destructible_sub, ch, _world_viewport)
	_host._dirty_chunks.clear()
	_host._damaged_subs.clear()


func rewind_elite_hits() -> void:
	var rw: WorldRewind = _host._rewind
	if rw == null:
		return
	var elites: Array = []
	for e in _host.get_tree().get_nodes_in_group("enemies"):
		if is_instance_valid(e) and e.has_meta("elite") and not bool(e.get("is_dead")):
			elites.append(e)
	if elites.is_empty():
		return
	for b in rw.replay_bullets():
		if not is_instance_valid(b):
			continue
		var dmg := int(b.get("hit_damage"))
		if dmg <= 0:
			continue
		var bp: Vector2 = (b as Node2D).global_position
		for e in elites:
			var ep: Vector2 = (e as Node2D).global_position
			var d := MazeGenerator.toroidal_delta_px(bp, ep,
					GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
			if d.length() > 42.0:
				continue
			var hit_ids: Array = b.get_meta("rw_hit_ids", [])
			if hit_ids.has(e.get_instance_id()):
				continue
			hit_ids.append(e.get_instance_id())
			b.set_meta("rw_hit_ids", hit_ids)
			var dir := d.normalized() if not d.is_zero_approx() else Vector2.RIGHT
			e.call("hurt", dmg, dir, float(b.get("hit_impact")))


func restore_sub(e: Dictionary) -> void:
	if _host._grid_ref.is_empty() or _host.wall_layer == null or MazeGenerator.current_subgrid.is_empty():
		return
	var sub: Vector2i = e["sub"]
	var hp := int(e["hp"])
	var sc: int = MazeGenerator.current_subgrid[0].size()
	var sr: int = MazeGenerator.current_subgrid.size()
	if sub.x < 0 or sub.y < 0 or sub.x >= sc or sub.y >= sr:
		return
	TileDefs.restore_sub(sub, hp)
	var tex := int(MazeGenerator.current_subgrid[sub.y][sub.x])
	var cell := Vector2i(sub.x / 4, sub.y / 4)
	if tex == 0:
		return
	var atlas_row: int = _host._wall_row(_host._desc_or_neutral(MazeGenerator.current_subdesc, sub.y, sub.x, tex))
	for ty in range(-1, 2):
		for tx in range(-1, 2):
			set_wall_cell(Vector2i(sub.x + tx * sc, sub.y + ty * sr),
					Vector2i((sub.y % 4) * 4 + (sub.x % 4), atlas_row))
	if not _host._destructible_sub.is_empty():
		_host._destructible_sub[sub.y][sub.x] = MazeGenerator.SOLID
		_host._dirty_chunks[CollisionBuilder.chunk_of(cell)] = true
	if _host._grid_ref[cell.y][cell.x] == 0 and not _host._pristine_grid.is_empty():
		_host._grid_ref[cell.y][cell.x] = _host._pristine_grid[cell.y][cell.x]
		if TileDefs.hp_grid_at(cell) <= 0:
			TileDefs.set_hp_grid(cell, TileDefs.hp_of(tex))


## 被合批用的两行图集:上半 = 水体砖,下半 = 水面砖,都按描述符 tint。
func make_water_atlas(ts: int, desc: int) -> Image:
	var img := Image.create(ts, ts * 2, false, Image.FORMAT_RGBA8)
	img.blit_rect(TerrainAtlas._tinted_water_brick(ts, desc), Rect2i(0, 0, ts, ts), Vector2i(0, 0))
	# 下半行 = **水面砖**(自带顶边水线),按同一描述符 tint:
	#   水面格用它,水线本来就画在贴图里,不需要后处理再画。
	var surf := TerrainAtlas.water_brick_image(ts, TerrainAtlas.WATER_SURFACE_BRICK).duplicate()
	for yy in ts:
		for xx in ts:
			surf.set_pixel(xx, yy, TerrainAtlas.tint_color(surf.get_pixel(xx, yy), desc))
	img.blit_rect(surf, Rect2i(0, 0, ts, ts), Vector2i(0, ts))
	return img
