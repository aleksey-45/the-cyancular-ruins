class_name TileDefs
extends RefCounted

# 砖块属性表(data/tile_defs.json 单一来源)。level_0._ready 调用 load_defs() 后使用。
# 未加载时默认"非 0 即墙"(旧行为),保证早期调用/冒烟测试兼容。
#
# 性能:热点判定(is_blocked/type/elastic/liquid/destroyable 等)每帧被寻路/LOS/水判定
# 反复调用。旧实现每次 `tile(tex)` → `str(tex)` 字符串分配 + 2 次字典查询;这里在
# load_defs 后把全部纹理属性压进「按纹理索引」的定长数组,查询 O(1) 零分配。
# 数组在 load_defs 时重建;若从未 load,也用与旧「空字典缺省」一致的默认值填一次。

const PATH: String = "res://data/tile_defs.json"
const MAX_TEXTURE: int = 22

static var _defs: Dictionary = {}
static var _loaded := false

# 纹理类型 id(避免每格一次字符串比较)。
const TYPE_WALL: int = 0
const TYPE_PASSAGE: int = 1
const TYPE_LIQUID: int = 2
const TYPE_GAS: int = 3
const _TYPE_NAMES: Array = ["wall", "passage", "liquid", "gas"]

# ── 预计算属性表(索引 = 纹理 0..MAX_TEXTURE)──
static var _type: PackedByteArray = PackedByteArray()          # 类型 id
static var _hp: PackedInt32Array = PackedInt32Array()
static var _bullet_destroyable: PackedByteArray = PackedByteArray()
static var _explosion_destroyable: PackedByteArray = PackedByteArray()
static var _elastic: PackedByteArray = PackedByteArray()
static var _climb_speed: PackedFloat32Array = PackedFloat32Array()
static var _climb_descent: PackedFloat32Array = PackedFloat32Array()
static var _decay: PackedFloat32Array = PackedFloat32Array()   # 逐格爆炸衰减(缺省回落全局)
static var _tables_built := false

# 未加载 defs 时的缺省,须与旧 `tile(tex).get(..., 缺省)` 完全一致:
# 任意纹理 type 缺省 wall、hp 1、各开关 false、climb 0、衰减回落全局 0.75。
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
	_type.fill(TYPE_WALL)
	_hp.fill(1)
	_bullet_destroyable.fill(0)
	_explosion_destroyable.fill(0)
	_elastic.fill(0)
	_climb_speed.fill(0.0)
	_climb_descent.fill(0.0)
	var fallback := float(_defs.get("explosion_decay", 0.75))
	_decay.fill(fallback)
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
		_bullet_destroyable[tex] = 1 if bool(d.get("bullet_destroyable", false)) else 0
		_explosion_destroyable[tex] = 1 if bool(d.get("explosion_destroyable", false)) else 0
		_elastic[tex] = 1 if bool(d.get("elastic", false)) else 0
		_climb_speed[tex] = float(d.get("climb_speed", 0.0))
		_climb_descent[tex] = float(d.get("climb_descent_speed", 0.0))
		_decay[tex] = float(d.get("explosion_decay", fallback))


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
	# defs 改变 → 重建属性表(把先前可能的"未加载缺省表"覆盖成真实值)
	_tables_built = false
	_ensure_tables()


static func explosion_decay() -> float:
	return float(_defs.get("explosion_decay", 0.75))


# 逐格爆炸衰减(水 0.25);缺省回落全局 explosion_decay()。
static func explosion_decay_of(texture: int) -> float:
	_ensure_tables()
	if texture < 0 or texture > MAX_TEXTURE:
		return explosion_decay()
	return _decay[texture]


# 旧接口保留(少量非热点调用/tests 仍比对字符串);内部走预计算表。
static func type_of(texture: int) -> String:
	var tid := type_id_of(texture)
	return _TYPE_NAMES[tid] if tid >= 0 and tid < _TYPE_NAMES.size() else "wall"


# 类型 id(热点:寻路/LOS/水判定),省去字符串比较。
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


# 攀爬下降速度倍率(梯子 2.0;锁链无此字段 → 0,玩家下降走自由落体)。
static func climb_descent_speed(texture: int) -> float:
	_ensure_tables()
	if texture < 0 or texture > MAX_TEXTURE:
		return 0.0
	return _climb_descent[texture]


# packed 格值 → 是否挡路:非 0 且 type=wall。
static func is_blocked(v: int) -> bool:
	if v == 0:
		return false
	return type_id_of(MazeGenerator.texture_of(v)) == TYPE_WALL


# ── 运行时破坏(与 MazeGenerator.current_grid 同尺寸的当前 HP 表)──
static var hp_grid: Array[Array] = []
# 瓦片被破坏(变空气)后的回调,由 level_0 注册(清瓦片层 + 重建碰撞)。
# 用 Callable 而不是硬引用 Level0,避免场景脚本依赖 autoload 导致 -s 测试编译失败。
static var on_destroyed: Callable = Callable()

static func init_hp(grid: Array) -> void:
	hp_grid = []
	for row in grid:
		var r: Array[int] = []
		for v in row:
			r.append(hp_of(MazeGenerator.texture_of(v)))
		hp_grid.append(r)


# ── cyrm v4 子格破坏(选项 A:破坏按 16px 子格算,格级 current_grid 在整格死光时才清零)──
# sub_hp 下标 = sub_y * sub_cols + sub_x;0 = 空气或已摧毁。纹理永远读
# MazeGenerator.current_subgrid(它不变,摧毁改的是 hp)。
static var sub_hp: PackedInt32Array = PackedInt32Array()
static var sub_cols: int = 0
static var sub_rows: int = 0
# 子格被摧毁的回调,由 level_0(渲染/账本/碰撞)与 worker(广播/颗粒结算)分别注册。
# 参数 (sub: Vector2i, pre_hp: int, owner: Node) —— pre_hp 供回溯账本记"改前值";
# owner = 造成破坏的射手节点(子弹的 shooter / 爆炸的 shooter;单人模式由 Level0 忽略,
# worker 侧用它映射 role 结算"破坏瓦片得颗粒")。
static var on_sub_destroyed: Callable = Callable()


static func init_sub_hp(sgrid: Array) -> void:
	sub_cols = 0
	sub_rows = 0
	sub_hp = PackedInt32Array()
	if sgrid.is_empty():
		return
	sub_rows = sgrid.size()
	sub_cols = (sgrid[0] as Array).size()
	sub_hp.resize(sub_cols * sub_rows)
	for y in sub_rows:
		var row: Array = sgrid[y]
		for x in sub_cols:
			var tex := int(row[x])
			sub_hp[y * sub_cols + x] = hp_of(tex) if tex != 0 else 0


static func sub_of(pos: Vector2) -> Vector2i:
	return Vector2i(posmod(int(pos.x) / 16, sub_cols), posmod(int(pos.y) / 16, sub_rows))


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


## 对单个 16px 子格扣除生命值。source 为 "bullet"/"explosion",按对应可破坏开关判定。
## 扣到 ≤0 → 该子格死亡(回调 level_0 清渲染/记账本/重建碰撞块);所属 64px 格的全部
## 子格死光时,把格级 current_grid 该格清零(让 20 个格级逻辑调用方看到它消失)。
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
		# 所属 64px 格全部子格死光 → 格级网格清零(选项 A:逻辑层只看格)
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
		if on_sub_destroyed.is_valid():
			on_sub_destroyed.call(sub, pre_hp, owner)
		return true
	return false


## 回溯还原:把子格 HP 写回(渲染/碰撞由 level_0 的还原路径做)。
static func restore_sub(sub: Vector2i, hp: int) -> void:
	if sub_cols == 0 or sub.x < 0 or sub.y < 0 or sub.x >= sub_cols or sub.y >= sub_rows:
		return
	sub_hp[sub.y * sub_cols + sub.x] = hp


# 对某格瓦片扣除生命值。source 为 "bullet"/"explosion",按对应可破坏开关判定。
# 扣到 ≤0 → 变空气(改 current_grid + 回调 Level0 刷新渲染/碰撞),返回是否破坏。
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
