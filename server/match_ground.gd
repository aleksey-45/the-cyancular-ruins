class_name MatchGround
extends MatchState

# 地面武器域(服务器权威):表 + 拾取/丢弃裁决 + 事件广播 + 初始分布/换局重置。
#
# ★ 本文件是继承链的**中间层**(…→ MatchSnapshot → MatchGround → MatchState)。
#   按 match_state.gd 的规矩**不得定义** _init/_ready/_enter_tree/_exit_tree/_physics_process ——
#   编排仍由 MatchHost._physics_process 每帧显式调用下面的函数。
#
# ★ 为什么服务器要**真的实例化 WeaponPickup**:落体决定最终落点,而落点直接决定
#   "够不够得着"。纯逻辑表只存位置、不会算落体;复用 WeaponPickup 的物理就两端同源
#   (这也是单机侧那条"落点与何时开始模拟无关"的不变量在联机端成立的前提)。
#   代价是 headless 服务器上多 12 个(带哑视觉的)节点 —— 可忽略,真要省再说。

var ground_weapons := GroundWeaponField.new()
var _next_ground_inst := 1
var _ground_nodes: Dictionary = {}     # inst -> WeaponPickup(服务器侧;headless 不渲染)
var _self_drop_until: Dictionary = {}  # role -> {inst: 解禁时刻(ms)},防"丢完立刻捡回"


# 本局投放的武器类型清单:每种 2 把,跳过被禁的槽位。
func _server_weapon_types() -> Array:
	var out: Array = []
	for slot in [1, 2, 3, 4, 5, 6]:
		if not _disabled_weapons.has(slot):
			out.append(slot)
			out.append(slot)
	return out


func _grid_dims_cells() -> Vector2i:
	return Vector2i(
			maxi(1, int(GameParameters.MAP_WIDTH / GameParameters.TILE_SIZE)),
			maxi(1, int(GameParameters.MAP_HEIGHT / GameParameters.TILE_SIZE)))


# 生成一件地面武器(服务器侧权威)。返回 inst。
# self_role >= 0 表示"这把是该 role 刚丢下的" → 冷却期内不参与他自己的拾取判定。
func _spawn_ground_weapon(type_id: int, mag: int, pos: Vector2, vel: Vector2,
		inst: int = 0, self_role: int = -1) -> int:
	if inst <= 0:
		inst = _next_ground_inst
		_next_ground_inst += 1
	else:
		_next_ground_inst = maxi(_next_ground_inst, inst + 1)
	var node: WeaponPickup = preload("res://scenes/weapons/weapon_pickup.tscn").instantiate()
	node.configure(type_id, inst, mag, vel)   # ★ 必须在 add_child 之前(见 WeaponPickup 的注释)
	add_child(node)   # 与 WorldBuilder.build_sim 的碰撞体同级 → 落体才撞得到地形
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


# 服务器每帧把落体的**实际**位置同步回表:落点由 WeaponPickup 的物理决定,
# 而拾取判定(nearest_within)读的是表里的 pos。
func _sync_ground_positions() -> void:
	for inst in _ground_nodes:
		var n = _ground_nodes[inst]
		if n != null and is_instance_valid(n):
			var e: Dictionary = ground_weapons.get_entry(int(inst))
			if not e.is_empty():
				e["pos"] = (n as Node2D).canonical_pos


# 给 match_sync_data 的载荷(客户端进场拉取时一并拿到开局那批)。
func ground_weapons_payload() -> Array:
	return ground_weapons.entries.duplicate(true)


# by_role = 这把是**谁刚丢下的**(-1 = 开局铺的/无主)。客户端靠它排除"自己刚丢的那把"
# —— 那条 0.5s 拾取冷却只有服务器知道,不告诉客户端的话,刚丢下的枪会**短暂显示 F
# 却捡不起来**(提示与判定不一致)。
func _broadcast_weapon_spawned(inst: int, by_role: int = -1) -> void:
	var e: Dictionary = ground_weapons.get_entry(inst)
	if e.is_empty():
		return
	_rpc_all("weapon_spawned", [{"inst": inst, "type_id": int(e["type_id"]),
			"mag": int(e["mag"]), "pos": e["pos"], "vel": e["vel"], "by_role": by_role}])


func _broadcast_weapon_removed(inst: int, by_role: int) -> void:
	_rpc_all("weapon_removed", [{"inst": inst, "by_role": by_role}])


# 该 role 在冷却期内、不该被他自己捡回的 inst 列表。
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


# 拾取/丢弃:由 MatchHost 在**消费输入包之后**调用(边沿刚写进 PacketInputSource)。
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


# 拾取:一次只捡**最近的一把**(与单机同规则)。服务器裁决 —— 两人抢同一把时,
# 谁先被消费到这里谁得,输的一方客户端从未预测过,所以不需要回滚。
func _try_server_pickup(p: Node2D, role: int) -> void:
	var e: Dictionary = ground_weapons.nearest_within(
			p.global_position, PlayerParams.weapon_pickup_radius, _live_self_drops(role))
	if e.is_empty():
		return
	var inst := int(e["inst"])
	var dropped: int = p.weapons.pick_up(int(e["type_id"]), int(e["mag"]))
	if dropped < 0:
		return   # 被禁用闸门拒绝:地面那件留着(与单机同款哨兵,见 WeaponComponent.PICKUP_DENIED)
	_remove_ground_weapon(inst)
	_broadcast_weapon_removed(inst, role)
	if dropped > 0:
		# 放不下 → 被换下的那把掉在玩家脚下(残弹跟着枪走)
		var d: Dictionary = p.weapons.take_last_dropped()
		var ni := _spawn_ground_weapon(dropped, int(d.get("mag", WeaponInventory.MAG_FULL)),
				p.global_position + PlayerParams.weapon_drop_offset * Vector2(float(p.facing_direction), 1.0),
				Vector2(PlayerParams.weapon_drop_speed * p.facing_direction, -PlayerParams.weapon_drop_up),
				0, role)
		_broadcast_weapon_spawned(ni, role)


func _try_server_drop(p: Node2D, role: int) -> void:
	if p.weapons.current_slot_int() == 0:
		return   # 空手没什么可丢
	var e: Dictionary = p.weapons.drop_current()
	if e.is_empty():
		return
	var ni := _spawn_ground_weapon(int(e["type"]), int(e["mag"]),
			p.global_position + PlayerParams.weapon_drop_offset * Vector2(float(p.facing_direction), 1.0),
			Vector2(PlayerParams.weapon_drop_speed * p.facing_direction, -PlayerParams.weapon_drop_up),
			0, role)
	_broadcast_weapon_spawned(ni, role)


# 复活:从背包**随机**保留一条,其余在死亡点散开掉出(用户 2026-09-15 裁定)。
# ★ 不补满弹:与"残弹跟着枪走"一致,也与改动前(服务器复活只 equip)一致。
func _drop_all_but_one(p: Node2D, role: int) -> void:
	if p.weapons == null:
		return
	var rest: Array = p.weapons.random_keep_one()   # 内部已 equip 保留的那把
	if rest.is_empty():
		return
	var pos := p.global_position
	var n := maxi(rest.size(), 1)
	for i in rest.size():
		var e: Dictionary = rest[i]
		# 各方向散开(向上偏),免得全叠在一个点上
		var ang := TAU * float(i) / float(n)
		var vel := Vector2(cos(ang), -absf(sin(ang))) * 380.0
		var inst := _spawn_ground_weapon(int(e["type"]), int(e.get("mag", WeaponInventory.MAG_FULL)),
				pos + Vector2(0.0, -12.0), vel, 0, role)
		_broadcast_weapon_spawned(inst, role)


# ── 初始分布 / 换局重置 ──

# 开阔地板格(1v1 的判据)。★ RoyaleHost 覆写成自己的 `_spawn_candidates()`
# (那边还要求同层连通区 ≥ OPEN_AREA_MIN,淘汰密封死角)。判据本体仍是
# `MazeGenerator.is_floor_cell_with_headroom`,别在这儿抄第二份。
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


# 把 types 里每种武器铺到全图开阔地板格(尽量互相远离)。
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


# 开局:铺 12 把(每种 2 把、跳过禁用),再让每个玩家(含 AI 补位)从池子里随机拿 1 把
# → 地上剩 12 - N 把。
# ★ 这同时是"服务器玩家**必须有枪**"的唯一来源:player.tscn 自身的 _ready 给的是空背包,
#   不发的话服务器上的玩家开不了火(PvP 直接哑火)。
func _setup_ground_weapons() -> void:
	_scatter_ground_weapons(_server_weapon_types())
	for role in players:
		var p: Node = players[role]
		if p.weapons == null:
			continue
		var t := 1   # 兜底:池子空(全禁/无地板格)时至少给手枪
		if not ground_weapons.entries.is_empty():
			var idx := randi() % ground_weapons.entries.size()
			var e: Dictionary = ground_weapons.remove(int(ground_weapons.entries[idx]["inst"]))
			_remove_ground_weapon(int(e["inst"]))
			t = int(e["type_id"])
		p.weapons.set_initial_inventory([t])


# 换局:清空重铺 + 每人背包重置为随机一把。
# 与"还原可破坏砖 + 清子弹"同一纪律 —— 两端每局从同一基线出发,装备也是本局的进度。
func _reset_ground_weapons() -> void:
	for inst in _ground_nodes.keys():
		var n = _ground_nodes[inst]
		if n != null and is_instance_valid(n):
			n.queue_free()
	_ground_nodes.clear()
	_self_drop_until.clear()
	ground_weapons.clear()
	_next_ground_inst = 1
	_setup_ground_weapons()
