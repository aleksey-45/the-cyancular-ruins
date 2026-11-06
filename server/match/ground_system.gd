class_name GroundSystem
extends RefCounted


static var test_ground_teleport := false

var _state: MatchState = null
var _ports: MatchPorts = null

var ground_weapons := GroundWeaponField.new()
var _next_ground_inst := 1
var _ground_nodes: Dictionary = {}
var _self_drop_until: Dictionary = {}
var _settled_seen: Dictionary = {}
const PICKUP_INTENT_S := 0.4
var _pickup_intent: Dictionary = {}


func bind(state: MatchState, ports: MatchPorts) -> void:
	_state = state
	_ports = ports


# 本局投放的武器类型清单:每种 2 把、跳过被禁的(与单机同源,差别只在禁用表)。
func _server_weapon_types() -> Array:
	var out: Array = []
	for type_id in WeaponRegistry.all_ids():
		if not _state._disabled_weapons.has(type_id):
			out.append(type_id)
			out.append(type_id)
	return out


func _grid_dims_cells() -> Vector2i:
	return Vector2i(
			maxi(1, int(GameParameters.MAP_WIDTH / GameParameters.TILE_SIZE)),
			maxi(1, int(GameParameters.MAP_HEIGHT / GameParameters.TILE_SIZE)))


func _spawn_ground_weapon(type_id: int, mag: int, pos: Vector2, vel: Vector2,
		inst: int = 0, self_role: int = -1) -> int:
	if inst <= 0:
		inst = _next_ground_inst
		_next_ground_inst += 1
	else:
		_next_ground_inst = maxi(_next_ground_inst, inst + 1)
	var node: WeaponPickup = preload("res://scenes/weapons/weapon_pickup.tscn").instantiate()
	node.configure(type_id, inst, mag, vel)
	_ports.scene_add_child.call(node)
	node.global_position = pos
	node.canonical_pos = pos
	ground_weapons.map_size = Vector2(float(GameParameters.MAP_WIDTH), float(GameParameters.MAP_HEIGHT))
	ground_weapons.add({"inst": inst, "type_id": type_id, "mag": mag, "pos": pos, "vel": vel})
	_ground_nodes[inst] = node
	if self_role >= 0:
		if not _self_drop_until.has(self_role):
			_self_drop_until[self_role] = {}
		(_self_drop_until[self_role] as Dictionary)[inst] = \
			Time.get_ticks_msec() + int(PlayerParams.weapon_pickup_self_delay * 1000.0)
	return inst


func _remove_ground_weapon(inst: int) -> void:
	ground_weapons.remove(inst)
	var n = _ground_nodes.get(inst, null)
	if n != null and is_instance_valid(n):
		n.queue_free()
	_ground_nodes.erase(inst)
	_settled_seen.erase(inst)
	for role in _self_drop_until:
		(_self_drop_until[role] as Dictionary).erase(inst)


func sync_positions() -> void:
	for inst in _ground_nodes:
		var n = _ground_nodes[inst]
		if n != null and is_instance_valid(n):
			var pk := n as WeaponPickup
			var e: Dictionary = ground_weapons.get_entry(int(inst))
			if not e.is_empty():
				e["pos"] = pk.canonical_pos
			if pk._settled and not bool(_settled_seen.get(int(inst), false)):
				_broadcast_weapon_spawned(int(inst), -1, true)
			_settled_seen[int(inst)] = pk._settled
	_tick_pickup_intents()


func debug_keep_weapon_within_reach() -> void:
	if not test_ground_teleport or ground_weapons.entries.is_empty():
		return
	for role in _state.players:
		var p: Node2D = _state.players[role]
		if p == null or p.is_downed():
			continue
		var blocked: Array = _live_self_drops(role)
		if not ground_weapons.nearest_within(
				p.global_position, PlayerParams.weapon_pickup_radius, blocked).is_empty():
			continue
		var near: Dictionary = ground_weapons.nearest_within(p.global_position, 1e9, blocked)
		if near.is_empty():
			continue
		var n = _ground_nodes.get(int(near["inst"]), null)
		if n == null or not is_instance_valid(n):
			continue
		var pk := n as WeaponPickup
		pk.canonical_pos = p.global_position
		pk.global_position = pk.canonical_pos
		pk.velocity = Vector2.ZERO
		pk._settled = true
		near["pos"] = pk.canonical_pos


func _canonical_of(inst: int) -> Vector2:
	var n = _ground_nodes.get(inst, null)
	if n != null and is_instance_valid(n):
		return (n as WeaponPickup).canonical_pos
	var e: Dictionary = ground_weapons.get_entry(inst)
	push_warning("GroundSystem._canonical_of: inst %d 没有活节点,退回表里的 pos(可能与实际落点不符)" % inst)
	return e.get("pos", Vector2.ZERO)


func payload() -> Array:
	var out: Array = []
	for e in ground_weapons.entries:
		var d: Dictionary = e.duplicate(true)
		var inst := int(e["inst"])
		d["pos"] = _canonical_of(inst)
		d["vel"] = _live_velocity_of(inst)
		out.append(d)
	return out


func _live_velocity_of(inst: int) -> Vector2:
	var n = _ground_nodes.get(inst, null)
	if n != null and is_instance_valid(n):
		return (n as WeaponPickup).velocity
	var e: Dictionary = ground_weapons.get_entry(inst)
	return e.get("vel", Vector2.ZERO)


func _broadcast_weapon_spawned(inst: int, by_role: int = -1, settled: bool = false) -> void:
	var e: Dictionary = ground_weapons.get_entry(inst)
	if e.is_empty():
		return
	var vel: Vector2 = Vector2.ZERO if settled else (e["vel"] as Vector2)
	var data := {"inst": inst, "type_id": int(e["type_id"]),
			"mag": int(e["mag"]), "pos": _canonical_of(inst), "vel": vel, "by_role": by_role}
	if settled:
		data["settled"] = true
	_ports.net_rpc_role_all.call("weapon_spawned", [data])


func _broadcast_weapon_removed(inst: int, by_role: int) -> void:
	_ports.net_rpc_role_all.call("weapon_removed", [{"inst": inst, "by_role": by_role}])


func _live_self_drops(role: int) -> Array:
	var out: Array = []
	if not _self_drop_until.has(role):
		return out
	var now := Time.get_ticks_msec()
	var m: Dictionary = _self_drop_until[role]
	for inst in m.keys():
		if int(m[inst]) > now:
			out.append(inst)
		else:
			m.erase(inst)
	return out


func handle_actions(role: int, src: PacketInputSource) -> void:
	if not _state.players.has(role):
		return
	var p: Node2D = _state.players[role]
	if p.is_downed():
		return
	if src.is_pickup_pressed():
		_pickup_intent[int(role)] = Time.get_ticks_msec() + int(PICKUP_INTENT_S * 1000.0)
		if _try_server_pickup(p, role):
			_pickup_intent.erase(int(role))
	if src.is_drop_pressed():
		_try_server_drop(p, role)


func _tick_pickup_intents() -> void:
	if _pickup_intent.is_empty():
		return
	var now := Time.get_ticks_msec()
	for r in _pickup_intent.keys():
		var role := int(r)
		if int(_pickup_intent[r]) <= now:
			_pickup_intent.erase(r)
			continue
		var p: Node2D = _state.players.get(role, null)
		if p == null or p.is_downed():
			_pickup_intent.erase(r)
			continue
		if _try_server_pickup(p, role, false):
			_pickup_intent.erase(r)


func _try_server_pickup(p: Node2D, role: int, log_miss: bool = true) -> bool:
	var e: Dictionary = ground_weapons.nearest_within(
			p.global_position, PlayerParams.weapon_pickup_radius, _live_self_drops(role))
	if e.is_empty():
		if log_miss and NetDiag.enabled():
			var any: Dictionary = ground_weapons.nearest_within(p.global_position, 1e9, _live_self_drops(role))
			if any.is_empty():
				NetDiag.log_event("pickup_try", {"role": role, "result": "none"})
			else:
				var dist := GridPathfinder.toroidal_delta_px(any["pos"], p.global_position,
						float(GameParameters.MAP_WIDTH), float(GameParameters.MAP_HEIGHT)).length()
				NetDiag.log_event("pickup_try", {"role": role, "result": "range",
						"dist": snappedf(dist, 0.1), "radius": PlayerParams.weapon_pickup_radius,
						"type": int(any.get("type_id", 0))})
		return false
	var inst := int(e["inst"])
	var dropped: int = p.weapons.pick_up(int(e["type_id"]), int(e["mag"]))
	if dropped < 0:
		NetDiag.log_event("pickup_try", {"role": role, "result": "denied",
				"type": int(e["type_id"]), "inst": inst})
		return true
	NetDiag.log_event("pickup_try", {"role": role, "result": "taken", "type": int(e["type_id"]),
			"inst": inst, "replaced": dropped})
	_remove_ground_weapon(inst)
	_broadcast_weapon_removed(inst, role)
	if dropped > 0:
		var d: Dictionary = p.weapons.take_last_dropped()
		var ni := _spawn_ground_weapon(dropped, int(d.get("mag", WeaponInventory.MAG_FULL)),
				p.global_position + PlayerParams.weapon_drop_offset * Vector2(float(p.facing_direction), 1.0),
				Vector2(PlayerParams.weapon_drop_speed * p.facing_direction, -PlayerParams.weapon_drop_up),
				0, role)
		_broadcast_weapon_spawned(ni, role)
	return true


func _try_server_drop(p: Node2D, role: int) -> void:
	if p.weapons.current_type_id() == 0:
		return
	var e: Dictionary = p.weapons.drop_current()
	if e.is_empty():
		return
	var ni := _spawn_ground_weapon(int(e["type"]), int(e["mag"]),
			p.global_position + PlayerParams.weapon_drop_offset * Vector2(float(p.facing_direction), 1.0),
			Vector2(PlayerParams.weapon_drop_speed * p.facing_direction, -PlayerParams.weapon_drop_up),
			0, role)
	_broadcast_weapon_spawned(ni, role)


func drop_all_but_one(p: Node2D, role: int) -> void:
	if p.weapons == null:
		return
	var rest: Array = p.weapons.random_keep_one()
	if rest.is_empty():
		return
	var pos := p.global_position
	var n := maxi(rest.size(), 1)
	for i in rest.size():
		var e: Dictionary = rest[i]
		var ang := TAU * float(i) / float(n)
		var vel := Vector2(cos(ang), -absf(sin(ang))) * 380.0
		var inst := _spawn_ground_weapon(int(e["type"]), int(e.get("mag", WeaponInventory.MAG_FULL)),
				pos + Vector2(0.0, -12.0), vel, 0, role)
		_broadcast_weapon_spawned(inst, role)


func _ground_spawn_cells() -> Array:
	var out: Array = []
	var grid: Array = _state.grid
	if grid.is_empty():
		return out
	var rows := grid.size()
	var cols := (grid[0] as Array).size()
	for y in rows:
		for x in cols:
			var c := Vector2i(x, y)
			if MazeGenerator.is_floor_cell_with_headroom(grid, c):
				out.append(c)
	return out


func _scatter_ground_weapons(types: Array) -> void:
	ground_weapons.map_size = Vector2(float(GameParameters.MAP_WIDTH), float(GameParameters.MAP_HEIGHT))
	var d := _grid_dims_cells()
	var cells: Array = _ground_spawn_cells()
	var picked: Array = GridPathfinder.spread_cells(cells, types.size(), 10, d.x, d.y)
	if picked.size() < types.size():
		print("[GroundSystem] 地面武器:只铺得下 %d/%d 件(开阔地板格不足)" % [picked.size(), types.size()])
	var ts := float(GameParameters.TILE_SIZE)
	var half := ts * 0.5
	for i in picked.size():
		var pos := Vector2(picked[i]) * ts + Vector2(half, half)
		_spawn_ground_weapon(int(types[i]), WeaponInventory.MAG_FULL, pos, Vector2.ZERO)


func setup() -> void:
	_scatter_ground_weapons(_server_weapon_types())
	for role in _state.players:
		var p: Node = _state.players[role]
		if p.weapons == null:
			continue
		var t := 1
		if not ground_weapons.entries.is_empty():
			var idx := randi() % ground_weapons.entries.size()
			var e: Dictionary = ground_weapons.remove(int(ground_weapons.entries[idx]["inst"]))
			_remove_ground_weapon(int(e["inst"]))
			t = int(e["type_id"])
		p.weapons.set_initial_inventory([t])


func reset() -> void:
	var cleared: Array = _ground_nodes.keys().duplicate()
	for inst in cleared:
		var n = _ground_nodes[inst]
		if n != null and is_instance_valid(n):
			n.queue_free()
	_ground_nodes.clear()
	_self_drop_until.clear()
	ground_weapons.clear()
	setup()
	for inst in cleared:
		_broadcast_weapon_removed(int(inst), -1)
	for e in ground_weapons.entries:
		_broadcast_weapon_spawned(int(e["inst"]), -1)
