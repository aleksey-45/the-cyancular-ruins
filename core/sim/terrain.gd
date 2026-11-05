class_name Terrain
extends RefCounted

# 地形数据与破坏状态的唯一所有者：宏格/16px 子格、HP、分块碰撞几何、
# 预测与回溯历史都在这里；场景只负责提供物理空间与视觉瓦片。

signal changed

# 物理与渲染共用的地形尺度；分块布局与生命周期由本类唯一持有。
const TILE_SIZE := 64
const SUB_SIZE := 16
const CHUNK_CELLS := 12
const LEDGE_THICKNESS := 6
const CACHE_STATES := 4

const FALLBACK_MATERIAL := {"type": 0, "hp": 1, "ledge": 0, "bullet": false, "explosion": false,
	"elastic": false, "climb": 0.0, "descent": 0.0, "decay": 0.75}

var columns := 0
var rows := 0
var sub_columns := 0
var sub_rows := 0
var tile_size := 64
var sub_size := 16
var per_tile := 4
var chunk_cells := 12
var cache_states := 4
var wall_type := 0
var liquid_type := 2
var ledge_thickness := 6
var blast_inner := BlastCurve.INNER_FRACTION
var blast_decay := 0.75
var map_size := Vector2.ZERO
var materials: Array = []
# 热字段派生表：由 materials 在 configure() 生成，供分块重建与爆炸扫描使用。
var _type_tex := PackedInt32Array()
var _bullet_tex := PackedByteArray()
var _explosion_tex := PackedByteArray()
var revision := 0
var generation := 0
var needs_state := false
var rewind_enabled := false
var authoritative := false

var _grid := PackedInt32Array()
var _initial_grid := PackedInt32Array()
var _textures := PackedInt32Array()
var _hp := PackedInt32Array()
var _initial_hp := PackedInt32Array()
var _tile_hp := PackedInt32Array()
var _initial_tile_hp := PackedInt32Array()
var _grid_revision := 0
var _floor_tick := -1
var _authority_tick := -1
var _base: Dictionary = {}
var _authority: Dictionary = {}
var _network_changes: Dictionary = {}
var _modified: Dictionary = {}
var _prediction: Dictionary = {}
var _blast_kernels: Dictionary = {}
var _rewind_pending: Dictionary = {}
var _rewind_entries: Array = []
var _rewards: Dictionary = {}
var _visual_changes: Dictionary = {}
var _dirty: Dictionary = {}
var _parent_id := 0
var _chunks: Dictionary = {}
var _space := RID()
var _ray_state: PhysicsDirectSpaceState2D = null
var _ray_params := PhysicsRayQueryParameters2D.create(Vector2.ZERO, Vector2.ZERO, CollisionWorld.LAYER_TERRAIN)
var _shape_rids: Dictionary = {}
var _placements: Array = []
var permanent_dirty := true
var ledges_dirty := true
var _grid_snapshot: Array[Array] = []
var _subgrid_snapshot: Array = []
var _grid_snapshot_revision := -1

static func _wrap(value: int, span: int) -> int:
	var n := value % span
	return n + span if n < 0 else n

static func texture(value: int) -> int:
	return value / 16

func configure(macro: Array, subgrid: Array, definitions: Dictionary, settings: Dictionary) -> void:
	rows = macro.size()
	columns = (macro[0] as Array).size() if rows else 0
	tile_size = int(settings.get("tile_size", 64))
	sub_size = int(settings.get("sub_size", 16))
	chunk_cells = int(settings.get("chunk_cells", 12))
	cache_states = int(settings.get("cache_states", 4))
	wall_type = int(settings.get("wall_type", 0))
	liquid_type = int(settings.get("liquid_type", 2))
	ledge_thickness = int(settings.get("ledge_thickness", 6))
	blast_inner = float(settings.get("blast_inner", BlastCurve.INNER_FRACTION))
	authoritative = bool(settings.get("authoritative", false))
	if tile_size <= 0 or sub_size <= 0 or tile_size % sub_size != 0 or chunk_cells <= 0 or cache_states <= 0:
		push_error("Terrain: 非法的尺寸参数")
		return
	per_tile = tile_size / sub_size
	if chunk_cells * per_tile > 64:
		push_error("Terrain: 分块超过 64 子格")
		return
	map_size = Vector2(columns * tile_size, rows * tile_size)
	blast_decay = float(definitions.get("explosion_decay", 0.75))
	var tiles: Dictionary = definitions.get("tiles", {})
	var max_texture := 0
	for y in rows:
		var row: Array = macro[y]
		for x in columns:
			max_texture = maxi(max_texture, texture(int(row[x])))
	for y in subgrid.size():
		var row: Array = subgrid[y]
		for x in row.size():
			max_texture = maxi(max_texture, int(row[x]))
	for key in tiles.keys():
		max_texture = maxi(max_texture, str(key).to_int())
	materials.clear()
	materials.resize(max_texture + 1)
	for i in max_texture + 1:
		var d: Dictionary = tiles.get(str(i), {})
		var kind := str(d.get("type", "wall"))
		materials[i] = {
			"type": wall_type if kind == "wall" else (liquid_type if kind == "liquid" else (1 if kind == "passage" else 3)),
			"hp": int(d.get("hp", 1)),
			"bullet": bool(d.get("bullet_destroyable", false)),
			"explosion": bool(d.get("explosion_destroyable", false)),
			"elastic": bool(d.get("elastic", false)),
			"climb": float(d.get("climb_speed", 0.0)),
			"descent": float(d.get("climb_descent_speed", 0.0)),
			"decay": float(d.get("explosion_decay", blast_decay)),
			"ledge": int(d.get("collision_ledge", 0)),
		}
	_type_tex.resize(max_texture + 1)
	_bullet_tex.resize(max_texture + 1)
	_explosion_tex.resize(max_texture + 1)
	for i in max_texture + 1:
		var m: Dictionary = materials[i]
		_type_tex[i] = int(m["type"])
		_bullet_tex[i] = 1 if bool(m["bullet"]) else 0
		_explosion_tex[i] = 1 if bool(m["explosion"]) else 0
	_grid.resize(columns * rows)
	_tile_hp.resize(columns * rows)
	for y in rows:
		var row: Array = macro[y]
		for x in columns:
			var i := y * columns + x
			_grid[i] = int(row[x])
			_tile_hp[i] = int(_material(texture(_grid[i]))["hp"])
	sub_rows = subgrid.size()
	if sub_rows == 0 or sub_rows != rows * per_tile:
		push_error("Terrain: 子格行数与宏格不匹配")
		return
	sub_columns = (subgrid[0] as Array).size()
	if sub_columns != columns * per_tile:
		push_error("Terrain: 子格列数与宏格不匹配")
		return
	_textures.resize(sub_rows * sub_columns)
	_hp.resize(_textures.size())
	var texture_rows: Array = []
	for y in sub_rows:
		var snapshot_row: Array = []
		var row: Array = subgrid[y]
		if row.size() != sub_columns:
			push_error("Terrain: 子格行长度不一致")
			return
		for x in sub_columns:
			var tex := int(row[x])
			var i := y * sub_columns + x
			_textures[i] = tex
			_hp[i] = int(_material(tex)["hp"]) if tex else 0
			snapshot_row.append(tex)
		snapshot_row.make_read_only()
		texture_rows.append(snapshot_row)
	texture_rows.make_read_only()
	_subgrid_snapshot = texture_rows
	_initial_grid = _grid.duplicate()
	_initial_hp = _hp.duplicate()
	_initial_tile_hp = _tile_hp.duplicate()
	_base.clear()
	_authority.clear()
	_prediction.clear()
	_blast_kernels.clear()
	_network_changes.clear()
	_modified.clear()
	_rewards.clear()
	_rewind_pending.clear()
	_rewind_entries.clear()
	rewind_enabled = false
	_visual_changes.clear()
	_dirty.clear()
	revision = 0
	_floor_tick = -1
	_authority_tick = -1
	needs_state = false
	generation += 1
	permanent_dirty = true
	ledges_dirty = true
	_release_chunks()
	_grid_revision += 1
	_grid_snapshot_revision = -1

func _material(tex: int) -> Dictionary:
	if tex >= 0 and tex < materials.size():
		return materials[tex]
	return FALLBACK_MATERIAL

func empty() -> bool:
	return columns == 0 or rows == 0

func size() -> Vector2:
	return map_size

func set_empty_world_bounds(bounds: Vector2) -> void:
	if empty():
		map_size = bounds

func space_rid() -> RID:
	return _space

func set_authoritative(value: bool) -> void:
	authoritative = value

func cell(position: Vector2) -> Vector2i:
	if empty():
		return Vector2i()
	return Vector2i(_wrap(int(floor(position.x / tile_size)), columns),
			_wrap(int(floor(position.y / tile_size)), rows))

func value(at: Vector2i) -> int:
	return 0 if empty() else _grid[_wrap(at.y, rows) * columns + _wrap(at.x, columns)]

func sub_index(at: Vector2i) -> int:
	if at.x < 0 or at.y < 0 or at.x >= sub_columns or at.y >= sub_rows:
		return -1
	return at.y * sub_columns + at.x

func sub_position(i: int) -> Vector2i:
	return Vector2i(i % sub_columns, i / sub_columns)

func macro_of(i: int) -> int:
	return (i / sub_columns / per_tile) * columns + (i % sub_columns / per_tile)

func sub_texture(at: Vector2i) -> int:
	var i := sub_index(at)
	return 0 if i < 0 else _textures[i]

func get_hp(at: Vector2i) -> int:
	var i := sub_index(at)
	return 0 if i < 0 else _hp[i]

func sub_of(position: Vector2) -> Vector2i:
	if sub_columns == 0 or sub_rows == 0:
		return Vector2i()
	return Vector2i(_wrap(int(floor(position.x / sub_size)), sub_columns),
			_wrap(int(floor(position.y / sub_size)), sub_rows))

func climb_speed(tex: int) -> float:
	return float(_material(tex)["climb"])

func descent_speed(tex: int) -> float:
	return float(_material(tex)["descent"])

func water(position: Vector2) -> bool:
	var v := value(cell(position))
	return v != 0 and int(_material(texture(v))["type"]) == liquid_type

func water_surface(position: Vector2) -> float:
	if not water(position):
		return position.y
	var at := cell(position)
	var top := at.y
	for n in rows:
		var above := _wrap(top - 1, rows)
		var v := value(Vector2i(at.x, above))
		if v == 0 or int(_material(texture(v))["type"]) != liquid_type:
			return top * tile_size
		top = above
	return 0.0

func water_multiplier(position: Vector2) -> float:
	return float(_material(texture(value(cell(position))))["decay"]) if water(position) else 1.0

func cell_center(at: Vector2i) -> Vector2:
	return Vector2((at.x + 0.5) * tile_size, (at.y + 0.5) * tile_size)

## 遮挡查询走引擎射线：只有真实存在于物理空间的地形才遮挡。
## 连线按环面最短位移分段，跨接缝时每段都在规范世界内查询；
## 否则两端贴边的连线会改判成穿过整张地图的直线。
func line_of_sight(from: Vector2, to: Vector2) -> bool:
	if empty() or not _space.is_valid():
		return true
	var delta := GridPathfinder.toroidal_delta_px(from, to, map_size.x, map_size.y)
	if delta.is_zero_approx():
		return true
	var size := map_size
	var dir := delta.normalized()
	var p := GridPathfinder.wrap_to_range(from, size.x, size.y)
	var remaining := delta.length()
	var steps := maxi(1, ceili(remaining / maxf(minf(size.x, size.y), 1.0)) + 1)
	for guard in steps:
		if remaining <= 1e-6:
			return true
		var edge := CollisionWorld.seam_distance(p, dir, size)
		var run := minf(remaining, edge)
		if run <= 0.0:
			run = minf(remaining, 1e-3)
		if not _ray_between(p, p + dir * run).is_empty():
			return false
		p = GridPathfinder.wrap_to_range(p + dir * run, size.x, size.y)
		remaining -= run
	return true

func _ray_between(from: Vector2, to: Vector2) -> Dictionary:
	if not _space.is_valid():
		return {}
	_ray_state = PhysicsServer2D.space_get_direct_state(_space)
	_ray_params.from = from
	_ray_params.to = to
	_ray_params.collision_mask = CollisionWorld.LAYER_TERRAIN
	_ray_params.exclude = []
	_ray_params.collide_with_bodies = true
	_ray_params.collide_with_areas = false
	_ray_params.hit_from_inside = false
	var started := PerformanceStats.begin()
	var hit := _ray_state.intersect_ray(_ray_params)
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
	if empty() or _ray_state == null:
		points.append(origin + d * length)
		return {"points": points, "contacts": contacts, "hit_points": hit_points}
	var size := map_size
	var p := GridPathfinder.wrap_to_range(origin, size.x, size.y)
	var shift := origin - p
	var remaining := length
	var bounces := 0
	var ended_on_hit := false
	for guard in 10000:
		if remaining <= 0.0:
			break
		var edge := CollisionWorld.seam_distance(p, d, size)
		var run := minf(remaining, edge)
		if run < 1e-6:
			run = minf(remaining, 1e-3)
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
			p = point + d * 0.5
			remaining -= 0.5
			continue
		remaining -= run
		ended_on_hit = false
		if run >= edge:
			var wrapped := GridPathfinder.wrap_to_range(q, size.x, size.y)
			shift += q - wrapped
			p = wrapped
		else:
			p = q
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
			var kind := int(_material(texture(packed))["type"])
			if kind == wall_type or (with_liquid and kind == liquid_type):
				return true
	return false

func elastic_alive(position: Vector2) -> bool:
	var i := sub_index(sub_of(position))
	return i >= 0 and _hp[i] > 0 and bool(_material(_textures[i])["elastic"])

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

func get_subgrid_snapshot() -> Array:
	return _subgrid_snapshot

func _capture(at: int) -> Dictionary:
	var s := {"index": at, "value": _grid[at], "hp": _tile_hp[at], "subs": []}
	var subs: Array = s["subs"]
	for y in per_tile:
		for x in per_tile:
			var i := sub_index(Vector2i((at % columns) * per_tile + x, (at / columns) * per_tile + y))
			subs.append(_hp[i] if i >= 0 else 0)
	return s

func _capture_before(at: int) -> void:
	if rewind_enabled and not _rewind_pending.has(at):
		_rewind_pending[at] = _capture(at)

func capture_cell(at: Vector2i) -> Dictionary:
	if at.x < 0 or at.y < 0 or at.x >= columns or at.y >= rows:
		return {}
	var s := _capture(at.y * columns + at.x)
	var subs := PackedInt32Array()
	subs.resize(s["subs"].size())
	for i in subs.size():
		subs[i] = int(s["subs"][i])
	var d := {}
	d["cell"] = at
	d["tile"] = s["value"]
	d["hp"] = s["hp"]
	d["subs"] = subs
	return d

func _restore_cell(s: Dictionary) -> void:
	var index: int = s["index"]
	var subs: Array = s["subs"]
	for y in per_tile:
		for x in per_tile:
			var i := sub_index(Vector2i((index % columns) * per_tile + x, (index / columns) * per_tile + y))
			var offset := y * per_tile + x
			if i >= 0 and offset < subs.size():
				_write_hp(i, int(subs[offset]), false, false)
	if _grid[index] != s["value"]:
		var old_ledge := int(_material(texture(_grid[index]))["ledge"])
		var new_ledge := int(_material(texture(int(s["value"])))["ledge"])
		ledges_dirty = ledges_dirty or old_ledge != 0 or new_ledge != 0
		_grid[index] = int(s["value"])
		_grid_revision += 1
	if _tile_hp[index] != s["hp"]:
		_tile_hp[index] = int(s["hp"])

func _refresh_macro(at: int) -> void:
	var x0 := (at % columns) * per_tile
	var y0 := (at / columns) * per_tile
	var alive := false
	for y in range(y0, mini(y0 + per_tile, sub_rows)):
		if alive:
			break
		for x in range(x0, mini(x0 + per_tile, sub_columns)):
			if _hp[y * sub_columns + x] > 0:
				alive = true
				break
	var next := _initial_grid[at] if alive else 0
	if _grid[at] != next:
		_grid[at] = next
		_grid_revision += 1
		ledges_dirty = ledges_dirty or int(_material(texture(_initial_grid[at]))["ledge"]) != 0

func _mark_collision(index: int) -> void:
	var sub := sub_position(index)
	var chunk := Vector2i(sub.x / (chunk_cells * per_tile), sub.y / (chunk_cells * per_tile))
	var key := chunk.y * ((columns + chunk_cells - 1) / chunk_cells) + chunk.x
	_dirty[key] = true
	var m := _material(_textures[index])
	if int(m["type"]) == wall_type and not bool(m["bullet"]) and not bool(m["explosion"]):
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
	var m := _material(_textures[i])
	if not (bool(m["bullet"]) if source == 0 else bool(m["explosion"])):
		return false
	var modified := _write_hp(i, _hp[i] - amount, true, true, owner)
	if modified:
		changed.emit()
	return modified and _hp[i] == 0

func damage_impact(position: Vector2, normal: Vector2, amount: int, owner: int) -> int:
	if empty():
		return 0
	for probe in 3:
		var at := sub_of(position - normal * (probe * sub_size * 0.5))
		var tex := sub_texture(at)
		if tex != 0 and bool(_material(tex)["bullet"]):
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
	var m := _material(texture(_grid[i]))
	if not (bool(m["bullet"]) if source == 0 else bool(m["explosion"])):
		return false
	_capture_before(i)
	_tile_hp[i] = maxi(0, _tile_hp[i] - amount)
	if _tile_hp[i] > 0:
		return false
	for y in per_tile:
		for x in per_tile:
			var n := sub_index(at * per_tile + Vector2i(x, y))
			if n < 0:
				continue
			var part := _material(_textures[n])
			if bool(part["bullet"]) if source == 0 else bool(part["explosion"]):
				_write_hp(n, 0, false, true, owner)
	_refresh_macro(i)
	changed.emit()
	return _grid[i] == 0

func blast_cells(center: Vector2, radius: float, damage: int, include_dead: bool) -> Array:
	var out: Array = []
	if sub_columns == 0 or sub_rows == 0 or radius <= 0.0:
		return out
	var at := sub_of(center)
	var reach := int(ceil(radius / sub_size)) + 1
	var width := mini(2 * reach + 1, sub_columns)
	var height := mini(2 * reach + 1, sub_rows)
	for y in range(-reach, -reach + height):
		for x in range(-reach, -reach + width):
			var sx := _wrap(at.x + x, sub_columns)
			var sy := _wrap(at.y + y, sub_rows)
			var i := sy * sub_columns + sx
			if _textures[i] == 0 or (not include_dead and _hp[i] <= 0) \
					or _explosion_tex[_textures[i]] == 0:
				continue
			var d := GridPathfinder.toroidal_delta_px(center, Vector2((sx + 0.5) * sub_size, (sy + 0.5) * sub_size),
			map_size.x, map_size.y).length()
			if d > radius:
				continue
			var falloff := BlastCurve.falloff(d, radius, radius * blast_inner, float(damage))
			out.append([i, int(falloff * blast_decay)])
	return out

func destructible_subs(center: Vector2, radius: float, include_dead: bool) -> Array:
	var out: Array = []
	for entry in blast_cells(center, radius, 0, include_dead):
		var sub := sub_position(entry[0])
		var pos := Vector2(sub * sub_size) + Vector2(sub_size * 0.5, sub_size * 0.5)
		var d := {}
		d["sub"] = sub
		d["pos"] = pos
		d["tex"] = _textures[entry[0]]
		d["d"] = GridPathfinder.toroidal_delta_px(center, pos, map_size.x, map_size.y).length()
		out.append(d)
	return out

func damage_blast(center: Vector2, radius: float, damage: int, owner: int) -> int:
	var changed_count := 0
	for entry in blast_cells(center, radius, damage, false):
		if int(entry[1]) > 0 and _write_hp(entry[0], _hp[entry[0]] - int(entry[1]), true, true, owner):
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
	var recording := rewind_enabled
	rewind_enabled = false
	for i in _hp.size():
		_write_hp(i, _initial_hp[i], false, false)
	_grid = _initial_grid.duplicate()
	_tile_hp = _initial_tile_hp.duplicate()
	_base.clear()
	_authority.clear()
	_prediction.clear()
	_blast_kernels.clear()
	_network_changes.clear()
	_modified.clear()
	_rewards.clear()
	_rewind_pending.clear()
	_rewind_entries.clear()
	revision = revision + 1 if authoritative else 0
	_floor_tick = -1
	_authority_tick = -1
	needs_state = false
	generation += 1
	_grid_revision += 1
	rewind_enabled = recording
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
			var m := _material(_textures[i])
			var solid := _hp[i] > 0 and int(m["type"]) == wall_type \
					and (bool(m["bullet"]) or bool(m["explosion"])) == destructible
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
			result.append(Rect2(Vector2((x + x2 + 1) * sub_size * 0.5, (y + y2 + 1) * sub_size * 0.5),
					Vector2((x2 - x + 1) * sub_size, (y2 - y + 1) * sub_size)))
	return result

func _new_chunk() -> Dictionary:
	return {"body": RID(), "current": PackedInt64Array(), "layouts": [], "slots": 0}

# 物理空间由挂载节点决定：视口取自身世界，画节点取所在世界，
# 普通节点按它所在的视口取（服务端对局节点就是这种）。
static func _space_of(parent: Node) -> RID:
	var view := parent as Viewport
	var world: World2D = view.world_2d if view != null else null
	if world == null:
		var node := parent as Node2D
		if node != null:
			world = node.get_world_2d()
	if world == null:
		var viewport := parent.get_viewport()
		if viewport != null:
			world = viewport.world_2d
	return world.space if world != null else RID()

func _release_chunks() -> void:
	for chunk: Dictionary in _chunks.values():
		var body: RID = chunk["body"]
		if body.is_valid():
			PhysicsServer2D.free_rid(body)
	_chunks.clear()

# 句柄不受场景树托管：挂载节点退出场景树、或地形被替换时归还。
func close() -> void:
	_release_chunks()
	for rid: RID in _shape_rids.values():
		if rid.is_valid():
			PhysicsServer2D.free_rid(rid)
	_shape_rids.clear()

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

# 物理地形只补接缝附近的必要镜像：中部孤立墙只有一份形状，
# 贴边形状向对面补一份，贴角形状再补一份角落副本。视觉平铺仍由 TileMapLayer 负责。
func _lay_shapes(rects: Array) -> void:
	_placements.clear()
	var reach := CollisionWorld.SEAM_REACH
	var wide := map_size.x > reach * 2.0
	var tall := map_size.y > reach * 2.0
	for rect: Rect2 in rects:
		var shape := _shape_rid(rect.size)
		_placements.append([shape, Transform2D(0.0, rect.position)])
		# greedy() 返回的 position 是矩形中心，接缝判定必须用真实边界。
		var box := Rect2(rect.position - rect.size * 0.5, rect.size)
		var xs: Array = []
		if wide:
			if box.position.x < reach:
				xs.append(map_size.x)
			elif box.end.x > map_size.x - reach:
				xs.append(-map_size.x)
		var ys: Array = []
		if tall:
			if box.position.y < reach:
				ys.append(map_size.y)
			elif box.end.y > map_size.y - reach:
				ys.append(-map_size.y)
		for x in xs:
			_placements.append([shape, Transform2D(0.0, rect.position + Vector2(x, 0.0))])
		for y in ys:
			_placements.append([shape, Transform2D(0.0, rect.position + Vector2(0.0, y))])
		for x in xs:
			for y in ys:
				_placements.append([shape, Transform2D(0.0, rect.position + Vector2(x, y))])

# 碰撞几何直接写进物理空间，不建场景节点。槽位按索引更新，数量变化时才整体重建。
func submit(chunk: Dictionary, signature: PackedInt64Array, rects: Array) -> bool:
	if not _space.is_valid():
		return false
	var body: RID = chunk["body"]
	if body.is_valid() and chunk["current"] == signature:
		return false
	if not body.is_valid():
		body = PhysicsServer2D.body_create()
		PhysicsServer2D.body_set_mode(body, PhysicsServer2D.BODY_MODE_STATIC)
		PhysicsServer2D.body_set_collision_layer(body, 1)
		PhysicsServer2D.body_set_collision_mask(body, 0)
		PhysicsServer2D.body_set_space(body, _space)
		chunk["body"] = body
	_lay_shapes(rects)
	if int(chunk["slots"]) == _placements.size():
		for i in _placements.size():
			var entry: Array = _placements[i]
			PhysicsServer2D.body_set_shape(body, i, entry[0])
			PhysicsServer2D.body_set_shape_transform(body, i, entry[1])
	else:
		PhysicsServer2D.body_clear_shapes(body)
		for entry: Array in _placements:
			PhysicsServer2D.body_add_shape(body, entry[0], entry[1])
		chunk["slots"] = _placements.size()
	# 静态体的形状改动必须重设自身变换后才会进入宽相；否则同帧查询看不到新几何。
	PhysicsServer2D.body_set_state(body, PhysicsServer2D.BODY_STATE_TRANSFORM, Transform2D.IDENTITY)
	chunk["current"] = signature
	return true

# 观测用：某个分块当前写入空间的形状中心；接缝镜像的数量由这份布局核对。
func body_shapes(key: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	var chunk: Dictionary = _chunks.get(key, {})
	var body: RID = chunk.get("body", RID())
	if not body.is_valid():
		return out
	for i in PhysicsServer2D.body_get_shape_count(body):
		out.append(PhysicsServer2D.body_get_shape_transform(body, i).origin)
	return out

func rebuild(key: int) -> bool:
	var count := (columns + chunk_cells - 1) / chunk_cells
	var span := chunk_cells * per_tile
	var x0 := (key % count) * span
	var y0 := (key / count) * span
	var x1 := mini(x0 + span, sub_columns)
	var y1 := mini(y0 + span, sub_rows)
	var signature := PackedInt64Array([sub_columns, sub_rows, sub_size])
	for y in range(y0, y1):
		var bits := 0
		for x in range(x0, x1):
			var i := y * sub_columns + x
			var tex := _textures[i]
			if _hp[i] > 0 and _type_tex[tex] == wall_type \
					and (_bullet_tex[tex] != 0 or _explosion_tex[tex] != 0):
				bits |= 1 << (x - x0)
		signature.append(bits)
	if not _chunks.has(key):
		_chunks[key] = _new_chunk()
	var chunk: Dictionary = _chunks[key]
	var selected: Dictionary = {}
	for layout: Dictionary in chunk["layouts"]:
		if layout["signature"] == signature:
			selected = layout
			break
	if selected.is_empty():
		chunk["layouts"].append({"signature": signature, "rects": greedy(x0, y0, x1, y1, true)})
		if chunk["layouts"].size() > cache_states:
			chunk["layouts"].pop_front()
		selected = chunk["layouts"].back()
	return submit(chunk, signature, selected["rects"])

func rebuild_permanent() -> void:
	var signature := PackedInt64Array([sub_columns, sub_rows, sub_size])
	var bits := 0
	var bit := 0
	for i in _hp.size():
		var tex := _textures[i]
		if _hp[i] > 0 and _type_tex[tex] == wall_type \
				and _bullet_tex[tex] == 0 and _explosion_tex[tex] == 0:
			bits |= 1 << bit
		bit += 1
		if bit == 64:
			signature.append(bits)
			bits = 0
			bit = 0
	if bit:
		signature.append(bits)
	if not _chunks.has(-1):
		_chunks[-1] = _new_chunk()
	var chunk: Dictionary = _chunks[-1]
	submit(chunk, signature, greedy(0, 0, sub_columns, sub_rows, false))
	permanent_dirty = false

func rebuild_ledges() -> void:
	var rects: Array = []
	var signature := PackedInt64Array([columns, rows, ledge_thickness])
	for i in _grid.size():
		var side := int(_material(texture(_grid[i]))["ledge"]) if _grid[i] else 0
		if side == 0:
			continue
		signature.append((i << 1) | (1 if side < 0 else 0))
		var x := i % columns
		var y := i / columns
		var center_y := y * tile_size + ledge_thickness * 0.5 if side > 0 \
				else (y + 1) * tile_size - ledge_thickness * 0.5
		rects.append(Rect2(Vector2((x + 0.5) * tile_size, center_y), Vector2(tile_size, ledge_thickness)))
	if not _chunks.has(-2):
		_chunks[-2] = _new_chunk()
	submit(_chunks[-2], signature, rects)
	ledges_dirty = false

func attach(parent: Node) -> void:
	if parent == null:
		push_error("Terrain: attach 需要父节点")
		return
	var space := _space_of(parent)
	if not space.is_valid():
		push_error("Terrain: attach 需要已在场景树中的节点")
		return
	var id := parent.get_instance_id()
	if _parent_id != id or space != _space:
		var old: Node = instance_from_id(_parent_id) if _parent_id != 0 else null
		if old != null and old.tree_exiting.is_connected(close):
			old.tree_exiting.disconnect(close)
		_release_chunks()
		_parent_id = id
		_space = space
		_ray_state = PhysicsServer2D.space_get_direct_state(space) if space.is_valid() else null
	if not parent.tree_exiting.is_connected(close):
		parent.tree_exiting.connect(close)
	permanent_dirty = true
	ledges_dirty = true
	invalidate_all()
	flush_collisions()

func flush_collisions() -> int:
	if _dirty.is_empty() and not permanent_dirty and not ledges_dirty:
		return 0
	var parent: Node = instance_from_id(_parent_id) if _parent_id != 0 else null
	if parent == null or empty() or not _space.is_valid():
		return 0
	var started := PerformanceStats.begin()
	if permanent_dirty:
		rebuild_permanent()
	if ledges_dirty:
		rebuild_ledges()
	var pending := _dirty
	_dirty = {}
	var count := pending.size()
	for key in pending:
		rebuild(key)
	PerformanceStats.end(PerformanceStats.TERRAIN_COMMIT, started)
	return count

func flush_visuals(layer: TileMapLayer) -> void:
	if layer == null:
		return
	for i in _visual_changes:
		var sub := sub_position(i)
		var atlas := Vector2i((sub.y % per_tile) * per_tile + sub.x % per_tile, _textures[i] - 1)
		for y in range(-1, 2):
			for x in range(-1, 2):
				var at := sub + Vector2i(x * sub_columns, y * sub_rows)
				if _hp[i] > 0:
					if layer.get_cell_source_id(at) != 0 or layer.get_cell_atlas_coords(at) != atlas:
						layer.set_cell(at, 0, atlas)
				elif layer.get_cell_source_id(at) != -1:
					layer.erase_cell(at)
	_visual_changes.clear()

func invalidate_chunk(at: Vector2i) -> void:
	var count := (columns + chunk_cells - 1) / chunk_cells
	if at.x < 0 or at.y < 0 or at.x >= count or at.y >= (rows + chunk_cells - 1) / chunk_cells:
		return
	_dirty[at.y * count + at.x] = true

func invalidate_all() -> void:
	permanent_dirty = true
	ledges_dirty = true
	for y in (rows + chunk_cells - 1) / chunk_cells:
		for x in (columns + chunk_cells - 1) / chunk_cells:
			invalidate_chunk(Vector2i(x, y))

func _values_at(at: int) -> Dictionary:
	var values := _base.duplicate()
	var ticks := _prediction.keys()
	ticks.sort()
	for tick in ticks:
		if tick > at:
			break
		var cells: Dictionary = _prediction[tick]
		for index in cells:
			values[index] = cells[index]["after"]
	return values

func _matches(at: int) -> bool:
	return at >= maxi(_floor_tick, _authority_tick) and _values_at(at) == _authority

func predict_blast(id: int, type: int, center: Vector2, tick: int, radius: float, damage: int) -> int:
	if not _blast_kernels.has(id):
		_blast_kernels[id] = {"position": Vector2(), "type": 0, "radius": 0.0,
			"damage": 0, "tick": 0, "cells": []}
	var kernel: Dictionary = _blast_kernels[id]
	if kernel["position"] != center or int(kernel["type"]) != type \
			or float(kernel["radius"]) != radius or int(kernel["damage"]) != damage:
		kernel["position"] = center
		kernel["type"] = type
		kernel["radius"] = radius
		kernel["damage"] = damage
		kernel["cells"] = blast_cells(center, radius, damage, true)
	kernel["tick"] = tick
	if not _prediction.has(tick):
		_prediction[tick] = {}
	var changes: Dictionary = _prediction[tick]
	var count := 0
	for cell in kernel["cells"]:
		var i: int = cell[0]
		var amount: int = cell[1]
		var before := _hp[i]
		if before <= 0 or amount <= 0:
			continue
		if not _base.has(i):
			_base[i] = before
			_authority[i] = before
		var after := maxi(0, before - amount)
		if not changes.has(i):
			changes[i] = {"before": before, "after": after}
		else:
			changes[i]["after"] = after
		if _write_hp(i, after, false, false):
			count += 1
	if changes.is_empty():
		_prediction.erase(tick)
	return count

func apply_authority(patch: Dictionary) -> void:
	var tick := int(patch["tick"])
	var cells: Dictionary = patch["cells"]
	var ticks := _prediction.keys()
	ticks.sort()
	for at in cells.keys():
		var i := sub_index(at)
		if i < 0:
			continue
		if not _base.has(i):
			_base[i] = _hp[i]
			_authority[i] = _hp[i]
		var next := int(cells[at])
		_authority[i] = next
		for pred_tick in ticks:
			if pred_tick > tick:
				var found: Dictionary = _prediction[pred_tick].get(i, {})
				if not found.is_empty():
					next = maxi(0, next - (int(found["before"]) - int(found["after"])))
		_write_hp(i, next, false, false)
	_authority_tick = maxi(_authority_tick, tick)
	revision = int(patch["revision"])
	needs_state = not _matches(_authority_tick)

func difference(tick: int, saved_generation: int, map_revision: int) -> String:
	if saved_generation != generation or tick < _floor_tick:
		return "terrain_history"
	if map_revision != revision or tick < _authority_tick:
		return "map_revision"
	return "" if _matches(tick) else "terrain_state"

func can_restore(tick: int, saved_generation: int) -> bool:
	return saved_generation == generation and tick >= maxi(_floor_tick, _authority_tick) and not needs_state

func restore_checkpoint(tick: int) -> void:
	var values := _values_at(tick)
	for index in values:
		_write_hp(index, int(values[index]), false, false)
	var ticks := _prediction.keys()
	ticks.sort()
	for pred_tick in ticks:
		if pred_tick > tick:
			_prediction.erase(pred_tick)
	flush_collisions()

func acknowledge(tick: int) -> void:
	_floor_tick = tick
	_base = _authority.duplicate()
	var ticks := _prediction.keys()
	ticks.sort()
	for pred_tick in ticks:
		if pred_tick <= tick:
			_prediction.erase(pred_tick)
	for id in _blast_kernels.keys():
		if int(_blast_kernels[id]["tick"]) <= tick:
			_blast_kernels.erase(id)
	var future := {}
	for pred_tick in _prediction:
		for index in _prediction[pred_tick]:
			future[index] = true
	for index in _base.keys():
		if not future.has(index):
			_authority.erase(index)
			_base.erase(index)
	needs_state = false

func prune_before(tick: int) -> void:
	if tick <= _floor_tick:
		return
	_base = _values_at(tick)
	_floor_tick = tick
	var ticks := _prediction.keys()
	ticks.sort()
	for pred_tick in ticks:
		if pred_tick <= tick:
			_prediction.erase(pred_tick)
	for id in _blast_kernels.keys():
		if int(_blast_kernels[id]["tick"]) <= tick:
			_blast_kernels.erase(id)

func reset_prediction(tick: int) -> void:
	for index in _authority:
		_write_hp(index, int(_authority[index]), false, false)
	_base.clear()
	_authority.clear()
	_prediction.clear()
	for id in _blast_kernels.keys():
		if tick < 0 or int(_blast_kernels[id]["tick"]) <= tick:
			_blast_kernels.erase(id)
	_floor_tick = tick
	_authority_tick = tick
	generation += 1
	needs_state = false

func set_rewind_enabled(enabled: bool) -> void:
	rewind_enabled = enabled

func seal_rewind(time: float) -> void:
	if _rewind_pending.is_empty():
		return
	var indices := _rewind_pending.keys()
	indices.sort()
	var cells: Array = []
	for index in indices:
		cells.append(_rewind_pending[index])
	_rewind_pending.clear()
	_rewind_entries.append({"time": time, "cells": cells})

func _upper_bound_time(value: float, from: int, to: int) -> int:
	var lo := from
	var hi := to
	while lo < hi:
		var mid := (lo + hi) / 2
		if value < float(_rewind_entries[mid]["time"]):
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
		var cells: Array = _rewind_entries[end]["cells"]
		for i in range(cells.size() - 1, -1, -1):
			_restore_cell(cells[i])
	flush_collisions()

func prune_rewind(cutoff: float) -> void:
	while not _rewind_entries.is_empty() and float(_rewind_entries[0]["time"]) < cutoff:
		_rewind_entries.pop_front()

func truncate_rewind(time: float) -> void:
	while not _rewind_entries.is_empty() and float(_rewind_entries.back()["time"]) > time:
		_rewind_entries.pop_back()
	_rewind_pending.clear()
