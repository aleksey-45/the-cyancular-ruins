class_name LevelPickups
extends RefCounted

# 单机地面武器场:GroundWeaponField(空间查询)+ WeaponPickup 节点表 + 自丢冷却。
# ★ 从 level_0.gd 拆出(2026-11-18):Level0 只保留对外的五个门面方法(spawn/remove/clear/scatter/try_pickup_for),
#   拾取表与节点生命周期在本类里。PvP 侧另有 scenes/mp_client/pickup_sync.gd(网络事件驱动),两者不共享状态。
# 依赖注入:容器节点(加 WeaponPickup)+ 敌人刷新器(取开阔地板格)。不反向引用 Level0。

const PICKUP_SCENE := preload("res://scenes/weapons/weapon_pickup.tscn")

var ground_weapons := GroundWeaponField.new()

var _container: Node = null
var _spawner: Node = null
var _next_inst: int = 1
var _nodes: Dictionary = {}
var _self_drop_until: Dictionary = {}


func setup(container: Node, spawner: Node) -> void:
	_container = container
	_spawner = spawner


func spawn(type_id: int, mag: int, pos: Vector2, vel: Vector2,
		inst: int = 0, self_drop: bool = false) -> WeaponPickup:
	if inst <= 0:
		inst = _next_inst
		_next_inst += 1
	else:
		_next_inst = maxi(_next_inst, inst + 1)
	var node: WeaponPickup = PICKUP_SCENE.instantiate()
	node.configure(type_id, inst, mag, vel)
	_container.add_child(node)
	node.global_position = pos
	node.canonical_pos = pos
	ground_weapons.map_size = Vector2(float(GameParameters.MAP_WIDTH), float(GameParameters.MAP_HEIGHT))
	ground_weapons.add({"inst": inst, "type_id": type_id, "mag": mag, "pos": pos, "vel": vel})
	_nodes[inst] = node
	if self_drop:
		_self_drop_until[inst] = Time.get_ticks_msec() + int(PlayerParams.weapon_pickup_self_delay * 1000.0)
	return node


func remove(inst: int) -> void:
	ground_weapons.remove(inst)
	_self_drop_until.erase(inst)
	var n = _nodes.get(inst, null)
	if n != null and is_instance_valid(n):
		n.queue_free()
	_nodes.erase(inst)


func clear() -> void:
	for n in _nodes.values():
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()
	_self_drop_until.clear()
	ground_weapons.clear()


# 开局散枪:clear + 在开阔地板格里均匀撒 types.size() 件。地图还没好时直接返回(调用方 deferred)。
func scatter(types: Array) -> void:
	clear()
	if MazeGenerator.current_grid.is_empty():
		return
	ground_weapons.map_size = Vector2(float(GameParameters.MAP_WIDTH), float(GameParameters.MAP_HEIGHT))
	var cols := int(ground_weapons.map_size.x / float(GameParameters.TILE_SIZE))
	var rows := int(ground_weapons.map_size.y / float(GameParameters.TILE_SIZE))
	var cells: Array = _spawner.open_floor_cells(MazeGenerator.current_grid)
	var want := types.size()
	var picked: Array = GridPathfinder.spread_cells(cells, want, 10, cols, rows)
	# 与 EnemySpawner 的 spawned N enemies from map 同款:布点数量要能一眼核对(不足时也走这行 —— 小图/密封图有多少铺多少,不报错也不卡住开局)。
	print("[Level0] 地面武器 %d/%d 件(开阔地板格 %d)" % [picked.size(), want, cells.size()])
	var half := float(GameParameters.TILE_SIZE) * 0.5
	for i in picked.size():
		var pos := Vector2(picked[i]) * float(GameParameters.TILE_SIZE) + Vector2(half, half)
		spawn(int(types[i]), WeaponInventory.MAG_FULL, pos, Vector2.ZERO)


func try_pickup_for(p: Node2D) -> void:
	if p == null or p.weapons == null:
		return
	var e: Dictionary = ground_weapons.nearest_within(
		p.global_position, PlayerParams.weapon_pickup_radius, live_self_drops())
	if e.is_empty():
		return
	var inst := int(e["inst"])
	var dropped_type: int = p.weapons.pick_up(int(e["type_id"]), int(e["mag"]))
	if dropped_type < 0:
		return
	remove(inst)
	if dropped_type > 0:
		var d: Dictionary = p.weapons.take_last_dropped()
		spawn(dropped_type, int(d.get("mag", WeaponInventory.MAG_FULL)),
			p.global_position + PlayerParams.weapon_drop_offset * Vector2(float(p.facing_direction), 1.0),
			Vector2(PlayerParams.weapon_drop_speed * p.facing_direction, -PlayerParams.weapon_drop_up))


func live_self_drops() -> Array:
	var now := Time.get_ticks_msec()
	var out: Array = []
	for inst in _self_drop_until.keys():
		if int(_self_drop_until[inst]) > now:
			out.append(inst)
		else:
			_self_drop_until.erase(inst)
	return out


func nodes() -> Dictionary:
	return _nodes


func entry(inst: int) -> Dictionary:
	return ground_weapons.get_entry(inst)
