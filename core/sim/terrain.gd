class_name Terrain
extends RefCounted

# 子格材质来自地图场景层。地形记录当前耐久度、碰撞形状和撤销日志。

const SUB_SIZE := CyrmMap.CELL_SIZE
const DAMAGE_BLOCK_SUBS := 32 / SUB_SIZE
const BEAM_BLOCK_SUBS := 64 / SUB_SIZE
const CHUNK_CELLS := 48
const LEDGE_THICKNESS := 6
const CACHE_STATES := 4

const PERMANENT_CHUNK := -1
const LEDGE_CHUNK := -2

class Chunk:
	var body := RID()
	var signature := PackedByteArray()
	var layouts: Dictionary[PackedByteArray, Array] = {}

var columns := 0
var rows := 0
var map_size := Vector2.ZERO
var version: int:
	get: return _version

var _version := 0
var _cells := PackedInt32Array()
var _hp := PackedInt32Array()
var _modified: Dictionary = {}
var _pending: Dictionary[int, int] = {}
# 当前版本减去日志长度就是尚可撤销到的起点。
var _undo: Array[Dictionary] = []
var _visual_changes: Dictionary = {}
var _chunk_columns := 0
var _chunk_dirty := PackedByteArray()
var _dirty_chunks := PackedInt32Array()
var physics: CollisionWorld
# 每个碰撞分块使用一个物理体。最后两项存放铁链端部的平台和不可破坏墙体。
var _chunks: Array[Chunk] = []
var _shape_rids: Dictionary = {}
var _placements: Array = []
var permanent_dirty := true
var ledges_dirty := true

func _init(map: Dictionary) -> void:
	columns = map.size.x
	rows = map.size.y
	map_size = Vector2(map.size * SUB_SIZE)
	_cells = map.layers[CyrmMap.SCENE]
	_hp.resize(_cells.size())
	for i in _cells.size():
		_hp[i] = TileDefs.hit_points[_material(i)]
	_chunk_columns = (columns + CHUNK_CELLS - 1) / CHUNK_CELLS
	_chunk_dirty.resize(_chunk_columns * ((rows + CHUNK_CELLS - 1) / CHUNK_CELLS))
	_chunk_dirty.fill(0)
	_chunks.resize(_chunk_dirty.size() + 2)
	for key in _chunks.size():
		_chunks[key] = Chunk.new()
	physics = CollisionWorld.new(map_size)
	for key in _chunk_dirty.size():
		_queue_chunk(key)
	_flush_collisions()

func cell(position: Vector2) -> Vector2i:
	return ToroidalGrid.cell_of(position, SUB_SIZE, columns, rows)

func _material(index: int) -> int:
	return CyrmMap.tile_material(_cells[index])

func material_at(at: Vector2i) -> int:
	var i := posmod(at.y, rows) * columns + posmod(at.x, columns)
	return _material(i) if _hp[i] > 0 else 0

func sub_index(at: Vector2i) -> int:
	if at.x < 0 or at.y < 0 or at.x >= columns or at.y >= rows:
		return -1
	return at.y * columns + at.x

func sub_position(i: int) -> Vector2i:
	return Vector2i(i % columns, i / columns)

func sub_texture(at: Vector2i) -> int:
	var i := sub_index(at)
	return _material(i) if i >= 0 else 0

func get_hp(at: Vector2i) -> int:
	var i := sub_index(at)
	return 0 if i < 0 else _hp[i]

func water(position: Vector2) -> bool:
	return _water_cell(cell(position))

func _water_cell(at: Vector2i) -> bool:
	return TileDefs.is_liquid(material_at(at))

## 返回输入位置到其正上方水面的距离。输入位置不在水里时为 -INF，整列没有水面时为 INF。
func water_depth(position: Vector2) -> float:
	var at := cell(position)
	if not _water_cell(at):
		return -INF
	for above in range(1, rows):
		if not _water_cell(at - Vector2i(0, above)):
			return fposmod(position.y, SUB_SIZE) + (above - 1) * SUB_SIZE
	return INF

func water_multiplier(position: Vector2) -> float:
	var material := material_at(cell(position))
	return TileDefs.decay[material] if TileDefs.is_liquid(material) else 1.0

func cell_center(at: Vector2i) -> Vector2:
	return Vector2((at.x + 0.5) * SUB_SIZE, (at.y + 0.5) * SUB_SIZE)

## 沿两点之间的最短路线检查地形遮挡。
## 路线横跨地图边缘时，在另一侧继续发射射线。
func line_of_sight(from: Vector2, to: Vector2) -> bool:
	var delta := ToroidalGrid.toroidal_delta_px(from, to, map_size)
	if delta.is_zero_approx():
		return true
	var size := map_size
	var dir := delta.normalized()
	var p := ToroidalGrid.wrap_to_range(from, size)
	var remaining := delta.length()
	var crossed_seam := false
	while remaining > 0.0:
		var run := CollisionWorld.seam_run(p, dir, size, remaining)
		var start := p - dir * 0.5 if crossed_seam else p
		if not _ray_between(start, p + dir * run).is_empty():
			return false
		p = ToroidalGrid.wrap_to_range(p + dir * run, size)
		remaining -= run
		crossed_seam = true
	return true

func _ray_between(from: Vector2, to: Vector2) -> Dictionary:
	var started := PerformanceStats.begin()
	var hit := physics.ray_hit(from, to, CombatProfiles.Layer.TERRAIN)
	PerformanceStats.end(PerformanceStats.PHYSICS_RAY, started)
	return hit

## 光束按碰撞法线反射，反射前走过的距离会从剩余射程中扣除。
## 跨边缘的碰撞查询从地图另一侧继续。记录路径点时保留相应的偏移量，让渲染仍能连成整条光束。
## 返回的 contacts 中保存被光束击中的子格坐标，供地形伤害结算。
func trace_beam(origin: Vector2, direction: Vector2, length: float, max_bounces: int) -> Dictionary:
	var points := PackedVector2Array([origin])
	var contacts: Array = []
	var d := direction.normalized()
	if d == Vector2.ZERO:
		d = Vector2(1.0, 0.0)
	var size := map_size
	var p := ToroidalGrid.wrap_to_range(origin, size)
	var shift := origin - p
	var remaining := length
	var bounces := 0
	var ended_on_hit := false
	var crossed_seam := false
	while remaining > 0.0:
		var run := CollisionWorld.seam_run(p, d, size, remaining)
		var q := p + d * run
		var start := p - d * 0.5 if crossed_seam else p
		var hit := _ray_between(start, q)
		if not hit.is_empty():
			var point: Vector2 = hit["position"]
			var normal: Vector2 = hit["normal"]
			points.append(point + shift)
			contacts.append(cell(point - normal * 0.5))
			remaining -= p.distance_to(point)
			ended_on_hit = true
			if remaining <= 0.0 or bounces >= max_bounces:
				break
			bounces += 1
			crossed_seam = false
			d = d.bounce(normal)
			q = point + d * 0.5
			p = ToroidalGrid.wrap_to_range(q, size)
			shift += q - p
			remaining -= 0.5
			continue
		remaining -= run
		ended_on_hit = false
		crossed_seam = true
		p = ToroidalGrid.wrap_to_range(q, size)
		shift += q - p
	if not ended_on_hit:
		points.append(p + shift)
	return {"points": points, "contacts": contacts}

## 检查矩形是否碰到实心瓦片。将 with_liquid 设为 true 也会检查水体。
func rect_overlaps(bounds: Rect2, with_liquid: bool) -> bool:
	if not bounds.has_area(): return false
	var first := Vector2i((bounds.position / SUB_SIZE).floor())
	var end := Vector2i((bounds.end / SUB_SIZE).ceil())
	for y in range(first.y, end.y):
		for x in range(first.x, end.x):
			var kind := TileDefs.types[material_at(Vector2i(x, y))]
			if kind == TileDefs.TYPE_WALL or (with_liquid and kind == TileDefs.TYPE_LIQUID): return true
	return false

func elastic_alive(position: Vector2) -> bool:
	var i := sub_index(cell(position))
	return _hp[i] > 0 and TileDefs.elastic[_material(i)] != 0

func _write_hp(index: int, next: int) -> void:
	_hp[index] = next
	if next == TileDefs.hit_points[_material(index)]:
		_modified.erase(index)
	else:
		_modified[index] = next

func _occupancy_changed(index: int, before: int) -> void:
	var alive := _hp[index] > 0
	if (before > 0) == alive:
		return
	if _visual_changes.has(index):
		_visual_changes.erase(index)
	else:
		_visual_changes[index] = alive
	var tex := _material(index)
	if TileDefs.types[tex] == TileDefs.TYPE_WALL:
		if TileDefs.damage_masks[tex] == 0:
			permanent_dirty = true
		else:
			var sub := sub_position(index)
			_queue_chunk((sub.y / CHUNK_CELLS) * _chunk_columns + sub.x / CHUNK_CELLS)
	if TileDefs.ledges[tex] != 0:
		ledges_dirty = true

## 立即扣除耐久度并返回破坏的子格数。commit() 更新碰撞和渲染记录。
func damage_impact(position: Vector2, normal: Vector2, amount: int) -> int:
	if amount <= 0:
		return 0
	var hit := cell(position - normal * 0.5)
	var index := sub_index(hit)
	var tex := _material(index)
	if _hp[index] <= 0 or (TileDefs.damage_masks[tex] & TileDefs.DamageMask.BULLET) == 0:
		return 0
	return _damage_block(hit / DAMAGE_BLOCK_SUBS, DAMAGE_BLOCK_SUBS, amount, TileDefs.DamageMask.BULLET)

func damage_beam(at: Vector2i, amount: int) -> int:
	if sub_index(at) < 0 or amount <= 0:
		return 0
	return _damage_block(at / BEAM_BLOCK_SUBS, BEAM_BLOCK_SUBS, amount, TileDefs.DamageMask.EXPLOSION)

func _damage_block(block: Vector2i, side: int, amount: int, mask: int) -> int:
	var origin := block * side
	var start := sub_index(origin)
	var extent := (Vector2i(columns, rows) - origin).min(Vector2i(side, side))
	var destroyed := 0
	for y in extent.y:
		for x in extent.x:
			var index := start + y * columns + x
			var before := _hp[index]
			if before > 0 and (TileDefs.damage_masks[_material(index)] & mask) != 0:
				var next := maxi(0, before - amount)
				_pending.get_or_add(index, before)
				_write_hp(index, next)
				destroyed += int(next == 0)
	return destroyed

func damage_blast(center: Vector2, radius: float, damage: int) -> int:
	if radius <= 0.0:
		return 0
	# 每个 32 像素块用块内距爆心最近的可破坏子格计算伤害。
	var nearest: Dictionary[Vector2i, float] = {}
	var at := cell(center)
	var reach := int(ceil(radius / SUB_SIZE)) + 1
	var width := mini(2 * reach + 1, columns)
	var height := mini(2 * reach + 1, rows)
	for y in range(-reach, -reach + height):
		for x in range(-reach, -reach + width):
			var sx := posmod(at.x + x, columns)
			var sy := posmod(at.y + y, rows)
			var i := sy * columns + sx
			if _material(i) == 0 or _hp[i] <= 0 \
					or (TileDefs.damage_masks[_material(i)] & TileDefs.DamageMask.EXPLOSION) == 0:
				continue
			var d := ToroidalGrid.toroidal_delta_px(center, Vector2((sx + 0.5) * SUB_SIZE, (sy + 0.5) * SUB_SIZE), map_size).length()
			if d <= radius:
				var block := Vector2i(sx, sy) / DAMAGE_BLOCK_SUBS
				nearest[block] = minf(nearest.get(block, INF), d)
	var inner := radius * BlastCurve.INNER_FRACTION
	var destroyed := 0
	for block in nearest:
		var falloff := BlastCurve.falloff(nearest[block], radius, inner, float(damage))
		var amount := int(falloff * TileDefs.blast_decay)
		if amount > 0:
			destroyed += _damage_block(block, DAMAGE_BLOCK_SUBS, amount, TileDefs.DamageMask.EXPLOSION)
	return destroyed

func reset() -> void:
	for i: int in _modified.keys():
		_pending.get_or_add(i, _hp[i])
		_write_hp(i, TileDefs.hit_points[_material(i)])
	commit()

## 返回相对版本 at 发生变化的子格及其当前耐久度，破坏的子格值为 0。
func changes_since(at: int) -> Dictionary:
	var cells := {}
	var originals := _originals_since(at)
	for index: int in originals:
		if originals[index] != _hp[index]:
			cells[sub_position(index)] = _hp[index]
	return cells

func get_modified() -> Dictionary:
	var out := {}
	for index: int in _modified:
		out[sub_position(index)] = _modified[index]
	return out

func _wall_mask(area: Rect2i, breakable: bool) -> PackedByteArray:
	var mask := PackedByteArray()
	mask.resize(area.get_area())
	var width := area.size.x
	for y in area.size.y:
		var row := (area.position.y + y) * columns + area.position.x
		for x in width:
			var tex := _material(row + x)
			if _hp[row + x] > 0 and TileDefs.types[tex] == TileDefs.TYPE_WALL \
					and (TileDefs.damage_masks[tex] != 0) == breakable:
				mask[y * width + x] = 1
	return mask

static func _wall_rectangles(area: Rect2i, remaining: PackedByteArray) -> Array:
	var result := []
	var width := area.size.x
	for y in area.size.y:
		for x in width:
			if remaining[y * width + x] == 0:
				continue
			var end_x := x + 1
			while end_x < width and remaining[y * width + end_x]:
				end_x += 1
			var end_y := y
			while end_y < area.size.y:
				var row := end_y * width
				var complete := true
				for cx in range(x, end_x):
					if remaining[row + cx] == 0:
						complete = false
						break
				if not complete:
					break
				for cx in range(x, end_x):
					remaining[row + cx] = 0
				end_y += 1
			var size := Vector2(end_x - x, end_y - y) * SUB_SIZE
			var corner := Vector2(area.position + Vector2i(x, y)) * SUB_SIZE
			result.append(Rect2(corner + size * 0.5, size))
	return result

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for chunk in _chunks:
			if chunk.body.is_valid():
				PhysicsServer2D.free_rid(chunk.body)
		for shape: RID in _shape_rids.values():
			PhysicsServer2D.free_rid(shape)

# 尺寸相同的矩形共用一个形状。在物理服务器中，矩形的尺寸参数是半宽和半高。
func _shape_rid(size: Vector2) -> RID:
	var key := Vector2i(size)
	var rid: RID = _shape_rids.get(key, RID())
	if rid.is_valid():
		return rid
	rid = PhysicsServer2D.rectangle_shape_create()
	PhysicsServer2D.shape_set_data(rid, size * 0.5)
	_shape_rids[key] = rid
	return rid

func _lay_shapes(rects: Array) -> void:
	_placements.clear()
	var reach := CollisionWorld.SEAM_REACH
	var margin := Vector2(reach if map_size.x > reach * 2.0 else 0.0,
			reach if map_size.y > reach * 2.0 else 0.0)
	for rect: Rect2 in rects:
		var shape := _shape_rid(rect.size)
		_placements.append([shape, Transform2D(0.0, rect.position)])
		# 为地图边缘附近的矩形添加另一侧的碰撞形状，覆盖越界后的移动和查询。
		var box := Rect2(rect.position - rect.size * 0.5, rect.size)
		var copies := ToroidalGrid.seam_copy_range(box, map_size, margin)
		for y in range(copies.position.y, copies.end.y):
			for x in range(copies.position.x, copies.end.x):
				if x != 0 or y != 0:
					var center := rect.position + Vector2(x, y) * map_size
					_placements.append([shape, Transform2D(0.0, center)])

# 形状数量相同时更新已有形状，数量变化时重建形状列表。
func _submit(chunk: Chunk, signature: PackedByteArray, rects: Array) -> void:
	var body := chunk.body
	if not body.is_valid():
		body = CollisionWorld.create_body(CombatProfiles.Layer.TERRAIN, 0)
		PhysicsServer2D.body_set_space(body, physics.world.space)
		chunk.body = body
	_lay_shapes(rects)
	if PhysicsServer2D.body_get_shape_count(body) == _placements.size():
		for i in _placements.size():
			var entry: Array = _placements[i]
			PhysicsServer2D.body_set_shape(body, i, entry[0])
			PhysicsServer2D.body_set_shape_transform(body, i, entry[1])
	else:
		PhysicsServer2D.body_clear_shapes(body)
		for entry: Array in _placements:
			PhysicsServer2D.body_add_shape(body, entry[0], entry[1])
	# 提交一次变换以刷新物理服务器，让紧接着的查询就能使用更新后的形状。
	PhysicsServer2D.body_set_state(body, PhysicsServer2D.BODY_STATE_TRANSFORM, Transform2D.IDENTITY)
	chunk.signature = signature

func _chunk_area(key: int) -> Rect2i:
	var span := CHUNK_CELLS
	var start := Vector2i(key % _chunk_columns, key / _chunk_columns) * span
	return Rect2i(start, (Vector2i(columns, rows) - start).min(Vector2i.ONE * span))

func _rebuild_walls(key: int, area: Rect2i) -> void:
	var chunk := _chunks[key]
	var mask := _wall_mask(area, key != PERMANENT_CHUNK)
	# 每块区域用压缩后的子格占用数据标识碰撞布局。相同布局再次出现时，可以直接使用已计算的矩形列表。
	var signature := mask.compress(FileAccess.COMPRESSION_FASTLZ)
	if chunk.signature == signature:
		return
	if chunk.layouts.has(signature):
		_submit(chunk, signature, chunk.layouts[signature])
		return
	var rects := _wall_rectangles(area, mask)
	if key != PERMANENT_CHUNK:
		if chunk.layouts.size() == CACHE_STATES:
			chunk.layouts.erase(chunk.layouts.keys()[0])
		chunk.layouts[signature] = rects
	_submit(chunk, signature, rects)

func _rebuild_ledges() -> void:
	var rects: Array = []
	var ledges := PackedInt64Array()
	for y in rows:
		var start := 0
		var run := 0
		for x in columns + 1:
			var side := 0
			if x < columns:
				var at := Vector2i(x, y)
				side = TileDefs.ledges[material_at(at)]
				if side != 0 and TileDefs.ledges[material_at(at - Vector2i(0, side))] == side: side = 0
			if side == run: continue
			if run != 0:
				var width := (x - start) * SUB_SIZE
				var top := y * SUB_SIZE if run > 0 else (y + 1) * SUB_SIZE - LEDGE_THICKNESS
				rects.append(Rect2(Vector2(start * SUB_SIZE + width * 0.5, top + LEDGE_THICKNESS * 0.5), Vector2(width, LEDGE_THICKNESS)))
				ledges.append_array(PackedInt64Array([start, x, y, run]))
			run = side
			start = x
	var signature := ledges.to_byte_array()
	if _chunks[LEDGE_CHUNK].signature != signature:
		_submit(_chunks[LEDGE_CHUNK], signature, rects)
	ledges_dirty = false

func _flush_collisions() -> void:
	if _dirty_chunks.is_empty() and not permanent_dirty and not ledges_dirty:
		return
	var started := PerformanceStats.begin()
	if permanent_dirty:
		_rebuild_walls(PERMANENT_CHUNK, Rect2i(0, 0, columns, rows))
		permanent_dirty = false
	if ledges_dirty:
		_rebuild_ledges()
	var pending := _dirty_chunks
	_dirty_chunks = PackedInt32Array()
	for key in pending:
		_chunk_dirty[key] = 0
		_rebuild_walls(key, _chunk_area(key))
	PerformanceStats.end(PerformanceStats.TERRAIN_COMMIT, started)

func take_wall_changes() -> Dictionary:
	var changes := _visual_changes
	_visual_changes = {}
	return changes

func _queue_chunk(key: int) -> void:
	if _chunk_dirty[key] == 0:
		_chunk_dirty[key] = 1
		_dirty_chunks.append(key)

func commit() -> void:
	if _pending.is_empty():
		return
	for index: int in _pending.keys():
		if _pending[index] == _hp[index]:
			_pending.erase(index)
		else:
			_occupancy_changed(index, _pending[index])
	_finish_commit(_pending)
	_pending = {}

## 基于已提交的版本 at 应用地形补丁。cells 提供各子格的绝对耐久度。
func apply_at(at: int, cells: Dictionary) -> int:
	if at == version and cells.is_empty():
		return version
	var originals := _originals_since(at)
	_undo.resize(_undo.size() - (version - at))
	_version = at
	var undo: Dictionary[int, int] = {}
	for sub: Vector2i in cells:
		var index := sub_index(sub)
		var before: int = originals.get(index, _hp[index])
		var next := maxi(0, cells[sub])
		if before != next:
			undo[index] = before
		_replace_hp(index, next)
		originals.erase(index)
	for index: int in originals:
		_replace_hp(index, originals[index])
	_finish_commit(undo)
	return version

func forget_before(at: int) -> void:
	if at == version:
		_undo.clear()
	else:
		var count := _undo.size() - (version - at)
		if count > 0:
			_undo = _undo.slice(count)

func _originals_since(at: int) -> Dictionary:
	var originals := {}
	for offset in range(1, version - at + 1):
		originals.merge(_undo[-offset], true)
	return originals

func _replace_hp(index: int, next: int) -> void:
	var before := _hp[index]
	if before != next:
		_write_hp(index, next)
		_occupancy_changed(index, before)

func _finish_commit(undo: Dictionary) -> void:
	if not undo.is_empty():
		_undo.append(undo)
		_version += 1
	_flush_collisions()
