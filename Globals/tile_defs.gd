class_name TileDefs
extends RefCounted

# 砖块属性表(Globals/tile_defs.json 单一来源)。level_0._ready 调用 load_defs() 后使用。
# 未加载时默认"非 0 即墙"(旧行为),保证早期调用/冒烟测试兼容。

const PATH: String = "res://Globals/tile_defs.json"
const MAX_TEXTURE: int = 22

static var _defs: Dictionary = {}
static var _loaded := false


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


static func friction() -> float:
	return float(_defs.get("friction", 1.0))


static func explosion_decay() -> float:
	return float(_defs.get("explosion_decay", 0.75))


# 逐格爆炸衰减(水 0.25);缺省回落全局 explosion_decay()。
static func explosion_decay_of(texture: int) -> float:
	return float(tile(texture).get("explosion_decay", explosion_decay()))


static func tile(texture: int) -> Dictionary:
	var tiles: Dictionary = _defs.get("tiles", {})
	return tiles.get(str(texture), {})


static func type_of(texture: int) -> String:
	return String(tile(texture).get("type", "wall"))


static func hp_of(texture: int) -> int:
	return int(tile(texture).get("hp", 1))


static func bullet_destroyable(texture: int) -> bool:
	return bool(tile(texture).get("bullet_destroyable", false))


static func explosion_destroyable(texture: int) -> bool:
	return bool(tile(texture).get("explosion_destroyable", false))


static func elastic(texture: int) -> bool:
	return bool(tile(texture).get("elastic", false))


static func climb_speed(texture: int) -> float:
	return float(tile(texture).get("climb_speed", 0.0))


# 攀爬下降速度倍率(梯子 2.0;锁链无此字段 → 0,玩家下降走自由落体)。
static func climb_descent_speed(texture: int) -> float:
	return float(tile(texture).get("climb_descent_speed", 0.0))


# packed 格值 → 是否挡路:非 0 且 type=wall。
static func is_blocked(v: int) -> bool:
	if v == 0:
		return false
	return type_of(v / 16) == "wall"


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
			r.append(hp_of(v / 16))
		hp_grid.append(r)


# 对某格瓦片扣血。source 为 "bullet"/"explosion",按对应可破坏开关判定。
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
	var tex: int = v / 16
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
