class_name GroundWeaponField
extends RefCounted


var items := {}
var _next_id := 1
var _parent: Node
var _time_field: TimeField

func _init(parent: Node, time_field: TimeField = null) -> void:
	_parent = parent
	_time_field = time_field

func spawn(type_id: int, carried: int, pos: Vector2, vel: Vector2) -> WeaponPickup:
	var item: WeaponPickup = preload("res://scenes/weapons/weapon_pickup.tscn").instantiate()
	item.configure(type_id, _next_id, carried, vel)
	_next_id += 1
	item.position = pos
	item.canonical_pos = pos
	_parent.add_child(item)
	items[item.inst] = item
	return item

func spawn_locked(type_id: int, carried: int, pos: Vector2, vel: Vector2, role: int, tick: int) -> void:
	var item := spawn(type_id, carried, pos, vel)
	item.locked_role = role
	var delay := PlayerParams.weapon_pickup_self_delay
	item.unlock_at = tick + ceili(delay * 60) if _time_field == null else Time.get_ticks_msec() + int(delay * 1000)

static func can_pick_up(player: Player, type_id: int, locked_role: int, unlock_at: int, now: int) -> bool:
	return (locked_role != player.role or now >= unlock_at) and player.weapons.is_type_enabled(type_id)

static func in_pickup_range(distance: float) -> bool:
	return distance <= PlayerParams.weapon_pickup_radius

func handle_actions(player: Player, record: Array, tick := 0) -> void:
	var pressed: int = record[ActorInput.PRESSED]
	if (pressed & (ActorInput.BIT_PICKUP | ActorInput.BIT_DROP)) == 0:
		return
	var solo := _time_field != null
	var drop_weapon := pressed & ActorInput.BIT_DROP
	var spawn_drop := spawn_locked.bind(player.role, tick)
	# 单人先丢再捡，多人先拾取并校验丢弃请求中的武器实例。
	if solo and drop_weapon:
		_drop(player, player.weapons.drop_current(), spawn_drop)
	if pressed & ActorInput.BIT_PICKUP:
		var now := Time.get_ticks_msec() if solo else tick
		_pick_up(player, now, spawn if solo else spawn_drop)
	if not solo and drop_weapon:
		var weapon: int = record[ActorInput.WINST]
		if weapon > 0:
			player.weapons.equip_inst(weapon)
			if player.weapons.current_inst() != weapon:
				return
		_drop(player, player.weapons.drop_current(), spawn_drop)

func clear() -> void:
	for item: WeaponPickup in items.values():
		item.queue_free()
	items.clear()

## 两种权威模式都以掉落物的规范位置选最近的可拾取物品。同距取较小的实例 ID。
static func nearest(pickups: Array, origin: Vector2, size: Vector2, available: Callable) -> WeaponPickup:
	var best: WeaponPickup
	var best_distance := INF
	for item: WeaponPickup in pickups:
		if not available.call(item):
			continue
		var distance := GridPathfinder.toroidal_delta_px(origin, item.canonical_pos, size).length()
		if not in_pickup_range(distance):
			continue
		if best == null or distance < best_distance or (distance == best_distance and item.inst < best.inst):
			best_distance = distance
			best = item
	return best

func _pick_up(player: Player, now: int, spawn_drop: Callable) -> void:
	var item := nearest(items.values(), player.global_position, player.terrain.map_size, func(pickup: WeaponPickup) -> bool:
		return can_pick_up(player, pickup.type_id, pickup.locked_role, pickup.unlock_at, now))
	if item == null:
		return
	var result := player.weapons.pick_up(item.type_id, item.carried)
	if result["ok"]:
		items.erase(item.inst)
		item.queue_free()
		_drop(player, result["dropped"], spawn_drop)

static func _drop(player: Player, item: Dictionary, spawn: Callable) -> void:
	if not item.is_empty():
		spawn.call(item["type"], item["carried"],
				player.global_position + PlayerParams.weapon_drop_offset * Vector2(player.facing_direction, 1),
				Vector2(PlayerParams.weapon_drop_speed * player.facing_direction, -PlayerParams.weapon_drop_up))

func scatter(terrain: Terrain, floors: Array[Vector2i], types: Array[int]) -> void:
	var cells := GridPathfinder.spread_cells(floors, types.size() * 2, 10, terrain.columns, terrain.rows)
	for i in cells.size():
		var pickup := spawn(types[i / 2], WeaponInventory.DEFAULT_CARRIED,
				terrain.cell_center(cells[i]), Vector2.ZERO)
		pickup.settle_on_spawn_floor()
