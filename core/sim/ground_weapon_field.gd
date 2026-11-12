class_name GroundWeaponField
extends RefCounted

## 两种权威模式都以掉落物的规范位置选最近的可拾取物品。同距取较小的实例 ID。
static func nearest(pickups: Array, origin: Vector2, size: Vector2, available: Callable) -> WeaponPickup:
	var best: WeaponPickup
	var radius := PlayerParams.weapon_pickup_radius
	var best_distance := radius
	for item: WeaponPickup in pickups:
		if not available.call(item):
			continue
		var distance := GridPathfinder.toroidal_delta_px(origin, item.canonical_pos, size).length()
		if distance > radius:
			continue
		if best == null or distance < best_distance or (distance == best_distance and item.inst < best.inst):
			best_distance = distance
			best = item
	return best

static func pick_up(pickups: Dictionary, player: Player, size: Vector2, unlocked: Callable, spawn: Callable) -> void:
	var item := nearest(pickups.values(), player.global_position, size, func(candidate: WeaponPickup) -> bool:
		return unlocked.call(candidate) and player.weapons.is_type_enabled(candidate.type_id))
	if item == null:
		return
	var result := player.weapons.pick_up(item.type_id, item.carried)
	if result["ok"]:
		pickups.erase(item.inst)
		item.queue_free()
		drop(player, result["dropped"], spawn)

static func drop(player: Player, item: Dictionary, spawn: Callable) -> void:
	if not item.is_empty():
		spawn.call(item["type"], item["carried"],
				player.global_position + PlayerParams.weapon_drop_offset * Vector2(player.facing_direction, 1),
				Vector2(PlayerParams.weapon_drop_speed * player.facing_direction, -PlayerParams.weapon_drop_up))

static func scatter(terrain: Terrain, floors: Array[Vector2i], types: Array[int], spawn: Callable) -> void:
	var cells := GridPathfinder.spread_cells(floors, types.size() * 2, 10, terrain.columns, terrain.rows)
	for i in cells.size():
		var pickup: WeaponPickup = spawn.call(types[i / 2], WeaponInventory.DEFAULT_CARRIED,
				terrain.cell_center(cells[i]), Vector2.ZERO)
		pickup.settle_on_spawn_floor()
