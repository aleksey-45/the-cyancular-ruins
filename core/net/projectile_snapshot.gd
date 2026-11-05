class_name ProjectileSnapshot
extends RefCounted

# 每帧一条 id -> PackedFloat64Array 的弹丸运动值。
# 表按帧独立持有；表内数组视为只读，更新时整体替换。
# 网络字典与后续帧都不能改写已发布快照。

const TYPE := 0
const PX := 1
const PY := 2
const VX := 3
const VY := 4
const TRAVELED := 5
const FUSE_ELAPSED := 6
const FUSE_DURATION := 7
const FLAGS := 8
const STRIDE := 9
const FUSE_ACTIVE := 1
const DIRECT_HIT := 2

var _values: Dictionary = {}

static func capture(entries: Dictionary) -> ProjectileSnapshot:
	var saved := ProjectileSnapshot.new()
	for id: int in entries:
		var entry: ProjectileEntry = entries[id]
		if entry == null or not entry.active:
			continue
		var body: BulletBody = entry.get_bullet()
		if body == null or body.finished:
			continue
		saved._values[id] = pack_body(body)
	return saved

# 槽位布局只在这里定义：实体与字典两种来源各自填入同一组下标。
static func pack_body(body: BulletBody) -> PackedFloat64Array:
	var values := PackedFloat64Array()
	values.resize(STRIDE)
	values[TYPE] = float(body.type_id)
	values[PX] = body.position.x
	values[PY] = body.position.y
	values[VX] = body.velocity_vec.x
	values[VY] = body.velocity_vec.y
	values[TRAVELED] = body.traveled
	values[FUSE_ELAPSED] = body._fuse_elapsed
	values[FUSE_DURATION] = body._fuse_duration
	values[FLAGS] = (FUSE_ACTIVE if body._fuse_active else 0.0) + (DIRECT_HIT if body.direct_hit else 0.0)
	return values

static func _pack(state: Dictionary) -> PackedFloat64Array:
	var values := PackedFloat64Array()
	values.resize(STRIDE)
	values[TYPE] = float(int(state["type_id"]))
	values[PX] = state["pos"].x
	values[PY] = state["pos"].y
	values[VX] = state["vel"].x
	values[VY] = state["vel"].y
	values[TRAVELED] = float(state["traveled"])
	values[FUSE_ELAPSED] = float(state["fuse_elapsed"])
	values[FUSE_DURATION] = float(state["fuse_duration"])
	values[FLAGS] = (FUSE_ACTIVE if bool(state["fuse_active"]) else 0.0) + (DIRECT_HIT if bool(state["direct_hit"]) else 0.0)
	return values

static func _state_of(values: PackedFloat64Array) -> Dictionary:
	return {"type_id": int(values[TYPE]), "pos": Vector2(values[PX], values[PY]),
		"vel": Vector2(values[VX], values[VY]), "traveled": values[TRAVELED],
		"fuse_elapsed": values[FUSE_ELAPSED], "fuse_duration": values[FUSE_DURATION],
		"fuse_active": (int(values[FLAGS]) & FUSE_ACTIVE) != 0,
		"direct_hit": (int(values[FLAGS]) & DIRECT_HIT) != 0}

static func _matches(values: PackedFloat64Array, state: Dictionary) -> bool:
	return _pack(state) == values

func matches(states: Dictionary, role := 0) -> bool:
	var count := 0
	for id: int in _values:
		if role != 0 and (id >> 48) != role:
			continue
		if not states.has(id) or not _matches(_values[id], states[id]):
			return false
		count += 1
	return count == states.size()

func state_matches(id: int, state: Dictionary) -> bool:
	return _values.has(id) and _matches(_values[id], state)

func can_restore(entries: Dictionary, tick: int) -> bool:
	for id: int in _values:
		if not entries.has(id):
			return false
		var entry: ProjectileEntry = entries[id]
		var body: BulletBody = entry.get_bullet() if entry != null else null
		if body == null or body.type_id != int(_values[id][TYPE]) \
				or (entry.confirmed and entry.birth_tick > tick):
			return false
	return true

func restore(entries: Dictionary, tick: int) -> void:
	for id: int in entries:
		var entry: ProjectileEntry = entries[id]
		if _values.has(id):
			entry.restore_at(_state_of(_values[id]), tick)
		else:
			entry.active = false
			var body: BulletBody = entry.get_bullet()
			if body != null:
				body.finished = true
