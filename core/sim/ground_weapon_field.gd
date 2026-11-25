class_name GroundWeaponField
extends RefCounted

const CFG: PlayerConfig = preload("res://core/config/player_config.tres")

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
		item.unlock_tick = tick + ceili(CFG.weapon_pickup_self_delay / ActorStep.DT)
	items[item.inst] = item
	return item

func step(delta: float) -> void:
	tick += 1
	for item: WeaponPickup in items.values():
		item.simulate_tick(delta)

func capture() -> Dictionary:
	var drops := {}
	for item: WeaponPickup in items.values():
		drops[item.inst] = item.capture()
	return drops

func restore(rows: Dictionary, at: int, next_id: int) -> void:
	for id: int in items.keys():
		if not rows.has(id) or rows[id][WeaponPickup.TYPE] != items[id].type_id:
			items[id].release()
			items.erase(id)
	var ids := rows.keys()
	ids.sort()
	for id: int in ids:
		var row: Array = rows[id]
		if not items.has(id):
			items[id] = WeaponPickup.new(_terrain, id, row[WeaponPickup.TYPE], row[WeaponPickup.AMMO],
					row[WeaponPickup.POS], row[WeaponPickup.VEL])
		items[id].restore(row)
	tick = at
	_next_id = next_id

func clear() -> void:
	for item: WeaponPickup in items.values():
		item.release()
	items.clear()

static func available(player: Player, type: int, owner: int, unlock: int, now: int, distance_sq: float) -> bool:
	return distance_sq <= CFG.weapon_pickup_radius ** 2 and (owner != player.role or now >= unlock) \
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
				player.position + CFG.weapon_drop_offset * Vector2(player.facing_direction, 1),
				Vector2(CFG.weapon_drop_speed * player.facing_direction, -CFG.weapon_drop_up), player.role)

func scatter(floors: Array[Vector2i], types: Array[int], rng: RandomNumberGenerator) -> void:
	var cells := GridPathfinder.spread_cells(floors, types.size() * 2, 40, _terrain.columns, _terrain.rows, rng)
	for i in cells.size():
		var pickup := spawn(types[i / 2], WeaponInventory.DEFAULT_CARRIED, _terrain.cell_center(cells[i]), Vector2.ZERO)
		pickup.settle_on_spawn_floor()
