class_name PickupSync
extends RefCounted


var _state: ClientState = null
var _ports: ClientPorts = null

# ── 拾取诊断插桩(★ 默认关;开关 -- --pickup-diag,必须写在 -- 之后,写在前面会被 Godot 丢掉)── 用来回答「地上的枪看得见、走过去却没有 F 提示」:那种症状只有两种成因 —— ① 客户端压根没建出这把枪(on_spawned 的早退是静默 return);② 建出来了但 canonical_pos(提示判据读的值)与画出来的位置不在一处。
var _pickup_diag := false
var _pickup_diag_checked := false
var _pickup_diag_frame := 0

var ground_weapons := GroundWeaponField.new()
var _pickup_nodes: Dictionary = {}
var _self_drop_until: Dictionary = {}

const PICKUP_SCENE := preload("res://scenes/weapons/weapon_pickup.tscn")


func bind(state: ClientState, ports: ClientPorts) -> void:
	_state = state
	_ports = ports


func _pickup_diag_on() -> bool:
	if not _pickup_diag_checked:
		_pickup_diag_checked = true
		_pickup_diag = OS.get_cmdline_user_args().has("--pickup-diag")
	return _pickup_diag


func subscribe() -> void:
	NetBus.local_weapon_spawned.connect(on_spawned)
	NetBus.local_weapon_removed.connect(on_removed)


func on_spawned(data: Dictionary) -> void:
	_spawn_pickup_node(data)


func on_removed(data: Dictionary) -> void:
	remove(int(data.get("inst", 0)))


func _spawn_pickup_node(data: Dictionary) -> void:
	# 诊断:早退是静默的 —— 先把"为什么没建"打出来。
	if _pickup_diag_on():
		print("[pkd] ← spawned inst=%s type=%s by_role=%s pos=%s vel=%s | world=%s local=%s 已有=%s" % [
				str(data.get("inst", -1)), str(data.get("type_id", -1)), str(data.get("by_role", -1)),
				str(data.get("pos", Vector2.ZERO)), str(data.get("vel", Vector2.ZERO)),
				"有" if _state._world != null else "空", "有" if _state._local != null else "空",
				"是" if _pickup_nodes.has(int(data.get("inst", 0))) else "否"])
	if _state._world == null:
		NetDiag.log_event("pickup_skip", {"reason": "no_world", "inst": int(data.get("inst", 0))})
		return
	var inst := int(data.get("inst", 0))
	if inst <= 0:
		NetDiag.log_event("pickup_skip", {"reason": "bad_inst", "inst": inst})
		return
	if _pickup_nodes.has(inst):
		_reanchor_existing(inst, data)
		return
	var type_id := int(data.get("type_id", 1))
	var node: WeaponPickup = PICKUP_SCENE.instantiate()
	node.configure(type_id, inst, int(data.get("mag", 0)), data.get("vel", Vector2.ZERO))
	_state._world.add_child(node)
	node.canonical_pos = data.get("pos", Vector2.ZERO)
	node.set_anchor((_state._local as Node2D).global_position if _state._local != null else Vector2.ZERO)
	node.sync_render_from_canonical()
	ground_weapons.map_size = Vector2(float(GameParameters.MAP_WIDTH), float(GameParameters.MAP_HEIGHT))
	ground_weapons.add({"inst": inst, "type_id": type_id, "mag": int(data.get("mag", 0)),
			"pos": node.canonical_pos, "vel": data.get("vel", Vector2.ZERO)})
	_pickup_nodes[inst] = node
	NetDiag.log_event("pickup_add", {"inst": inst, "type": type_id,
			"by_role": int(data.get("by_role", -1)),
			"pos": [snappedf(node.canonical_pos.x, 0.01), snappedf(node.canonical_pos.y, 0.01)]})
	if int(data.get("by_role", -1)) == int(PvpSession.role):
		_self_drop_until[inst] = Time.get_ticks_msec() 				+ int(PlayerParams.weapon_pickup_self_delay * 1000.0)


func _reanchor_existing(inst: int, data: Dictionary) -> void:
	var n = _pickup_nodes.get(inst, null)
	if n == null or not is_instance_valid(n):
		_pickup_nodes.erase(inst)
		return
	var node := n as WeaponPickup
	node.canonical_pos = data.get("pos", node.canonical_pos)
	node.velocity = data.get("vel", Vector2.ZERO)
	node._settled = bool(data.get("settled", false)) or node.velocity == Vector2.ZERO
	node.sync_render_from_canonical()
	if not ground_weapons.reanchor(inst, node.canonical_pos, node.velocity):
		NetDiag.log_event("pickup_skip", {"reason": "reanchor_missing", "inst": inst})
		return
	NetDiag.log_event("pickup_anchor", {"inst": inst, "settled": bool(data.get("settled", false))})


func clear() -> void:
	for inst in _pickup_nodes:
		var n = _pickup_nodes[inst]
		if n != null and is_instance_valid(n):
			n.queue_free()
	_pickup_nodes.clear()
	ground_weapons.clear()
	_self_drop_until.clear()


func remove(inst: int) -> void:
	NetDiag.log_event("pickup_remove", {"inst": inst, "had_node": _pickup_nodes.has(inst)})
	ground_weapons.remove(inst)
	var n = _pickup_nodes.get(inst, null)
	if n != null and is_instance_valid(n):
		n.queue_free()
	_pickup_nodes.erase(inst)
	_self_drop_until.erase(inst)
	if _pickup_diag_on():
		print("[pkd] ← removed inst=%d" % inst)


func tick() -> void:
	if _state._local == null:
		return
	var lp: Vector2 = (_state._local as Node2D).global_position
	for inst in _pickup_nodes:
		var n = _pickup_nodes[inst]
		if n == null or not is_instance_valid(n):
			continue
		var pk := n as WeaponPickup
		pk.set_anchor(lp)
		pk.sync_render_from_canonical()
		var e: Dictionary = ground_weapons.get_entry(int(inst))
		if not e.is_empty():
			e["pos"] = pk.canonical_pos
	_pickup_diag_frame += 1
	_update_pickup_prompt(lp)


func _update_pickup_prompt(lp: Vector2) -> void:
	var self_drops := _live_self_drops()
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	for inst in _pickup_nodes:
		var n = _pickup_nodes.get(inst, null)
		if n == null or not is_instance_valid(n):
			continue
		var pk := n as WeaponPickup
		var can := false
		if _state._local != null and not _live_self_drops().has(int(inst)) 				and _state._local.weapons.is_type_enabled(int(pk.type_id)):
			var d := GridPathfinder.toroidal_delta_px(pk.canonical_pos, lp, w, h).length()
			can = d <= PlayerParams.weapon_pickup_radius
		pk.set_prompt_visible(can)
		if _pickup_diag_on() and _pickup_diag_frame % 30 == 0:
			var dd := GridPathfinder.toroidal_delta_px(pk.canonical_pos, lp, w, h).length()
			if dd <= 400.0:
				print("[pkd]   inst=%d type=%d d=%.1f can=%s | 冷却=%s 启用=%s | canon=(%.0f,%.0f) render=(%.0f,%.0f) 玩家=(%.0f,%.0f) settled=%s" % [
						int(inst), int(pk.type_id), dd, "是" if can else "否",
						"是" if _live_self_drops().has(int(inst)) else "否",
						"是" if _state._local.weapons.is_type_enabled(int(pk.type_id)) else "否",
						pk.canonical_pos.x, pk.canonical_pos.y,
						pk.global_position.x, pk.global_position.y, lp.x, lp.y,
						"是" if pk._settled else "否"])


func _live_self_drops() -> Array:
	var out: Array = []
	if _self_drop_until.is_empty():
		return out
	var now := Time.get_ticks_msec()
	for inst in _self_drop_until.keys():
		if int(_self_drop_until[inst]) > now:
			out.append(inst)
		else:
			_self_drop_until.erase(inst)
	return out
