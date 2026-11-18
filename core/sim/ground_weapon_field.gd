class_name GroundWeaponField
extends RefCounted

var items: Dictionary[int, WeaponPickup] = {}
var tick := 0
var _next_id := 1
var _terrain: Terrain

func _init(map: Terrain) -> void:
	_terrain = map

func spawn(type: int, carried: int, pos: Vector2, vel: Vector2, owner := 0) -> WeaponPickup:
	var item := WeaponPickup.new(_terrain, _next_id, type, carried, pos, vel)
	_next_id += 1
	if owner != 0:
		item.locked_role = owner
		item.unlock_tick = tick + ceili(PlayerParams.weapon_pickup_self_delay / ActorStep.DT)
	items[item.inst] = item
	return item

func step(delta: float) -> void:
	tick += 1
	for item: WeaponPickup in items.values():
		item.simulate_tick(delta)

func snapshot() -> Dictionary:
	var drops := {}
	for item: WeaponPickup in items.values():
		drops[item.inst] = [item.position, item.velocity, item.type_id, item.locked_role, item.unlock_tick]
	return drops

func clear() -> void:
	for item: WeaponPickup in items.values():
		item.release()
	items.clear()

static func available(player: Player, type: int, owner: int, unlock: int, now: int, distance_sq: float) -> bool:
	return distance_sq <= PlayerParams.weapon_pickup_radius ** 2 and (owner != player.role or now >= unlock) \
			and player.weapons.is_type_enabled(type)

func nearest(player: Player) -> WeaponPickup:
	var best: WeaponPickup
	var best_distance := INF
	for item: WeaponPickup in items.values():
		var offset := GridPathfinder.toroidal_delta_px(player.position, item.position, _terrain.map_size)
		var distance := offset.length_squared()
		if available(player, item.type_id, item.locked_role, item.unlock_tick, tick, distance) \
				and (best == null or distance < best_distance or (distance == best_distance and item.inst < best.inst)):
			best_distance = distance
			best = item
	return best

func handle_actions(player: Player, record: Array) -> void:
	var pressed: int = record[ActorInput.PRESSED]
	if pressed & ActorInput.BIT_PICKUP:
		var item := nearest(player)
		if item != null:
			var result := player.weapons.pick_up(item.type_id, item.carried)
			if result["ok"]:
				items.erase(item.inst)
				item.release()
				_drop(player, result["dropped"])
	if pressed & ActorInput.BIT_DROP:
		var inst: int = record[ActorInput.WINST]
		if inst > 0:
			player.weapons.equip_inst(inst)
			if player.weapons.current_inst() != inst:
				return
		_drop(player, player.weapons.drop_current())

func _drop(player: Player, item: Dictionary) -> void:
	if not item.is_empty():
		spawn(item["type"], item["carried"],
				player.position + PlayerParams.weapon_drop_offset * Vector2(player.facing_direction, 1),
				Vector2(PlayerParams.weapon_drop_speed * player.facing_direction, -PlayerParams.weapon_drop_up), player.role)

func scatter(floors: Array[Vector2i], types: Array[int]) -> void:
	var cells := GridPathfinder.spread_cells(floors, types.size() * 2, 10, _terrain.columns, _terrain.rows)
	for i in cells.size():
		var pickup := spawn(types[i / 2], WeaponInventory.DEFAULT_CARRIED, _terrain.cell_center(cells[i]), Vector2.ZERO)
		pickup.settle_on_spawn_floor()
