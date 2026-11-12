class_name Terrain
extends RefCounted

# 地形数据与破坏状态的唯一所有者：宏格/16px 子格、HP、分块碰撞几何、
# 单人回溯历史也在这里；场景只负责提供物理空间与视觉瓦片。

signal changed

# 物理与渲染共用的地形尺度；分块布局与生命周期由本类唯一持有。
const TILE_SIZE := 64
const SUB_SIZE := 16
const SUB_PER_CELL := TILE_SIZE / SUB_SIZE
const CHUNK_CELLS := 12
const LEDGE_THICKNESS := 6
const CACHE_STATES := 4

const PERMANENT_CHUNK := -1
const LEDGE_CHUNK := -2

const CHUNK_BODY: int = 0
const CHUNK_SIGNATURE: int = 1
const CHUNK_LAYOUTS: int = 2
const CHUNK_SLOTS: int = 3

const LAYOUT_SIGNATURE: int = 0
const LAYOUT_RECTS: int = 1

const CELL_INDEX: int = 0
const CELL_VALUE: int = 1
const CELL_HP: int = 2
const CELL_SUB_HP: int = 3

const REWIND_TIME: int = 0
const REWIND_CELLS: int = 1

var columns := 0
var rows := 0
var sub_columns := 0
var sub_rows := 0
var map_size := Vector2.ZERO
var revision := 0
var rewind_enabled := false
var authoritative := false

var _grid := PackedInt32Array()
var _initial_grid := PackedInt32Array()
var _textures := PackedInt32Array()
var _descriptors := PackedInt32Array()
var _hp := PackedInt32Array()
var _initial_hp := PackedInt32Array()
var _tile_hp := PackedInt32Array()
var _initial_tile_hp := PackedInt32Array()
var _grid_revision := 0
var _network_changes: Dictionary = {}
var _modified: Dictionary = {}
var _rewind_pending: Dictionary[int, PackedInt32Array] = {}
var _rewind_entries: Array[Array] = []
var _rewards: Dictionary = {}
var _visual_changes: Dictionary = {}
var _chunk_columns := 0
var _chunk_dirty := PackedByteArray()
var _dirty_chunks := PackedInt32Array()
var _owner: Node
# 常规块按编号索引，数组末两槽存台阶和永久墙。
var _chunks: Array[Array] = []
var _space := RID()
var _ray_params := PhysicsRayQueryParameters2D.create(Vector2.ZERO, Vector2.ZERO, CollisionWorld.LAYER_TERRAIN)
var _shape_rids: Dictionary = {}
var _placements: Array = []
var permanent_dirty := true
var ledges_dirty := true
var _grid_snapshot: Array[Array] = []
var _grid_snapshot_revision := -1

static func _wrap(value: int, span: int) -> int:
	var n := value % span
	return n + span if n < 0 else n

static func texture(value: int) -> int:
	return value / 16

func _init(macro: Array = [], descriptors := PackedInt32Array()) -> void:
	if macro.is_empty():
		return
	TileDefs.load_defs()
	rows = macro.size()
	columns = (macro[0] as Array).size()
	sub_rows = rows * SUB_PER_CELL
	sub_columns = columns * SUB_PER_CELL
	assert(descriptors.size() == sub_rows * sub_columns)
	map_size = Vector2(columns * TILE_SIZE, rows * TILE_SIZE)
	_grid.resize(columns * rows)
	_tile_hp.resize(columns * rows)
	for y in rows:
		var row: Array = macro[y]
		for x in columns:
			var i := y * columns + x
			_grid[i] = int(row[x])
			_tile_hp[i] = TileDefs.hit_points[texture(_grid[i])]
	_descriptors = descriptors
	_textures.resize(descriptors.size())
	_hp.resize(descriptors.size())
	for i in descriptors.size():
		var tex := MapFormatV4.descriptor_texture(descriptors[i])
		_textures[i] = tex
		_hp[i] = TileDefs.hit_points[tex]
	_initial_grid = _grid.duplicate()
	_initial_hp = _hp.duplicate()
	_initial_tile_hp = _tile_hp.duplicate()
	_chunk_columns = (columns + CHUNK_CELLS - 1) / CHUNK_CELLS
	_chunk_dirty.resize(_chunk_columns * ((rows + CHUNK_CELLS - 1) / CHUNK_CELLS))
	_chunk_dirty.fill(0)
	_chunks.resize(_chunk_dirty.size() + 2)
	for key in _chunks.size():
		_chunks[key] = [RID(), PackedInt64Array(), [], 0]

func empty() -> bool:
	return columns == 0 or rows == 0

func space_rid() -> RID:
	return _space

func cell(position: Vector2) -> Vector2i:
	if empty():
		return Vector2i()
	return Vector2i(_wrap(int(floor(position.x / TILE_SIZE)), columns),
			_wrap(int(floor(position.y / TILE_SIZE)), rows))

func value(at: Vector2i) -> int:
	return 0 if empty() else _grid[_wrap(at.y, rows) * columns + _wrap(at.x, columns)]

func sub_index(at: Vector2i) -> int:
	if at.x < 0 or at.y < 0 or at.x >= sub_columns or at.y >= sub_rows:
		return -1
	return at.y * sub_columns + at.x

func sub_position(i: int) -> Vector2i:
	return Vector2i(i % sub_columns, i / sub_columns)

func macro_of(i: int) -> int:
	return (i / sub_columns / SUB_PER_CELL) * columns + (i % sub_columns / SUB_PER_CELL)

func _macro_sub_start(index: int) -> int:
	return (index / columns * sub_columns + index % columns) * SUB_PER_CELL

func sub_texture(at: Vector2i) -> int:
	var i := sub_index(at)
	return 0 if i < 0 else _textures[i]

func descriptors() -> PackedInt32Array:
	return _descriptors

func get_hp(at: Vector2i) -> int:
	var i := sub_index(at)
	return 0 if i < 0 else _hp[i]

func sub_of(position: Vector2) -> Vector2i:
	if sub_columns == 0 or sub_rows == 0:
		return Vector2i()
	return Vector2i(_wrap(int(floor(position.x / SUB_SIZE)), sub_columns),
			_wrap(int(floor(position.y / SUB_SIZE)), sub_rows))

func climb_speed(tex: int) -> float:
	return TileDefs.climb[tex]

func descent_speed(tex: int) -> float:
	return TileDefs.descent[tex]

func water(position: Vector2) -> bool:
	return _water_cell(cell(position))

func _water_cell(at: Vector2i) -> bool:
	var v := value(at)
	return v != 0 and TileDefs.types[texture(v)] == TileDefs.TYPE_LIQUID

## 沿采样点所在的连续水柱向上量深度。干处为 -INF，整列是水时为 INF。
func water_depth(position: Vector2) -> float:
	var at := cell(position)
	if not _water_cell(at):
		return -INF
	for above in range(1, rows):
		if not _water_cell(at - Vector2i(0, above)):
			return fposmod(position.y, TILE_SIZE) + (above - 1) * TILE_SIZE
	return INF

func water_multiplier(position: Vector2) -> float:
	return TileDefs.decay[texture(value(cell(position)))] if water(position) else 1.0

func cell_center(at: Vector2i) -> Vector2:
	return Vector2((at.x + 0.5) * TILE_SIZE, (at.y + 0.5) * TILE_SIZE)

## 遮挡查询走引擎射线：只有真实存在于物理空间的地形才遮挡。
## 连线按环面最短位移分段，跨接缝时每段都在规范世界内查询；
## 否则两端贴边的连线会改判成穿过整张地图的直线。
func line_of_sight(from: Vector2, to: Vector2) -> bool:
	if empty():
		return true
	var delta := GridPathfinder.toroidal_delta_px(from, to, map_size)
	if delta.is_zero_approx():
		return true
	var size := map_size
	var dir := delta.normalized()
	var p := GridPathfinder.wrap_to_range(from, size)
	var remaining := delta.length()
	while remaining > 0.0:
		var run := CollisionWorld.seam_run(p, dir, size, remaining)
		if not _ray_between(p, p + dir * run).is_empty():
			return false
		p = GridPathfinder.wrap_to_range(p + dir * run, size)
		remaining -= run
	return true

func _ray_between(from: Vector2, to: Vector2) -> Dictionary:
	_ray_params.from = from
	_ray_params.to = to
	var started := PerformanceStats.begin()
	var hit := PhysicsServer2D.space_get_direct_state(_space).intersect_ray(_ray_params)
	PerformanceStats.end(PerformanceStats.PHYSICS_RAY, started)
	return hit

## 光束几何全部交给引擎射线；命中后沿法线反射并保留剩余总长度。
## 长光线在接缝处分段：查询位置回绕到规范区间，返回的折线保持视觉连续。
## contacts 仍是宏格坐标，供武器结算瓦片伤害。
func trace_beam(origin: Vector2, direction: Vector2, length: float, max_bounces: int) -> Dictionary:
	var points := PackedVector2Array([origin])
	var hit_points := PackedVector2Array()
	var contacts: Array = []
	var d := direction.normalized()
	if d == Vector2.ZERO:
		d = Vector2(1.0, 0.0)
	if empty():
		points.append(origin + d * length)
		return {"points": points, "contacts": contacts, "hit_points": hit_points}
	var size := map_size
	var p := GridPathfinder.wrap_to_range(origin, size)
	var shift := origin - p
	var remaining := length
	var bounces := 0
	var ended_on_hit := false
	while remaining > 0.0:
		var run := CollisionWorld.seam_run(p, d, size, remaining)
		var q := p + d * run
		var hit := _ray_between(p, q)
		if not hit.is_empty():
			var point: Vector2 = hit["position"]
			var normal: Vector2 = hit["normal"]
			points.append(point + shift)
			hit_points.append(point + shift)
			contacts.append(cell(point - normal * 0.5))
			remaining -= p.distance_to(point)
			ended_on_hit = true
			if remaining <= 0.0 or bounces >= max_bounces:
				break
			bounces += 1
			d = d.bounce(normal)
			q = point + d * 0.5
			p = GridPathfinder.wrap_to_range(q, size)
			shift += q - p
			remaining -= 0.5
			continue
		remaining -= run
		ended_on_hit = false
		p = GridPathfinder.wrap_to_range(q, size)
		shift += q - p
	if not ended_on_hit:
		points.append(p + shift)
	return {"points": points, "contacts": contacts, "hit_points": hit_points}

## 矩形是否与实心格重叠；with_liquid 时液体格也算。按格尺寸取样，边界格向两侧取整。
func rect_overlaps(bounds: Rect2, size: float, with_liquid: bool) -> bool:
	if empty() or size <= 0.0:
		return false
	var x0 := int(floor(bounds.position.x / size))
	var x1 := int(floor(bounds.end.x / size))
	var y0 := int(floor(bounds.position.y / size))
	var y1 := int(floor(bounds.end.y / size))
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var packed := value(Vector2i(x, y))
			if packed == 0:
				continue
			var kind := TileDefs.types[texture(packed)]
			if kind == TileDefs.TYPE_WALL or (with_liquid and kind == TileDefs.TYPE_LIQUID):
				return true
	return false

func elastic_alive(position: Vector2) -> bool:
	var i := sub_index(sub_of(position))
	return i >= 0 and _hp[i] > 0 and TileDefs.elastic[_textures[i]] != 0

func get_grid_snapshot() -> Array[Array]:
	if _grid_snapshot_revision == _grid_revision:
		return _grid_snapshot
	var result: Array[Array] = []
	for y in rows:
		var row: Array = []
		for x in columns:
			row.append(_grid[y * columns + x])
		row.make_read_only()
		result.append(row)
	result.make_read_only()
	_grid_snapshot = result
	_grid_snapshot_revision = _grid_revision
	return _grid_snapshot

func _capture(at: int) -> PackedInt32Array:
	var state := PackedInt32Array([at, _grid[at], _tile_hp[at]])
	state.resize(CELL_SUB_HP + SUB_PER_CELL * SUB_PER_CELL)
	var start := _macro_sub_start(at)
	for y in SUB_PER_CELL:
		for x in SUB_PER_CELL:
			state[CELL_SUB_HP + y * SUB_PER_CELL + x] = _hp[start + y * sub_columns + x]
	return state

func _capture_before(at: int) -> void:
	if rewind_enabled and not _rewind_pending.has(at):
		_rewind_pending[at] = _capture(at)

func capture_cell(at: Vector2i) -> Dictionary:
	if at.x < 0 or at.y < 0 or at.x >= columns or at.y >= rows:
		return {}
	var state := _capture(at.y * columns + at.x)
	return {"cell": at, "tile": state[CELL_VALUE], "hp": state[CELL_HP],
			"subs": state.slice(CELL_SUB_HP)}

func _restore_cell(state: PackedInt32Array) -> void:
	var index := state[CELL_INDEX]
	var start := _macro_sub_start(index)
	for y in SUB_PER_CELL:
		for x in SUB_PER_CELL:
			_write_hp(start + y * sub_columns + x, state[CELL_SUB_HP + y * SUB_PER_CELL + x], false, false)
	var next := state[CELL_VALUE]
	if _grid[index] != next:
		var old_ledge := TileDefs.ledges[texture(_grid[index])]
		var new_ledge := TileDefs.ledges[texture(next)]
		ledges_dirty = ledges_dirty or old_ledge != 0 or new_ledge != 0
		_grid[index] = next
		_grid_revision += 1
	_tile_hp[index] = state[CELL_HP]

func _refresh_macro(at: int) -> void:
	var start := _macro_sub_start(at)
	var alive := false
	for y in SUB_PER_CELL:
		if alive:
			break
		for x in SUB_PER_CELL:
			if _hp[start + y * sub_columns + x] > 0:
				alive = true
				break
	var next := _initial_grid[at] if alive else 0
	if _grid[at] != next:
		_grid[at] = next
		_grid_revision += 1
		ledges_dirty = ledges_dirty or TileDefs.ledges[texture(_initial_grid[at])] != 0

func _mark_collision(index: int) -> void:
	var sub := sub_position(index)
	var span := CHUNK_CELLS * SUB_PER_CELL
	_queue_chunk((sub.y / span) * _chunk_columns + sub.x / span)
	var tex := _textures[index]
	if TileDefs.types[tex] == TileDefs.TYPE_WALL and TileDefs.damage_masks[tex] == 0:
		permanent_dirty = true

func _write_hp(index: int, next: int, record: bool, notify: bool, owner := 0) -> bool:
	next = maxi(0, next)
	var before := _hp[index]
	if before == next:
		return false
	var macro := macro_of(index)
	if record:
		_capture_before(macro)
	_hp[index] = next
	if notify and authoritative:
		_network_changes[index] = next
		_modified[index] = next
		revision += 1
	if (before > 0) != (next > 0):
		_visual_changes[index] = true
		_mark_collision(index)
		_refresh_macro(macro)
		if notify and before > 0 and next == 0 and owner > 0:
			_rewards[owner] = int(_rewards.get(owner, 0)) + 1
	return true

func damage_sub(at: Vector2i, amount: int, source: int, owner: int) -> bool:
	var i := sub_index(at)
	if i < 0 or _textures[i] == 0 or _hp[i] <= 0 or amount <= 0:
		return false
	var mask := TileDefs.DamageMask.BULLET if source == 0 else TileDefs.DamageMask.EXPLOSION
	if (TileDefs.damage_masks[_textures[i]] & mask) == 0:
		return false
	var modified := _write_hp(i, _hp[i] - amount, true, true, owner)
	if modified:
		changed.emit()
	return modified and _hp[i] == 0

func damage_impact(position: Vector2, normal: Vector2, amount: int, owner: int) -> int:
	if empty():
		return 0
	for probe in 3:
		var at := sub_of(position - normal * (probe * SUB_SIZE * 0.5))
		var tex := sub_texture(at)
		if tex != 0 and (TileDefs.damage_masks[tex] & TileDefs.DamageMask.BULLET) != 0:
			if amount > 0:
				damage_sub(at, amount, 0, owner)
			return tex
	return 0

func damage_tile(at: Vector2i, amount: int, source: int, owner: int) -> bool:
	if at.x < 0 or at.y < 0 or at.x >= columns or at.y >= rows or amount <= 0:
		return false
	var i := at.y * columns + at.x
	if _grid[i] == 0:
		return false
	var mask := TileDefs.DamageMask.BULLET if source == 0 else TileDefs.DamageMask.EXPLOSION
	if (TileDefs.damage_masks[texture(_grid[i])] & mask) == 0:
		return false
	_capture_before(i)
	_tile_hp[i] = maxi(0, _tile_hp[i] - amount)
	if _tile_hp[i] > 0:
		return false
	var start := _macro_sub_start(i)
	for y in SUB_PER_CELL:
		for x in SUB_PER_CELL:
			var n := start + y * sub_columns + x
			if (TileDefs.damage_masks[_textures[n]] & mask) != 0:
				_write_hp(n, 0, false, true, owner)
	_refresh_macro(i)
	changed.emit()
	return _grid[i] == 0

func blast_cells(center: Vector2, radius: float) -> Array:
	var out: Array = []
	if sub_columns == 0 or sub_rows == 0 or radius <= 0.0:
		return out
	var at := sub_of(center)
	var reach := int(ceil(radius / SUB_SIZE)) + 1
	var width := mini(2 * reach + 1, sub_columns)
	var height := mini(2 * reach + 1, sub_rows)
	for y in range(-reach, -reach + height):
		for x in range(-reach, -reach + width):
			var sx := _wrap(at.x + x, sub_columns)
			var sy := _wrap(at.y + y, sub_rows)
			var i := sy * sub_columns + sx
			if _textures[i] == 0 or _hp[i] <= 0 \
					or (TileDefs.damage_masks[_textures[i]] & TileDefs.DamageMask.EXPLOSION) == 0:
				continue
			var d := GridPathfinder.toroidal_delta_px(center, Vector2((sx + 0.5) * SUB_SIZE, (sy + 0.5) * SUB_SIZE), map_size).length()
			if d > radius:
				continue
			out.append([i, d])
	return out

func damage_blast(center: Vector2, radius: float, damage: int, owner: int) -> int:
	var changed_count := 0
	var inner := radius * BlastCurve.INNER_FRACTION
	for entry in blast_cells(center, radius):
		var falloff := BlastCurve.falloff(entry[1], radius, inner, float(damage))
		var amount := int(falloff * TileDefs.blast_decay)
		if amount > 0 and _write_hp(entry[0], _hp[entry[0]] - amount, true, true, owner):
			changed_count += 1
	if changed_count:
		changed.emit()
	return changed_count

func apply_hp(at: Vector2i, value: int, owner: int) -> bool:
	var i := sub_index(at)
	if i < 0:
		return false
	var modified := _write_hp(i, value, true, true, owner)
	if modified:
		changed.emit()
	return modified and _hp[i] == 0

func apply_values(values: Dictionary) -> void:
	for at in values.keys():
		var n := sub_index(at)
		if n >= 0:
			_write_hp(n, int(values[at]), false, false)

func reset() -> void:
	for i in _hp.size():
		_write_hp(i, _initial_hp[i], false, false)
	_grid = _initial_grid.duplicate()
	_tile_hp = _initial_tile_hp.duplicate()
	_network_changes.clear()
	_modified.clear()
	_rewards.clear()
	_rewind_pending.clear()
	_rewind_entries.clear()
	revision = revision + 1 if authoritative else 0
	_grid_revision += 1
	flush_collisions()

func take_network_changes() -> Dictionary:
	var out := {}
	for index in _network_changes:
		out[sub_position(index)] = _network_changes[index]
	_network_changes.clear()
	return out

func get_modified() -> Dictionary:
	var out := {}
	for index in _modified:
		out[sub_position(index)] = _modified[index]
	return out

func take_rewards() -> Dictionary:
	var out := _rewards.duplicate()
	_rewards.clear()
	return out

func greedy(x0: int, y0: int, x1: int, y1: int, destructible: bool) -> Array:
	var width := x1 - x0
	var height := y1 - y0
	var occupied := PackedByteArray()
	occupied.resize(width * height)
	var used := PackedByteArray()
	used.resize(width * height)
	for y in range(y0, y1):
		for x in range(x0, x1):
			var i := y * sub_columns + x
			var tex := _textures[i]
			var solid := _hp[i] > 0 and TileDefs.types[tex] == TileDefs.TYPE_WALL and (TileDefs.damage_masks[tex] != 0) == destructible
			occupied[(y - y0) * width + x - x0] = 1 if solid else 0
	var result: Array = []
	for y in range(y0, y1):
		for x in range(x0, x1):
			var i := (y - y0) * width + x - x0
			if occupied[i] == 0 or used[i] != 0:
				continue
			var x2 := x
			var y2 := y
			while x2 + 1 < x1 and occupied[(y - y0) * width + x2 + 1 - x0] != 0 \
					and used[(y - y0) * width + x2 + 1 - x0] == 0:
				x2 += 1
			while y2 + 1 < y1:
				var can := true
				for cx in range(x, x2 + 1):
					var n := (y2 + 1 - y0) * width + cx - x0
					if occupied[n] == 0 or used[n] != 0:
						can = false
						break
				if not can:
					break
				y2 += 1
			for ry in range(y, y2 + 1):
				for rx in range(x, x2 + 1):
					used[(ry - y0) * width + rx - x0] = 1
			result.append(Rect2(Vector2((x + x2 + 1) * SUB_SIZE * 0.5, (y + y2 + 1) * SUB_SIZE * 0.5),
					Vector2((x2 - x + 1) * SUB_SIZE, (y2 - y + 1) * SUB_SIZE)))
	return result

# 挂载节点离树时归还自管的物理句柄。
func close() -> void:
	if is_instance_valid(_owner):
		_owner.tree_exiting.disconnect(close)
	_owner = null
	for chunk: Array in _chunks:
		var body: RID = chunk[CHUNK_BODY]
		if body.is_valid():
			PhysicsServer2D.free_rid(body)
		chunk[CHUNK_BODY] = RID()
		chunk[CHUNK_SIGNATURE] = PackedInt64Array()
		chunk[CHUNK_LAYOUTS].clear()
		chunk[CHUNK_SLOTS] = 0

	for rid: RID in _shape_rids.values():
		if rid.is_valid():
			PhysicsServer2D.free_rid(rid)
	_shape_rids.clear()
	if _space.is_valid():
		CollisionWorld.release_terrain(_space, self)
		_space = RID()

# 形状句柄按尺寸共享；物理服务器收的是半宽高。
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
		# greedy() 返回的 position 是矩形中心，接缝判定必须用真实边界。
		var box := Rect2(rect.position - rect.size * 0.5, rect.size)
		var copies := GridPathfinder.seam_copy_range(box, map_size, margin)
		for y in range(copies.position.y, copies.end.y):
			for x in range(copies.position.x, copies.end.x):
				if x != 0 or y != 0:
					var center := rect.position + Vector2(x, y) * map_size
					_placements.append([shape, Transform2D(0.0, center)])

# 碰撞几何直接写进物理空间，不建场景节点。槽位按索引更新，数量变化时才整体重建。
func submit(chunk: Array, signature: PackedInt64Array, rects: Array) -> bool:
	if not _space.is_valid():
		return false
	var body: RID = chunk[CHUNK_BODY]
	if body.is_valid() and chunk[CHUNK_SIGNATURE] == signature:
		return false
	if not body.is_valid():
		body = PhysicsServer2D.body_create()
		PhysicsServer2D.body_set_mode(body, PhysicsServer2D.BODY_MODE_STATIC)
		PhysicsServer2D.body_set_collision_layer(body, 1)
		PhysicsServer2D.body_set_collision_mask(body, 0)
		PhysicsServer2D.body_set_space(body, _space)
		chunk[CHUNK_BODY] = body
	_lay_shapes(rects)
	if chunk[CHUNK_SLOTS] == _placements.size():
		for i in _placements.size():
			var entry: Array = _placements[i]
			PhysicsServer2D.body_set_shape(body, i, entry[0])
			PhysicsServer2D.body_set_shape_transform(body, i, entry[1])
	else:
		PhysicsServer2D.body_clear_shapes(body)
		for entry: Array in _placements:
			PhysicsServer2D.body_add_shape(body, entry[0], entry[1])
		chunk[CHUNK_SLOTS] = _placements.size()
	# 静态体的形状改动必须重设自身变换后才会进入宽相；否则同帧查询看不到新几何。
	PhysicsServer2D.body_set_state(body, PhysicsServer2D.BODY_STATE_TRANSFORM, Transform2D.IDENTITY)
	chunk[CHUNK_SIGNATURE] = signature
	return true

# 观测用：某个分块当前写入空间的形状中心；接缝镜像的数量由这份布局核对。
func body_shapes(key: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	var body: RID = _chunks[key][CHUNK_BODY]
	if not body.is_valid():
		return out
	for i in PhysicsServer2D.body_get_shape_count(body):
		out.append(PhysicsServer2D.body_get_shape_transform(body, i).origin)
	return out

func rebuild(key: int) -> bool:
	var span := CHUNK_CELLS * SUB_PER_CELL
	var x0 := (key % _chunk_columns) * span
	var y0 := (key / _chunk_columns) * span
	var x1 := mini(x0 + span, sub_columns)
	var y1 := mini(y0 + span, sub_rows)
	var signature := PackedInt64Array([sub_columns, sub_rows, SUB_SIZE])
	for y in range(y0, y1):
		var bits := 0
		for x in range(x0, x1):
			var i := y * sub_columns + x
			var tex := _textures[i]
			if _hp[i] > 0 and TileDefs.types[tex] == TileDefs.TYPE_WALL and TileDefs.damage_masks[tex] != 0:
				bits |= 1 << (x - x0)
		signature.append(bits)
	var chunk := _chunks[key]
	var layouts: Array = chunk[CHUNK_LAYOUTS]
	for layout: Array in layouts:
		if layout[LAYOUT_SIGNATURE] == signature:
			return submit(chunk, signature, layout[LAYOUT_RECTS])
	var rects := greedy(x0, y0, x1, y1, true)
	layouts.append([signature, rects])
	if layouts.size() > CACHE_STATES:
		layouts.pop_front()
	return submit(chunk, signature, rects)

func rebuild_permanent() -> void:
	var signature := PackedInt64Array([sub_columns, sub_rows, SUB_SIZE])
	var bits := 0
	var bit := 0
	for i in _hp.size():
		var tex := _textures[i]
		if _hp[i] > 0 and TileDefs.types[tex] == TileDefs.TYPE_WALL and TileDefs.damage_masks[tex] == 0:
			bits |= 1 << bit
		bit += 1
		if bit == 64:
			signature.append(bits)
			bits = 0
			bit = 0
	if bit:
		signature.append(bits)
	submit(_chunks[PERMANENT_CHUNK], signature, greedy(0, 0, sub_columns, sub_rows, false))
	permanent_dirty = false

func rebuild_ledges() -> void:
	var rects: Array = []
	var signature := PackedInt64Array([columns, rows, LEDGE_THICKNESS])
	for i in _grid.size():
		var side := TileDefs.ledges[texture(_grid[i])] if _grid[i] else 0
		if side == 0:
			continue
		signature.append((i << 1) | (1 if side < 0 else 0))
		var x := i % columns
		var y := i / columns
		var center_y := y * TILE_SIZE + LEDGE_THICKNESS * 0.5 if side > 0 \
				else (y + 1) * TILE_SIZE - LEDGE_THICKNESS * 0.5
		rects.append(Rect2(Vector2((x + 0.5) * TILE_SIZE, center_y), Vector2(TILE_SIZE, LEDGE_THICKNESS)))
	submit(_chunks[LEDGE_CHUNK], signature, rects)
	ledges_dirty = false

func attach(parent: Node) -> void:
	assert(parent.is_inside_tree(), "Terrain: attach 需要已挂载的节点")
	var space := CollisionWorld.world_of(parent).space
	var physics := CollisionWorld.for_space(space)
	assert(physics.terrain == null or physics.terrain == self, "一个物理空间只能挂载一张地图")
	if _space != space:
		close()
		_space = space
	if _owner != parent:
		if _owner != null:
			_owner.tree_exiting.disconnect(close)
		_owner = parent
		_owner.tree_exiting.connect(close)
	physics.terrain = self
	invalidate_all()
	flush_collisions()

func flush_collisions() -> int:
	if _dirty_chunks.is_empty() and not permanent_dirty and not ledges_dirty:
		return 0
	if empty() or not _space.is_valid():
		return 0
	var started := PerformanceStats.begin()
	if permanent_dirty:
		rebuild_permanent()
	if ledges_dirty:
		rebuild_ledges()
	var pending := _dirty_chunks
	_dirty_chunks = PackedInt32Array()
	for key in pending:
		_chunk_dirty[key] = 0
		rebuild(key)
	PerformanceStats.end(PerformanceStats.TERRAIN_COMMIT, started)
	return pending.size()

func flush_visual_changes(paint: Callable) -> void:
	for i: int in _visual_changes:
		paint.call(i, _descriptors[i], _hp[i] > 0)
	_visual_changes.clear()

func _queue_chunk(key: int) -> void:
	if _chunk_dirty[key] == 0:
		_chunk_dirty[key] = 1
		_dirty_chunks.append(key)

func invalidate_all() -> void:
	permanent_dirty = true
	ledges_dirty = true
	for key in _chunk_dirty.size():
		_queue_chunk(key)

func seal_rewind(time: float) -> void:
	if _rewind_pending.is_empty():
		return
	var indices := _rewind_pending.keys()
	indices.sort()
	var cells: Array[PackedInt32Array] = []
	for index in indices:
		cells.append(_rewind_pending[index])
	_rewind_pending.clear()
	_rewind_entries.append([time, cells])

func _upper_bound_time(value: float, from: int, to: int) -> int:
	var lo := from
	var hi := to
	while lo < hi:
		var mid := (lo + hi) / 2
		if value < _rewind_entries[mid][REWIND_TIME]:
			hi = mid
		else:
			lo = mid + 1
	return lo

func rewind_between(target: float, cursor: float) -> void:
	var total := _rewind_entries.size()
	var begin := _upper_bound_time(target, 0, total)
	var end := _upper_bound_time(cursor, begin, total)
	while end > begin:
		end -= 1
		var cells: Array[PackedInt32Array] = _rewind_entries[end][REWIND_CELLS]
		for i in range(cells.size() - 1, -1, -1):
			_restore_cell(cells[i])
	flush_collisions()

func prune_rewind(cutoff: float) -> void:
	while not _rewind_entries.is_empty() and _rewind_entries[0][REWIND_TIME] < cutoff:
		_rewind_entries.pop_front()

func truncate_rewind(time: float) -> void:
	while not _rewind_entries.is_empty() and _rewind_entries.back()[REWIND_TIME] > time:
		_rewind_entries.pop_back()
	_rewind_pending.clear()
