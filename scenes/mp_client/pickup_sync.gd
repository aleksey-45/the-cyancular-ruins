class_name PickupSync
extends RefCounted

# 地面武器(拾取)组合件(2026-10-22 从 PvpMatchClient 拆出;Task 7):事件订阅 + 节点表 + F 提示 + 诊断。
# 形状是**组合**不是继承:宿主 PvpMatchClient 只剩 `_subscribe_ground_weapons()` / `_spawn_pickup_node()` /
# `_clear_ground_weapons()` / `_remove_pickup_node()` / `_tick_ground_weapons()` 五个委托口;
# 本类经 bind(client) 读宿主的 `_world` / `_local`(与拆件前同一个字段、同一个对象)。
# ★ `[pkd]` 诊断行是运维判据,文本逐字未改(见 docs/eng/weapons.md)。

var _client: Node = null

# ── 拾取诊断插桩(★ 默认关;开关 -- --pickup-diag,必须写在 -- 之后,写在前面会被 Godot 丢掉)── 用来回答「地上的枪看得见、走过去却没有 F 提示」:那种症状只有两种成因 —— ① 客户端压根没建出这把枪(on_spawned 的早退是静默 return);② 建出来了但 canonical_pos(提示判据读的值)与画出来的位置不在一处。两者在画面上长得一模一样,只能靠数字分;判据是玩家 400px 内的枪每 30 物理帧打一行。
var _pickup_diag := false
var _pickup_diag_checked := false
var _pickup_diag_frame := 0

# ── 地面武器:服务器权威,本端只渲染 + 等事件(不做客户端预测)──
var ground_weapons := GroundWeaponField.new()
var _pickup_nodes: Dictionary = {}    # inst -> WeaponPickup
var _self_drop_until: Dictionary = {} # inst -> 解禁时刻(ms):自己刚丢下的那把,
                                      # 冷却期内不提示(与服务器 _live_self_drops 同口径;
                                      # 不排的话刚丢下的枪会显示 F 却捡不起来)

const PICKUP_SCENE := preload("res://scenes/weapons/weapon_pickup.tscn")


func bind(client: Node) -> void:
	_client = client


func _pickup_diag_on() -> bool:
	if not _pickup_diag_checked:
		_pickup_diag_checked = true
		_pickup_diag = OS.get_cmdline_user_args().has("--pickup-diag")
	return _pickup_diag


# 订阅服务器的两条地面武器事件。★ 必须走 NetBus,不是 NetBusExt —— 后者里有同名遗留的 beam_fired,挂错节点的表现是静默 no-op(对手的枪凭空消失 / 永不再现,且不报错)。两个子类各自 _ready 里经宿主调一次。
func subscribe() -> void:
	Wire.local_weapon_spawned.connect(on_spawned)
	Wire.local_weapon_removed.connect(on_removed)


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
				"有" if _client._world != null else "空", "有" if _client._local != null else "空",
				"是" if _pickup_nodes.has(int(data.get("inst", 0))) else "否"])
	if _client._world == null:
		NetDiag.log_event("pickup_skip", {"reason": "no_world", "inst": int(data.get("inst", 0))})
		return
	var inst := int(data.get("inst", 0))
	if inst <= 0 or _pickup_nodes.has(inst):
		NetDiag.log_event("pickup_skip", {"reason": "dup" if _pickup_nodes.has(inst) else "bad_inst", "inst": inst})
		return
	var type_id := int(data.get("type_id", 1))
	var node: WeaponPickup = PICKUP_SCENE.instantiate()
	node.configure(type_id, inst, int(data.get("mag", 0)), data.get("vel", Vector2.ZERO))
	_client._world.add_child(node)
	# 权威位置与渲染位置分开(见 WeaponPickup 的字段注释):事件里的 pos 是 canonical。
	node.canonical_pos = data.get("pos", Vector2.ZERO)
	node.set_anchor((_client._local as Node2D).global_position if _client._local != null else Vector2.ZERO)
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


# 清空本端的地面武器表与全部拾取物节点(_on_match_sync 的"先清后灌"用)。★ 为什么必须先清:match_sync 的 ground_weapons 是全量,不清就直接 add,掉线期间已被服务器移除的那些会变成永久幽灵枪(看着在、按 F 无效);进场那次本地本来是空的,清一遍是 no-op。
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


# 每帧:① 把锚点推给所有地面武器(接缝另一侧的枪要画在身边那一份上);② 把落体的实际位置同步回本地表(提示的"最近一把"要跟着落点走);③ 更新 F 提示。
func tick() -> void:
	if _client._local == null:
		return
	var lp: Vector2 = (_client._local as Node2D).global_position
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


# F 提示:贴到"按 F 会捡到的那一把"上方,每把能捡的各自一个。★ 与服务器 _try_server_pickup 用同一个 nearest_within + 同一个半径,否则会出现"提示了 A、服务器却捡了 B";★ "自己刚丢下"的冷却与服务器同源:weapon_spawned 带 by_role,本端据此写 _self_drop_until,冷却期内不给提示(与服务器 _live_self_drops 同口径)。
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
		if _client._local != null and not _live_self_drops().has(int(inst)) 				and _client._local.weapons.is_type_enabled(int(pk.type_id)):
			var d := GridPathfinder.toroidal_delta_px(pk.canonical_pos, lp, w, h).length()
			can = d <= PlayerParams.weapon_pickup_radius
		pk.set_prompt_visible(can)
		# 诊断:玩家附近的枪逐条打;can=否 时把三条闸门各是真是假分开打(合成一个 false 就看不出是哪一条挡的);canon 与 render 两栏是重点 —— 两者本应只差整数个地图宽 / 高。
		if _pickup_diag_on() and _pickup_diag_frame % 30 == 0:
			var dd := GridPathfinder.toroidal_delta_px(pk.canonical_pos, lp, w, h).length()
			if dd <= 400.0:
				print("[pkd]   inst=%d type=%d d=%.1f can=%s | 冷却=%s 启用=%s | canon=(%.0f,%.0f) render=(%.0f,%.0f) 玩家=(%.0f,%.0f) settled=%s" % [
						int(inst), int(pk.type_id), dd, "是" if can else "否",
						"是" if _live_self_drops().has(int(inst)) else "否",
						"是" if _client._local.weapons.is_type_enabled(int(pk.type_id)) else "否",
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
