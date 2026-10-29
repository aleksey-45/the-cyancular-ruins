class_name MatchGround
extends MatchState

# 地面武器域(服务器权威):表 + 拾取/丢弃裁决 + 事件广播 + 初始分布/换局重置。★ 本文件是继承链的中间层
# (→ MatchSnapshot → MatchGround → MatchState):按 match_state.gd 的规矩不得定义 _init/_ready/_enter_tree/
# _exit_tree/_physics_process。★ 服务器真的实例化 WeaponPickup:落点由物理决定、而它决定「够不够得着」。

# ★ 仅测试用(默认关,只由 worker 的 --test-ground-teleport 打开,生产路径不可达):每帧保证每个站着的玩家
# 脚下 64px 内至少有一把枪 —— 探针就不必走位(只会水平走 + 卡住跳的机器人在窄台上会永久卡死)。
static var test_ground_teleport := false

var ground_weapons := GroundWeaponField.new()
var _next_ground_inst := 1
var _ground_nodes: Dictionary = {}     # inst -> WeaponPickup(服务器侧;headless 不渲染)
var _self_drop_until: Dictionary = {}  # role -> {inst: 解禁时刻(ms)},防"丢完立刻捡回"


# 本局投放的武器类型清单:每种 2 把、跳过被禁的;与单机 Level0._default_weapon_types 同源(都取注册表),差别只在禁用表。
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


# self_role >= 0 表示这把是该 role 刚丢下的 ⇒ 冷却期内不参与他自己的拾取判定。
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


# 把落体的实际位置每帧同步回表:落点由 WeaponPickup 物理决定,而拾取判定(nearest_within)读的是表里的 pos。
func _sync_ground_positions() -> void:
	for inst in _ground_nodes:
		var n = _ground_nodes[inst]
		if n != null and is_instance_valid(n):
			var e: Dictionary = ground_weapons.get_entry(int(inst))
			if not e.is_empty():
				e["pos"] = (n as WeaponPickup).canonical_pos


# ★ 仅测试用(见 test_ground_teleport):把最近的一把挪到脚下;判据直接用 PlayerParams.weapon_pickup_radius,免得「服务器认为够得着」与「实际捡得到」漂移。
func _debug_keep_weapon_within_reach() -> void:
	if not test_ground_teleport or ground_weapons.entries.is_empty():
		return
	for role in players:
		var p: Node2D = players[role]
		if p == null or p.is_downed():
			continue
# ★ 必须排除他自己刚丢下的那些(冷却期内本就不参与他的拾取判定),否则会喂到那把 —— 探针看着枪在脚边却捡不起来。
		var blocked: Array = _live_self_drops(role)
		if not ground_weapons.nearest_within(
				p.global_position, PlayerParams.weapon_pickup_radius, blocked).is_empty():
			continue   # 已经有够得着、且捡得动的,不动它
		var near: Dictionary = ground_weapons.nearest_within(p.global_position, 1e9, blocked)
		if near.is_empty():
			continue
		var n = _ground_nodes.get(int(near["inst"]), null)
		if n == null or not is_instance_valid(n):
			continue
		var pk := n as WeaponPickup
# 直接挪节点即可:拾取判定与 F 提示比的就是 canonical_pos,而它就是视觉中心(两者自 2026-09-17 起合并)。
		pk.canonical_pos = p.global_position
		pk.global_position = pk.canonical_pos
		pk.velocity = Vector2.ZERO
		pk._settled = true          # 停稳:落体逻辑不再动它,位置由本次赋值说了算
		near["pos"] = pk.canonical_pos


# ★ 一件地面武器的权威节点位置(canonical,恒在 [0,MAP));下发给客户端的 pos 一律用它。保留「读活节点」
# 而不是读表,是为了拿到节点自己的权威值并对陈旧条目留痕;表里那份 pos 每帧被 _sync_ground_positions 刷成同一个值。
func _canonical_of(inst: int) -> Vector2:
	var n = _ground_nodes.get(inst, null)
	if n != null and is_instance_valid(n):
		return (n as WeaponPickup).canonical_pos
# ★ 节点与条目一起增删,走不到这里;真走到 = 有陈旧条目 —— 不静默:兜底回表并 push_warning(可能与实际落点不符)。
	var e: Dictionary = ground_weapons.get_entry(inst)
	push_warning("MatchGround._canonical_of: inst %d 没有活节点,退回表里的 pos(可能与实际落点不符)" % inst)
	return e.get("pos", Vector2.ZERO)


# 给 match_sync_data 的载荷(客户端进场拉取时一并拿到开局那批)。
# ★ 本函数是「当前状态」、不是「生成事件」(后者是 _broadcast_weapon_spawned):pos 与 vel 都取活节点此刻的值。
# 调用时机两个(进场一次 + 每次重连一次);重连那次那些枪早已落定,若沿用条目里「生成时刻的 vel」,客户端会把它
# 重扔一次(configure 会置 velocity 且 _settled = false,重演约 2 格下落),F 提示就会指着服务器上没有枪的位置。
# 取活速度而不是强行落定(置零 / 置 _settled),是因为后者会把一把半空中的枪冻住。
# ⚠ 零守卫:ground_action_probe 已删(2026-10-09),「载荷 pos == 拾取判定圆心」这条契约今天只靠本注释维持。
func ground_weapons_payload() -> Array:
	var out: Array = []
	for e in ground_weapons.entries:
		var d: Dictionary = e.duplicate(true)
		var inst := int(e["inst"])
		d["pos"] = _canonical_of(inst)
		d["vel"] = _live_velocity_of(inst)
		out.append(d)
	return out


# 一件地面武器此刻的速度(已停稳的是零;半空中的是真实速度)。★ 兜底纪律与 _canonical_of 同款(没有活节点 → 退回条目那份);这里不重复留痕,调用方会先留过。
func _live_velocity_of(inst: int) -> Vector2:
	var n = _ground_nodes.get(inst, null)
	if n != null and is_instance_valid(n):
		return (n as WeaponPickup).velocity
	var e: Dictionary = ground_weapons.get_entry(inst)
	return e.get("vel", Vector2.ZERO)


# by_role = 这把是谁刚丢下的(-1 = 开局铺的/无主)。★ 客户端靠它排除自己刚丢的那把:那条 0.5s 冷却只有服务器知道,不告诉客户端就会「短暂显示 F 却捡不起来」。
func _broadcast_weapon_spawned(inst: int, by_role: int = -1) -> void:
	var e: Dictionary = ground_weapons.get_entry(inst)
	if e.is_empty():
		return
# ★ pos 显式取 canonical 而不是读 e["pos"]:今天两者等价,但契约必须是「读刚生成的节点」。
# ★ vel 必须保持是「生成时那一份」(表里的 vel 从不被 _sync_ground_positions 刷新)—— 客户端拿它 + canonical
# 重放落体才有「落点与何时开始模拟无关」;哪天把 vel 也做成逐帧刷新,两端落点会立刻发散而且不报错。
	_rpc_all(WireKind.WEAPON_SPAWNED, [{"inst": inst, "type_id": int(e["type_id"]),
			"mag": int(e["mag"]), "pos": _canonical_of(inst), "vel": e["vel"], "by_role": by_role}])


func _broadcast_weapon_removed(inst: int, by_role: int) -> void:
	_rpc_all(WireKind.WEAPON_REMOVED, [{"inst": inst, "by_role": by_role}])



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


# 拾取:一次只捡最近的一把(与单机同规则);服务器裁决 —— 两人抢同一把时谁先被消费到这里谁得,输的一方客户端从未预测过,不需要回滚。
func _try_server_pickup(p: Node2D, role: int) -> void:
	var e: Dictionary = ground_weapons.nearest_within(
			p.global_position, PlayerParams.weapon_pickup_radius, _live_self_drops(role))
	if e.is_empty():
		# 诊断(--diag,默认关):把「一次都没命中」拆成两种成因 —— 附近确实没枪(none),还是枪在但超出 64px 半径(range)。
		# 这就是用户那张「看得见却捡不起来」的现场唯一能分开的解释;半径与距离同源(weapon_pickup_radius + 环面最短距离)。
		if NetDiag.enabled():
			var any: Dictionary = ground_weapons.nearest_within(p.global_position, 1e9, _live_self_drops(role))
			if any.is_empty():
				NetDiag.log_event("pickup_try", {"role": role, "result": "none"})
			else:
				var dist := GridPathfinder.toroidal_delta_px(any["pos"], p.global_position,
						float(GameParameters.MAP_WIDTH), float(GameParameters.MAP_HEIGHT)).length()
				NetDiag.log_event("pickup_try", {"role": role, "result": "range",
						"dist": snappedf(dist, 0.1), "radius": PlayerParams.weapon_pickup_radius,
						"type": int(any.get("type_id", 0))})
		return
	var inst := int(e["inst"])
	var dropped: int = p.weapons.pick_up(int(e["type_id"]), int(e["mag"]))
	if dropped < 0:
		NetDiag.log_event("pickup_try", {"role": role, "result": "denied",
				"type": int(e["type_id"]), "inst": inst})
		return   # 被禁用闸门拒绝:地面那件留着(与单机同款哨兵,见 WeaponComponent.PICKUP_DENIED)
	NetDiag.log_event("pickup_try", {"role": role, "result": "taken", "type": int(e["type_id"]),
			"inst": inst, "replaced": dropped})
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
	if p.weapons.current_type_id() == 0:
		return   # 空手没什么可丢
	var e: Dictionary = p.weapons.drop_current()
	if e.is_empty():
		return
	var ni := _spawn_ground_weapon(int(e["type"]), int(e["mag"]),
			p.global_position + PlayerParams.weapon_drop_offset * Vector2(float(p.facing_direction), 1.0),
			Vector2(PlayerParams.weapon_drop_speed * p.facing_direction, -PlayerParams.weapon_drop_up),
			0, role)
	_broadcast_weapon_spawned(ni, role)


# 从背包随机保留一条(并 equip 它),其余在 p 当前所在位置散开掉出。★ 唯一调用时机 = 倒地边沿,三个模式各一处
# (MatchRound / RoyaleHost / TeamHost 的 _match_round_tick);不挂在复活流程里 —— 那里人会先被瞬移到出生点。
# ★ 保留哪把由 random_keep_one() 决定(内部已 equip),_respawn_player 里不许再调一次;★ 不补满弹(残弹跟着枪走)。
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

		var ang := TAU * float(i) / float(n)
		var vel := Vector2(cos(ang), -absf(sin(ang))) * 380.0
		var inst := _spawn_ground_weapon(int(e["type"]), int(e.get("mag", WeaponInventory.MAG_FULL)),
				pos + Vector2(0.0, -12.0), vel, 0, role)
		_broadcast_weapon_spawned(inst, role)




# ★ 判据唯一来源 = MazeGenerator.is_floor_cell_with_headroom,别在这儿抄第二份;本函数自己扫全量地板格、没走 SpawnPicker。
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


# 开局:铺 12 把(每种 2 把、跳过禁用),再让每个玩家(含 AI 补位)从池子里随机拿 1 把。
# ★ 这同时是「服务器玩家必须有枪」的唯一来源:player.tscn 的 _ready 给的是空背包,不发就开不了火(PvP 直接哑火)。
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


# 换局:清空重铺 + 每人背包重置为随机一把(与还原砖、清子弹同一纪律:两端每局从同一基线出发)。
# ★ 清的与铺的都必须广播 —— 换局是客户端唯一既不重进场景、也不再拉一次 match_sync 的时刻:不广播会留下一整批
# 上一局的幽灵枪,而新一轮那批在它那儿一件都不存在。★ _next_ground_inst 不重置:撞号会让客户端静默 return。
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
# 先清后铺(可靠通道保序)。★ 铺完只广播留在场上的那些 —— 发给玩家的那把已从表里摘走,广播出去客户端会凭空多一件。
	for inst in cleared:
		_broadcast_weapon_removed(int(inst), -1)
	for e in ground_weapons.entries:
		_broadcast_weapon_spawned(int(e["inst"]), -1)
