class_name MatchGround
extends MatchState

# 地面武器域（服务端权威管理）：
# 维护地面武器列表、处理拾取与丢弃判定、广播相关网络事件，并负责开局生成与换局重置。
# 服务端真实实例化 WeaponPickup 物理实体以模拟重力下落，保证两端落点完全一致。

# 自动化测试开关：将地面武器移至玩家脚下，便于测试拾取与丢弃逻辑。默认关闭。
static var test_ground_teleport := false

var ground_weapons := GroundWeaponField.new()
var _next_ground_inst := 1
var _ground_nodes: Dictionary = {}     # 实例 ID -> WeaponPickup 实体节点
var _self_drop_until: Dictionary = {}  # 角色编号 -> {实例 ID: 冷却结束时间戳}，防止丢弃后立即误拾取


# 获取本局投放的武器类型列表（每种类型生成 2 把，跳过被禁用的武器）
func _server_weapon_types() -> Array:
	var out: Array = []
	for type_id in WeaponRegistry.all_ids():
		if not _disabled_weapons.has(type_id):
			out.append(type_id)
			out.append(type_id)
	return out


func _grid_dims_cells() -> Vector2i:
	return Vector2i(
			maxi(1, int(GameParameters.MAP_WIDTH / GameParameters.TILE_SIZE)),
			maxi(1, int(GameParameters.MAP_HEIGHT / GameParameters.TILE_SIZE)))


# 在指定位置生成一件地面武器实体（服务端权威创建），返回武器实例 ID。
# self_role 为丢弃该武器的角色编号，用于设置防误拾取冷却。
func _spawn_ground_weapon(type_id: int, mag: int, pos: Vector2, vel: Vector2,
		inst: int = 0, self_role: int = -1) -> int:
	if inst <= 0:
		inst = _next_ground_inst
		_next_ground_inst += 1
	else:
		_next_ground_inst = maxi(_next_ground_inst, inst + 1)
	var node: WeaponPickup = preload("res://scenes/weapons/weapon_pickup.tscn").instantiate()
	node.configure(type_id, inst, mag, vel)
	add_child(node)
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
	for role in _self_drop_until:
		(_self_drop_until[role] as Dictionary).erase(inst)


# 每物理帧将实体落地的实际坐标同步回地面武器状态表，确保拾取判定使用最新位置
func _sync_ground_positions() -> void:
	for inst in _ground_nodes:
		var n = _ground_nodes[inst]
		if n != null and is_instance_valid(n):
			var e: Dictionary = ground_weapons.get_entry(int(inst))
			if not e.is_empty():
				e["pos"] = (n as WeaponPickup).canonical_pos


# 仅用于自动化测试：为站立且脚下无武器的角色就近移动一把可用武器
func _debug_keep_weapon_within_reach() -> void:
	if not test_ground_teleport or ground_weapons.entries.is_empty():
		return
	for role in players:
		var p: Node2D = players[role]
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


# 获取指定地面武器实例的规范化权威位置坐标（区间 [0, MAP_WIDTH) 与 [0, MAP_HEIGHT)）
func _canonical_of(inst: int) -> Vector2:
	var n = _ground_nodes.get(inst, null)
	if n != null and is_instance_valid(n):
		return (n as WeaponPickup).canonical_pos
	var e: Dictionary = ground_weapons.get_entry(inst)
	push_warning("MatchGround._canonical_of: inst %d 没有活节点,退回表里的 pos" % inst)
	return e.get("pos", Vector2.ZERO)


# 构造地面武器状态同步负载，供客户端进场同步与断线重连拉取使用
func ground_weapons_payload() -> Array:
	var out: Array = []
	for e in ground_weapons.entries:
		var d: Dictionary = e.duplicate(true)
		var inst := int(e["inst"])
		d["pos"] = _canonical_of(inst)
		d["vel"] = _live_velocity_of(inst)
		out.append(d)
	return out


# 获取地面武器当前实际的物理运动速度
func _live_velocity_of(inst: int) -> Vector2:
	var n = _ground_nodes.get(inst, null)
	if n != null and is_instance_valid(n):
		return (n as WeaponPickup).velocity
	var e: Dictionary = ground_weapons.get_entry(inst)
	return e.get("vel", Vector2.ZERO)


# 广播地面武器生成事件。by_role 表示丢弃该武器的角色编号（-1 表示场景初始生成）
func _broadcast_weapon_spawned(inst: int, by_role: int = -1) -> void:
	var e: Dictionary = ground_weapons.get_entry(inst)
	if e.is_empty():
		return
	_rpc_all("weapon_spawned", [{"inst": inst, "type_id": int(e["type_id"]),
			"mag": int(e["mag"]), "pos": _canonical_of(inst), "vel": e["vel"], "by_role": by_role}])


func _broadcast_weapon_removed(inst: int, by_role: int) -> void:
	_rpc_all("weapon_removed", [{"inst": inst, "by_role": by_role}])


# 获取指定角色处于防误拾取冷却期内的武器实例 ID 列表
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


# 消费输入包后处理角色的拾取与丢弃交互
func _handle_ground_actions(role: int, src: PacketInputSource) -> void:
	if not players.has(role):
		return
	var p: Node2D = players[role]
	if p.is_downed():
		return
	if src.is_pickup_pressed():
		_try_server_pickup(p, role)
	if src.is_drop_pressed():
		_try_server_drop(p, role)


# 拾取判定：选取拾取半径内最近且未处于冷却期的武器，由服务端权威仲裁
func _try_server_pickup(p: Node2D, role: int) -> void:
	var e: Dictionary = ground_weapons.nearest_within(
			p.global_position, PlayerParams.weapon_pickup_radius, _live_self_drops(role))
	if e.is_empty():
		return
	var inst := int(e["inst"])
	var dropped: int = p.weapons.pick_up(int(e["type_id"]), int(e["mag"]))
	if dropped < 0:
		return
	_remove_ground_weapon(inst)
	_broadcast_weapon_removed(inst, role)
	if dropped > 0:
		# 背包已满时换下的武器掉落在玩家当前位置
		var d: Dictionary = p.weapons.take_last_dropped()
		var ni := _spawn_ground_weapon(dropped, int(d.get("mag", WeaponInventory.MAG_FULL)),
				p.global_position + PlayerParams.weapon_drop_offset * Vector2(float(p.facing_direction), 1.0),
				Vector2(PlayerParams.weapon_drop_speed * p.facing_direction, -PlayerParams.weapon_drop_up),
				0, role)
		_broadcast_weapon_spawned(ni, role)


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


# 角色倒地时触发武器掉落：背包随机保留一把武器，其余全部在当前坐标散落掉出
func _drop_all_but_one(p: Node2D, role: int) -> void:
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


# ── 地面武器初始生成与换局重置 ──

# 获取地图中所有具备站立空间的地板瓦片坐标列表
func _ground_spawn_cells() -> Array:
	var out: Array = []
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


# 将各武器类型分散放置在地图中的开阔地面瓦片上
func _scatter_ground_weapons(types: Array) -> void:
	ground_weapons.map_size = Vector2(float(GameParameters.MAP_WIDTH), float(GameParameters.MAP_HEIGHT))
	var d := _grid_dims_cells()
	var cells: Array = _ground_spawn_cells()
	var picked: Array = GridPathfinder.spread_cells(cells, types.size(), 10, d.x, d.y)
	if picked.size() < types.size():
		print("[MatchGround] 地面武器:只铺得下 %d/%d 件(开阔地板格不足)" % [picked.size(), types.size()])
	var ts := float(GameParameters.TILE_SIZE)
	var half := ts * 0.5
	for i in picked.size():
		var pos := Vector2(picked[i]) * ts + Vector2(half, half)
		_spawn_ground_weapon(int(types[i]), WeaponInventory.MAG_FULL, pos, Vector2.ZERO)


# 开局初始化：生成初始地面武器并为每位玩家随机分配一把初始武器
func _setup_ground_weapons() -> void:
	_scatter_ground_weapons(_server_weapon_types())
	for role in players:
		var p: Node = players[role]
		if p.weapons == null:
			continue
		var t := 1
		if not ground_weapons.entries.is_empty():
			var idx := randi() % ground_weapons.entries.size()
			var e: Dictionary = ground_weapons.remove(int(ground_weapons.entries[idx]["inst"]))
			_remove_ground_weapon(int(e["inst"]))
			t = int(e["type_id"])
		p.weapons.set_initial_inventory([t])


# 换局重置：清理场上地面武器、重新随机分布，并向客户端同步更新
func _reset_ground_weapons() -> void:
	var cleared: Array = _ground_nodes.keys().duplicate()
	for inst in cleared:
		var n = _ground_nodes[inst]
		if n != null and is_instance_valid(n):
			n.queue_free()
	_ground_nodes.clear()
	_self_drop_until.clear()
	ground_weapons.clear()
	_setup_ground_weapons()
	for inst in cleared:
		_broadcast_weapon_removed(int(inst), -1)
	for e in ground_weapons.entries:
		_broadcast_weapon_spawned(int(e["inst"]), -1)

