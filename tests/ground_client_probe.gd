extends Node

# 局内「捡枪 / 丢枪」探针(客户端侧,场景模式)。
# 跑法:
#   "$GODOT" --headless --path . --quit-after 3600 res://tests/ground_client_probe.tscn
# 期望:每条 [gc] … 通过,末行 "GROUND CLIENT PROBE: ALL-OK"。
#
# 为什么单开一个:`ground_action_probe` 证了**服务器权威侧**那条路是干净的,而用户报的
# 「捡武器崩溃」在两端共用的另一头 —— 客户端。客户端上**只有拾取才会走到**的那段是:
#   `NetBus.local_weapon_removed` → `PvpMatchClient._remove_pickup_node`;
# 以及背包被权威改动后的 `restore_inventory` + `equip`(快照 c2 那条)。
# 开局铺的那 12 把只走 `_spawn_pickup_node`,所以"开局看得见枪"不能证明拾取这条路没问题。
#
# 做法:真 Level0(pvp_mode → 只建世界)+ 真 Player + 一个**没入树**的 `PvpMatchClient` 实例
# (基类,`_ready` 为空 —— 不入树就不会跑它的 `_physics_process`,那条会发网络包)。
# 客户端的地面武器表/节点生命周期全走生产函数,不重写一份。
#
# ⚠ 判据 grep 文本 "GROUND CLIENT PROBE: ALL-OK"(不只看退出码)。

const MAP := "res://maps/factory1v1.cyrm"

var _failures: Array[String] = []
var _client: PvpMatchClient = null
var _level0: Node = null
var _world: Node = null
var _local: Node2D = null
var _next_inst := 1


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("[gc]   ✓ %s" % msg)
	else:
		_failures.append(msg)
		print("[gc]   ✗ %s" % msg)


func _ready() -> void:
	MazeGenerator.set_map_file(MAP)
	GameParameters.refresh_map_size()
	Level0.pvp_mode = true
	_level0 = load("res://scenes/level_0.tscn").instantiate()
	add_child(_level0)
	_world = _level0.get_node("WorldViewport")
	_local = _world.get_node("Player")
	_local.weapons.set_initial_inventory([1])   # PvP 里由服务器发枪;探针自己发一把
	_client = PvpMatchClient.new()              # ★ 不入树:基类 _ready 为空,入了反而跑 _physics_process
	_client._world = _world
	_client._local = _local
	print("[gc] 客户端探针就绪:地图 %s,本地玩家槽 %d" % [
			MAP.get_file(), _local.weapons.current_slot_int()])
	_run()


func _run() -> void:
	for i in 30:
		await get_tree().physics_frame
	await _phase_spawn_batch()
	await _phase_prompt_near_weapon()
	await _phase_pickup_removal()
	await _phase_authoritative_inventory_change()
	await _phase_cycle_stress()
	await _phase_switch_field_contract()
	await _phase_replica_empty_hands()

	if _failures.is_empty():
		print("GROUND CLIENT PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("GROUND CLIENT PROBE: FAIL %s" % str(_failures))
		get_tree().quit(1)


# ── ① 开局那批(match_sync 载荷形状):按事件建节点、挂进 WorldViewport、能落体 ──
func _phase_spawn_batch() -> void:
	print("[gc] ── ① 开局批次进场(5 件)──")
	var base: Vector2 = _local.global_position
	for i in 5:
		var pos := base + Vector2(400.0 + i * 220.0, -200.0)
		_client._spawn_pickup_node({
			"inst": _take_inst(), "type_id": 1 + (i % 6), "mag": -1,
			"pos": pos, "vel": Vector2.ZERO, "by_role": -1,
		})
	_check(_client._pickup_nodes.size() == 5, "建了 5 个客户端节点(实际 %d)" % _client._pickup_nodes.size())
	_check(_client.ground_weapons.size() == 5, "本地地面表 5 条(实际 %d)" % _client.ground_weapons.size())
	var wrong_parent := 0
	for inst in _client._pickup_nodes:
		var n = _client._pickup_nodes[inst]
		if not is_instance_valid(n) or n.get_parent() != _world:
			wrong_parent += 1
	_check(wrong_parent == 0, "每件都挂在 WorldViewport 下(错挂 %d 件)" % wrong_parent)
	for i in 60:
		await get_tree().physics_frame
		_client._tick_ground_weapons()
	var moved := 0
	for inst in _client._pickup_nodes:
		var n: WeaponPickup = _client._pickup_nodes[inst]
		var e: Dictionary = _client.ground_weapons.get_entry(int(inst))
		if not e.is_empty() and (e["pos"] as Vector2).y > (n as Node2D).canonical_pos.y - 400.0:
			moved += 1
	_check(moved == 5, "落体把实际位置同步回了本地表(%d/5)" % moved)


# ── ② 走近武器 → 提示节点懒建(客户端特有的一条分支)──
func _phase_prompt_near_weapon() -> void:
	print("[gc] ── ② 靠近显示 F 提示 ──")
	var inst: int = int(_client._pickup_nodes.keys()[0])
	var pk: WeaponPickup = _client._pickup_nodes[inst]
	# ★ 每帧重新贴一次:玩家有重力,只设一次会被自己掉走 —— 那样这条断言会**间歇性**
	#   变红(实测:同一份代码连跑三遍,红绿绿),看着像功能坏了,其实是探针没站稳。
	for i in 10:
		_local.global_position = pk.canonical_pos
		_local.velocity = Vector2.ZERO
		await get_tree().physics_frame
		_client._tick_ground_weapons()
	# ★ 用成员而不是 `get_node_or_null("PickupPrompt")`:`PickupPrompt.new()` 建出来的节点
	#   **不叫** "PickupPrompt"(脚本建的节点名要到入树才由引擎补),按名字找必然 null。
	_check(pk.get("_prompt") != null, "提示节点已懒建")
	_check(is_instance_valid(pk), "提示建好后武器节点仍有效")


# ── ③ 拾取:**只有拾取才会走**的客户端路径(_on_weapon_removed → _remove_pickup_node)──
func _phase_pickup_removal() -> void:
	print("[gc] ── ③ 服务器广播 weapon_removed(拾取)──")
	var before: int = _client._pickup_nodes.size()
	var inst: int = int(_client._pickup_nodes.keys()[0])
	_client._on_weapon_removed({"inst": inst, "by_role": int(PvpSession.role)})
	_check(_client._pickup_nodes.size() == before - 1,
			"客户端节点少一件(%d → %d)" % [before, _client._pickup_nodes.size()])
	_check(_client.ground_weapons.size() == before - 1,
			"本地地面表少一条(实际 %d)" % _client.ground_weapons.size())
	_check(not _client._self_drop_until.has(inst), "自己刚丢下的冷却表清掉了该 inst")
	# ★ 关键:被 queue_free 的节点在**本帧余下时间仍会被 tick 到**吗?让帧跑完再看。
	for i in 10:
		await get_tree().physics_frame
		_client._tick_ground_weapons()
	_check(_client._pickup_nodes.size() == before - 1, "10 帧后仍是 %d 件" % _client._pickup_nodes.size())
	_check(is_instance_valid(_local), "本地玩家仍有效")


# ── ④ 权威改了背包(拾取的 c2):restore_inventory + equip ──
func _phase_authoritative_inventory_change() -> void:
	print("[gc] ── ④ 权威背包变化(快照 c2 那条)──")
	var w: WeaponComponent = _local.weapons
	var before: int = w.inventory.held.size()
	# 服务器说:手上还是手枪 + 又捡了一把霰弹(残弹 3)
	var inv: Array = [
		{"type": 1, "inst": 1, "mag": 5},
		{"type": 4, "inst": 2, "mag": 3},
	]
	_local.restore_state({"wslot": 4, "inv": inv})
	_check(w.inventory.held.size() == 2,
			"背包按权威重建(旧 %d → 新 %d,期望 2)" % [before, w.inventory.held.size()])
	_check(w.current_slot_int() == 4, "切到权威的 wslot(实际 %d)" % w.current_slot_int())
	for i in 10:
		await get_tree().physics_frame
	_check(w.current_weapon() == null or is_instance_valid(w.current_weapon()),
			"手持武器引用有效")
	# 权威说那把空手了(wslot 0 / 空背包)→ 不该留下悬垂引用
	_local.restore_state({"wslot": 0, "inv": []})
	for i in 10:
		await get_tree().physics_frame
	_check(w.inventory.held.is_empty(), "空背包按权威生效(实际 %d)" % w.inventory.held.size())
	# ★ 权威说"空手"时不能只清索引:那把枪的实例还会活着,而 `tick()`/`fire()` 只判
	#   `_player_ok()`(player 非空且没倒地)、**不看索引** —— 于是手上留着一把索引 -1
	#   却照常开火的**幽灵枪**。软回灌(`sync_soft_state`)之后这条路径是常路,不再是冷门。
	_check(w.current_weapon() == null,
			"权威空手后不得留有可开火的武器实例(实际 %s)" % str(w.current_weapon()))
	_check(is_instance_valid(_local), "本地玩家仍有效")


# ── ⑤ 拾取/丢出交替 60 轮 ──
func _phase_cycle_stress() -> void:
	print("[gc] ── ⑤ 拾取/丢出交替 60 轮 ──")
	_local.weapons.set_initial_inventory([1])
	# ★ 基线取**开始前**的件数,不假设"跑完必须为空":③ 还留着几件在地面表里,
	#   而本相每轮是"+1 建 / -1 删"净零 —— 断言"清空"是把别相的残留算到这一相头上。
	var nodes0: int = _client._pickup_nodes.size()
	var field0: int = _client.ground_weapons.size()
	for i in 60:
		var inst := _take_inst()
		var type_id := 1 + (i % 6)
		var pos: Vector2 = _local.global_position + Vector2(0.0, -80.0)
		_client._on_weapon_spawned({"inst": inst, "type_id": type_id, "mag": -1,
				"pos": pos, "vel": Vector2.ZERO, "by_role": int(PvpSession.role)})
		await get_tree().physics_frame
		_client._tick_ground_weapons()
		# 权威采納了这次拾取 → 广播 removed + 背包变化
		_client._on_weapon_removed({"inst": inst, "by_role": int(PvpSession.role)})
		_local.restore_state({"wslot": type_id, "inv": [
			{"type": 1, "inst": 100, "mag": -1},
			{"type": type_id, "inst": 101 + i, "mag": -1},
		]})
		await get_tree().physics_frame
		_client._tick_ground_weapons()
	_check(_client._pickup_nodes.size() == nodes0,
			"60 轮净零:节点数不变(%d → %d)" % [nodes0, _client._pickup_nodes.size()])
	_check(_client.ground_weapons.size() == field0,
			"60 轮净零:地面表条目数不变(%d → %d)" % [field0, _client.ground_weapons.size()])
	_check(is_instance_valid(_local), "60 轮后本地玩家仍有效")


# ── ⑥ 切枪包的字段契约:两条路径产出的都必须是**背包位置**(1-based)──
# 为什么:滚轮那条曾经上行**武器类型 id**,而消费端(`player.gd`)读的是 `equip_index(字段 - 1)`
# —— 按**背包位置**。背包 `[步枪2, 手枪1]` 从步枪滚一下 → 发 1 → 服务器 `equip_index(0)` 切回
# **步枪**(等于没切);`[手枪1, 重狙3]` → 发 3 → `equip_index(2)` **越界早退**,压根没切。
# 随后权威 `wslot` 经 `sync_soft_state` 把客户端拉回原枪 = 「滚轮切不动」。
# 选 `[3, 1]`(重狙 / 手枪)是因为**类型 id 与背包位置不同**,能把两者区分开;`[1, 2]` 那种
# 恰好相等,测了也白测(红绿一样)。
func _phase_switch_field_contract() -> void:
	print("[gc] ── ⑥ 切枪包字段 = 背包位置 ──")
	var w: WeaponComponent = _local.weapons
	w.set_initial_inventory([3, 1])   # 位置 0 = 重狙(类型 3)、位置 1 = 手枪(类型 1)
	_check(w.inventory.held.size() == 2 and w.current_slot_int() == 3,
			"先摆成两把(实际 %d 把,手上槽 %d)" % [w.inventory.held.size(), w.current_slot_int()])
	# 从位置 0 往正方向滚一次 → 目标位置 1
	w.request_net_cycle(1)
	var sent: int = w.consume_net_slot()
	_check(sent == 2, "滚轮上行的是**背包位置** 2(实际 %d)" % sent)
	_check(sent != 1, "上行值不得是目标那把的**类型 id**(1)—— 消费端按位置读,发类型 id 会切错/越界")
	_check(w._current_index == 1 and w.current_slot_int() == 1,
			"本地同刻切到位置 1(实际 index=%d slot=%d)" % [w._current_index, w.current_slot_int()])
	# 再走一遍**消费端口径**(服务器 `player.gd` 的那句):同一个字段必须还原出同一个位置
	w.equip_index(0)
	_check(w._current_index == 0, "先切回位置 0(实际 %d)" % w._current_index)
	w.equip_index(sent - 1)
	_check(w._current_index == 1 and w.current_slot_int() == 1,
			"按消费端口径 equip_index(字段 - 1) 落回同一把(实际 index=%d slot=%d)" % [
					w._current_index, w.current_slot_int()])
	_check(is_instance_valid(_local), "切枪后本地玩家仍有效")


# ── ⑦ 对手副本:权威说"空手"(丢光最后一把)→ 手上不能还举着 ──
# 快照的 `weapon` 变 0 只有一种成因:服务器侧玩家把**最后一把**丢出去。原实现写作
# `if slot > 0 and slot != ...` → 空手这一档被整个忽略,副本**一直举着那把已经不存在的枪**。
func _phase_replica_empty_hands() -> void:
	print("[gc] ── ⑦ 副本:权威空手 → 手上必须空 ──")
	var rep: Node2D = preload("res://scenes/player/player_replica.tscn").instantiate()
	_world.add_child(rep)
	for i in 3:
		await get_tree().physics_frame
	var anchor: Vector2 = _local.global_position
	var snap := {
		"pos": anchor + Vector2(200.0, 0.0), "vel": Vector2.ZERO, "facing": 1, "pose": 0,
		"hp": 100, "downed": false, "aim": Vector2.RIGHT, "weapon": 2,
	}
	rep.apply_snapshot(snap, anchor, 1)
	for i in 3:
		await get_tree().physics_frame
	_check(rep._weapon != null, "先握上一把(实际 %s)" % str(rep._weapon))
	_check(rep._weapon_slot_int == 2, "槽位记成 2(实际 %d)" % rep._weapon_slot_int)
	# 服务器说:他把最后一把丢出去了 → 空手
	snap["weapon"] = 0
	rep.apply_snapshot(snap, anchor, 2)
	for i in 3:
		await get_tree().physics_frame
	_check(rep._weapon == null,
			"权威空手后副本不得还举着枪(实际 %s)" % str(rep._weapon))
	_check(rep._weapon_slot_int == 0, "槽位回到 0(实际 %d)" % rep._weapon_slot_int)
	# 再握一把:同槽位之外的类型要能重建(证明 0 那一档没有把状态写坏)
	snap["weapon"] = 4
	rep.apply_snapshot(snap, anchor, 3)
	for i in 3:
		await get_tree().physics_frame
	_check(rep._weapon != null and rep._weapon_slot_int == 4,
			"空手之后仍能重建武器(实际 %s / 槽 %d)" % [str(rep._weapon), rep._weapon_slot_int])
	# ★ 收尾要**等它真的没**:`queue_free` 只是标记,探针末尾同帧就 `quit()` 的话,副本连同
	#   它手上那把武器都还活着 → 退出时报 "N ObjectDB instances / 1 RID leaked"(上一版实测)。
	rep.queue_free()
	for i in 2:
		await get_tree().physics_frame


func _take_inst() -> int:
	var v := _next_inst
	_next_inst += 1
	return v
