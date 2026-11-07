class_name TileDefs
extends RefCounted

# 砖块属性表(data/tile_defs.json 单一来源)。未加载时默认"非 0 即墙"(旧行为),保证早期调用/冒烟测试兼容。
# ★ 性能:热点判定每帧被寻路/LOS/水判定反复调用 ⇒ load_defs 后把属性压进按纹理索引的定长数组,查询 O(1) 零分配(旧实现每次 str(tex) 分配 + 2 次字典查询)。

const PATH: String = "res://data/tile_defs.json"
const MAX_TEXTURE: int = 22

static var _defs: Dictionary = {}
static var _loaded := false

const TYPE_WALL: int = 0
const TYPE_PASSAGE: int = 1
const TYPE_LIQUID: int = 2
const TYPE_GAS: int = 3
const _TYPE_NAMES: Array = ["wall", "passage", "liquid", "gas"]

static var _type: PackedByteArray = PackedByteArray()
static var _hp: PackedInt32Array = PackedInt32Array()
static var _bullet_destroyable: PackedByteArray = PackedByteArray()
static var _explosion_destroyable: PackedByteArray = PackedByteArray()
static var _elastic: PackedByteArray = PackedByteArray()
static var _climb_speed: PackedFloat32Array = PackedFloat32Array()
static var _climb_descent: PackedFloat32Array = PackedFloat32Array()
static var _decay: PackedFloat32Array = PackedFloat32Array()
# 材质类(渲染用):0=stone 1=metal 2=foliage 3=wood 4=water。来自 data/tile_defs.json 的 material 字段。
static var _material: PackedByteArray = PackedByteArray()
const MAT_STONE: int = 0
const MAT_METAL: int = 1
const MAT_FOLIAGE: int = 2
const MAT_WOOD: int = 3
const MAT_WATER: int = 4
# 旧图集废弃槽位 → (base 纹理, hue 档) 的读时迁移表(data/tile_defs.json 的 legacy_texture_map 单一来源;0 = 非 legacy)。
static var _legacy_base: PackedInt32Array = PackedInt32Array()
static var _legacy_hue: PackedInt32Array = PackedInt32Array()
static var _tables_built := false

static func _ensure_tables() -> void:
	if _tables_built:
		return
	_tables_built = true
	var n := MAX_TEXTURE + 1
	_type.resize(n)
	_hp.resize(n)
	_bullet_destroyable.resize(n)
	_explosion_destroyable.resize(n)
	_elastic.resize(n)
	_climb_speed.resize(n)
	_climb_descent.resize(n)
	_decay.resize(n)
	_material.resize(n)
	_legacy_base.resize(n)
	_legacy_hue.resize(n)
	_type.fill(TYPE_WALL)
	_hp.fill(1)
	_bullet_destroyable.fill(0)
	_explosion_destroyable.fill(0)
	_elastic.fill(0)
	_climb_speed.fill(0.0)
	_climb_descent.fill(0.0)
	_legacy_base.fill(0)
	_legacy_hue.fill(0)
	var fallback := float(_defs.get("explosion_decay", 0.75))
	_decay.fill(fallback)
	_material.fill(MAT_STONE)
	var legacy: Dictionary = _defs.get("legacy_texture_map", {})
	for key in legacy:
		var ltex := int(String(key))
		if ltex < 1 or ltex >= n:
			continue
		var entry: Dictionary = legacy[key]
		_legacy_base[ltex] = int(entry.get("base", 0))
		_legacy_hue[ltex] = int(entry.get("hue", 4))
	var tiles: Dictionary = _defs.get("tiles", {})
	for tex in range(1, n):
		var d: Dictionary = tiles.get(str(tex), {})
		var t := String(d.get("type", "wall"))
		var tid := TYPE_WALL
		if t == "passage":
			tid = TYPE_PASSAGE
		elif t == "liquid":
			tid = TYPE_LIQUID
		elif t == "gas":
			tid = TYPE_GAS
		_type[tex] = tid
		_hp[tex] = int(d.get("hp", 1))
		_material[tex] = _material_id_of(String(d.get("material", "stone")))
		_bullet_destroyable[tex] = 1 if bool(d.get("bullet_destroyable", false)) else 0
		_explosion_destroyable[tex] = 1 if bool(d.get("explosion_destroyable", false)) else 0
		_elastic[tex] = 1 if bool(d.get("elastic", false)) else 0
		_climb_speed[tex] = float(d.get("climb_speed", 0.0))
		_climb_descent[tex] = float(d.get("climb_descent_speed", 0.0))
		_decay[tex] = float(d.get("explosion_decay", fallback))


# legacy 纹理读时迁移口(表 = data/tile_defs.json 的 legacy_texture_map,单一来源):非 legacy 一律返回 0。
# ★ 先 load_defs 再查表:迁移的第一入口在格式层(MapFormatV4.parse),它跑在生产侧任何显式 load_defs 之前。
static func legacy_base_of(tex: int) -> int:
	load_defs()
	if tex < 1 or tex > MAX_TEXTURE:
		return 0
	return _legacy_base[tex]


static func legacy_hue_of(tex: int) -> int:
	load_defs()
	if tex < 1 or tex > MAX_TEXTURE:
		return 0
	return _legacy_hue[tex]


static func load_defs() -> void:
	if _loaded:
		return
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		push_error("TileDefs: 无法打开 %s" % PATH)
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		_defs = parsed
	else:
		push_error("TileDefs: %s 解析失败" % PATH)
	_loaded = true
	_tables_built = false
	_ensure_tables()


static func explosion_decay() -> float:
	return float(_defs.get("explosion_decay", 0.75))


static func explosion_decay_of(texture: int) -> float:
	_ensure_tables()
	if texture < 0 or texture > MAX_TEXTURE:
		return explosion_decay()
	return _decay[texture]


static func type_id_of(texture: int) -> int:
	_ensure_tables()
	if texture < 0 or texture > MAX_TEXTURE:
		return TYPE_WALL
	return int(_type[texture])


static func is_liquid(texture: int) -> bool:
	return type_id_of(texture) == TYPE_LIQUID


static func hp_of(texture: int) -> int:
	_ensure_tables()
	if texture < 0 or texture > MAX_TEXTURE:
		return 1
	return _hp[texture]


static func bullet_destroyable(texture: int) -> bool:
	_ensure_tables()
	if texture < 0 or texture > MAX_TEXTURE:
		return false
	return _bullet_destroyable[texture] != 0


static func explosion_destroyable(texture: int) -> bool:
	_ensure_tables()
	if texture < 0 or texture > MAX_TEXTURE:
		return false
	return _explosion_destroyable[texture] != 0


static func elastic(texture: int) -> bool:
	_ensure_tables()
	if texture < 0 or texture > MAX_TEXTURE:
		return false
	return _elastic[texture] != 0


static func climb_speed(texture: int) -> float:
	_ensure_tables()
	if texture < 0 or texture > MAX_TEXTURE:
		return 0.0
	return _climb_speed[texture]


static func climb_descent_speed(texture: int) -> float:
	_ensure_tables()
	if texture < 0 or texture > MAX_TEXTURE:
		return 0.0
	return _climb_descent[texture]


static func is_blocked(v: int) -> bool:
	if v == 0:
		return false
	return type_id_of(MazeGenerator.texture_of(v)) == TYPE_WALL


static var hp_grid: Array[Array] = []
static var on_destroyed: Callable = Callable()

static func init_hp(grid: Array) -> void:
	hp_grid = []
	for row in grid:
		var r: Array[int] = []
		for v in row:
			r.append(hp_of(MazeGenerator.texture_of(v)))
		hp_grid.append(r)


static func hp_grid_at(cell: Vector2i) -> int:
	if cell.y < 0 or cell.y >= hp_grid.size() or cell.x < 0 or cell.x >= hp_grid[cell.y].size():
		return 0
	return int(hp_grid[cell.y][cell.x])


# 格级 HP 的写入口(越界静默不写)。★ 写口留在本类:格级 hp_grid 与子格 sub_hp 的分家正是"幽灵砖"的根因,别再让调用方直接写数组。
static func set_hp_grid(cell: Vector2i, hp: int) -> void:
	if cell.y < 0 or cell.y >= hp_grid.size() or cell.x < 0 or cell.x >= hp_grid[cell.y].size():
		return
	hp_grid[cell.y][cell.x] = hp


static var sub_hp: PackedInt32Array = PackedInt32Array()
static var sub_cols: int = 0
static var sub_rows: int = 0
static var on_sub_destroyed: Callable = Callable()


static var _sub_hp_cache: Dictionary = {}


static func init_sub_hp(sgrid: Array) -> void:
	sub_cols = 0
	sub_rows = 0
	sub_hp = PackedInt32Array()
	if sgrid.is_empty():
		return
	sub_rows = sgrid.size()
	sub_cols = (sgrid[0] as Array).size()
	var n := sub_cols * sub_rows
	var hit: PackedInt32Array = _sub_hp_cache.get(MazeGenerator.map_file_path(), PackedInt32Array())
	if hit.size() == n and _hp_sample_matches(hit, sgrid):
		sub_hp = hit.duplicate()
		return
	sub_hp.resize(n)
	for y in sub_rows:
		var row: Array = sgrid[y]
		for x in sub_cols:
			var tex := int(row[x])
			sub_hp[y * sub_cols + x] = hp_of(tex) if tex != 0 else 0
	_sub_hp_cache[MazeGenerator.map_file_path()] = sub_hp.duplicate()


static func _hp_sample_matches(hit: PackedInt32Array, sgrid: Array) -> bool:
	var rows := sgrid.size()
	var cols: int = (sgrid[0] as Array).size()
	var n := rows * cols
	var probes := [[0, 0], [rows / 2, cols / 2], [rows - 1, cols - 1]]
	for pr in probes:
		var y: int = pr[0]
		var x: int = pr[1]
		var tex := int((sgrid[y] as Array)[x])
		if int(hit[y * cols + x]) != (hp_of(tex) if tex != 0 else 0):
			return false
	return n > 0


static func sub_texture(sub: Vector2i) -> int:
	var sgrid := MazeGenerator.current_subgrid
	if sgrid.is_empty() or sub.y < 0 or sub.y >= sgrid.size():
		return 0
	var row: Array = sgrid[sub.y]
	if sub.x < 0 or sub.x >= row.size():
		return 0
	return int(row[sub.x])


static func sub_alive(sub: Vector2i) -> bool:
	return sub_hp[sub.y * sub_cols + sub.x] > 0


static func sub_hp_at(sub: Vector2i) -> int:
	if sub_cols == 0 or sub.x < 0 or sub.y < 0 or sub.x >= sub_cols or sub.y >= sub_rows:
		return 0
	var idx := sub.y * sub_cols + sub.x
	if idx < 0 or idx >= sub_hp.size():
		return 0
	return int(sub_hp[idx])


static func damage_block32(block: Vector2i, amount: int, source: String, owner: Node = null) -> int:
	var n := 0
	for sy in 2:
		for sx in 2:
			if damage_sub(Vector2i(block.x * 2 + sx, block.y * 2 + sy), amount, source, owner):
				n += 1
	return n


static func damage_sub(sub: Vector2i, amount: int, source: String, owner: Node = null) -> bool:
	if sub_cols == 0 or sub.x < 0 or sub.y < 0 or sub.x >= sub_cols or sub.y >= sub_rows:
		return false
	var tex := sub_texture(sub)
	if tex == 0 or sub_hp[sub.y * sub_cols + sub.x] <= 0:
		return false
	if source == "bullet":
		if not bullet_destroyable(tex):
			return false
	else:
		if not explosion_destroyable(tex):
			return false
	var idx := sub.y * sub_cols + sub.x
	var pre_hp := sub_hp[idx]
	sub_hp[idx] = pre_hp - amount
	if sub_hp[idx] <= 0:
		sub_hp[idx] = 0
		var grid := MazeGenerator.current_grid
		if not grid.is_empty():
			var cell := Vector2i(sub.x / 4, sub.y / 4)
			var alive := false
			for sy in 4:
				for sx in 4:
					var sx2 := cell.x * 4 + sx
					var sy2 := cell.y * 4 + sy
					if sx2 < sub_cols and sy2 < sub_rows and sub_hp[sy2 * sub_cols + sx2] > 0:
						alive = true
						break
				if alive:
					break
			if not alive and grid[cell.y][cell.x] != 0:
				grid[cell.y][cell.x] = 0
				# 两本账在"格子已消失"这点上对齐:格级 hp_grid 必须同步归 0,否则回溯复原按 hp_grid_at>0 认为
				# 这格还有折减后的血量、把子格级路径清空的格当成"磨过但没死"(只清 grid 不碰 hp_grid 正是旧的缺口)。
				if not hp_grid.is_empty() and cell.y < hp_grid.size() and cell.x < hp_grid[cell.y].size():
					hp_grid[cell.y][cell.x] = 0
		if on_sub_destroyed.is_valid():
			on_sub_destroyed.call(sub, pre_hp, owner)
		return true
	return false


static func restore_sub(sub: Vector2i, hp: int) -> void:
	if sub_cols == 0 or sub.x < 0 or sub.y < 0 or sub.x >= sub_cols or sub.y >= sub_rows:
		return
	sub_hp[sub.y * sub_cols + sub.x] = hp


static func zero_cell_sub_hp(cell: Vector2i) -> void:
	if sub_cols == 0:
		return
	for sy in 4:
		for sx in 4:
			restore_sub(Vector2i(cell.x * 4 + sx, cell.y * 4 + sy), 0)


static func destroy_cell(cell: Vector2i) -> void:
	if sub_cols == 0 or sub_rows == 0:
		return
	var subs: Array[Vector2i] = []
	var pre_hp: Array[int] = []
	for sy in 4:
		for sx in 4:
			var sub := Vector2i(cell.x * 4 + sx, cell.y * 4 + sy)
			if sub.x < 0 or sub.y < 0 or sub.x >= sub_cols or sub.y >= sub_rows:
				continue
			if not sub_alive(sub):
				continue
			subs.append(sub)
			pre_hp.append(sub_hp[sub.y * sub_cols + sub.x])
	zero_cell_sub_hp(cell)
	if not on_sub_destroyed.is_valid():
		return
	for i in subs.size():
		on_sub_destroyed.call(subs[i], pre_hp[i], null)


static func damage_tile(cell: Vector2i, amount: int, source: String) -> bool:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return false
	if cell.y < 0 or cell.y >= grid.size() or cell.x < 0 or cell.x >= grid[cell.y].size():
		return false
	var v: int = grid[cell.y][cell.x]
	if v == 0:
		return false
	var tex: int = MazeGenerator.texture_of(v)
	if source == "bullet":
		if not bullet_destroyable(tex):
			return false
	else:
		if not explosion_destroyable(tex):
			return false
	if hp_grid.is_empty():
		init_hp(grid)
	hp_grid[cell.y][cell.x] -= amount
	if hp_grid[cell.y][cell.x] <= 0:
		grid[cell.y][cell.x] = 0
		hp_grid[cell.y][cell.x] = 0
		if on_destroyed.is_valid():
			on_destroyed.call(cell)
		return true
	return false


static func _material_id_of(name: String) -> int:
	match name:
		"metal":
			return MAT_METAL
		"foliage":
			return MAT_FOLIAGE
		"wood":
			return MAT_WOOD
		"water":
			return MAT_WATER
		_:
			return MAT_STONE


## 某纹理的材质类(渲染用)。未加载定义时一律 stone,保证旧行为。
static func material_id(tex: int) -> int:
	_ensure_tables()
	if tex <= 0 or tex >= _material.size():
		return MAT_STONE
	return _material[tex]
