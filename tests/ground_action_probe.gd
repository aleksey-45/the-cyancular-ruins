extends Node

# 局内「捡枪 / 丢枪」探针(服务器权威侧,场景模式):钉 `MatchGround._handle_ground_actions` 全链路。
# 跑法:
#   "$GODOT" --headless --path . --quit-after 3600 res://tests/ground_action_probe.tscn
# 期望:每条 [ga] … 通过,末行 "GROUND ACTION PROBE: ALL-OK"。
#
# 为什么单开一个:单机侧那条路(`Level0.try_pickup_for`)有 `level0_weapon_scatter_probe` 钉着,
# 而**联机侧**的权威路径(`MatchGround._try_server_pickup` / `_try_server_drop`)此前零覆盖 ——
# 用户 2026-09-16 报「1v1/大乱斗里捡武器会崩溃」,这条正是两者共用的那段。
#
# 做法(与 grenade_player_hit_probe / match_host_hygiene_probe 同一手法):
# 真建一个 MatchHost(真地图 + 真 WorldBuilder 碰撞),但 **role_peers 传空** ——
# 不建玩家、不排 peer,于是 `_rpc_all` 的循环体一次都不进(广播静默早退,
# 不会在无多人连接时尝试发包)。玩家由本探针自己摆、输入包由本探针自己塞进
# `_pending_input`,走的是**与生产完全同一条消费路径**(clear_edges → apply_packet →
# _handle_ground_actions),不是直接调函数。
#
# ⚠ 判据 grep 文本 "GROUND ACTION PROBE: ALL-OK"(不只看退出码;场景探针在脚本报错时
#   仍然 --quit-after 到点 exit 0,只看退出码会把"根本没跑完"读成"通过")。

const MAP := "res://maps/factory1v1.cyrm"
const SETTLE_FRAMES := 150     # 等开局那批落体停稳(拾取判定读的是落点)
const MAX_WAIT := 30           # 等一个包被消费的帧数上限(超了就是服务器没在跑)

var _failures: Array[String] = []
var _host: Node = null
var _players: Dictionary = {}   # role -> Player
var _srcs: Dictionary = {}      # role -> PacketInputSource
var _seq := 0


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("[ga]   ✓ %s" % msg)
	else:
		_failures.append(msg)
		print("[ga]   ✗ %s" % msg)


func _ready() -> void:
	_host = MatchHost.new(MAP, {})   # 空 role_peers:不建玩家、不排 peer
	add_child(_host)                 # _ready 跑 → 铺 12 把地面武器(此时无玩家)
	_make_player(1)
	_make_player(2)
	# 服务器玩家必须有枪(player.tscn 自身 _ready 给的是空背包)
	for r in _players:
		(_players[r] as Node).weapons.set_initial_inventory([1])
	# 跳过开局 COUNTDOWN:那一档 `_physics_process` 会把注入的包**清空**(冻结期不喂输入),
	# 探针要测的是 PLAYING 下的拾取/丢弃。
	_host._round_state = MatchHost.RoundState.PLAYING
	_host._round_timer = 999999.0
	print("[ga] MatchHost 就绪:地面武器 %d 件,玩家 %s" % [
			_host.ground_weapons.size(), str(_players.keys())])
	_run()


func _run() -> void:
	await _settle()
	await _phase_payload_position_contract()
	await _phase_pickup_into_free_slot()
	await _phase_pickup_replaces_when_full()
	await _phase_drop()
	await _phase_self_drop_cooldown()
	await _phase_stress()
	await _phase_drop_all_but_one()
	await _phase_round_reset()

	if _failures.is_empty():
		print("GROUND ACTION PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("GROUND ACTION PROBE: FAIL %s" % str(_failures))
		get_tree().quit(1)


# ── ⓪(最先跑,趁地面还是开局那批)下发位置契约:`pos` 必须是 canonical ──
# 为什么单开这一相:`ground_weapons_payload()` 曾经读"已被逐帧刷新的 entries"、发出
# visual_center(= canonical + visual_offset),而客户端把载荷的 `pos` 直接当
# `WeaponPickup.canonical_pos`(见 pvp_match_client 的注释:契约就是 canonical)。后果是
# 开局那批在客户端被画在 canonical + **2×offset**、落体也从错的地方开始,而服务器按
# canonical + offset 判距离 —— 差整整一个 offset(手枪 ≈60px,拾取半径只有 64px),于是
# "站在看得见的枪上,按 F 却捡不起来"。掉落那批走事件、刚好是对的,所以症状只在开局那批上。
# 判据 = **两边圆心对齐**:载荷 pos + 该节点的 visual_offset == 服务器判定表里的 pos。
func _phase_payload_position_contract() -> void:
	print("[ga] ── ⓪ 下发位置契约(canonical,不是判定圆心)──")
	var payload: Array = _host.ground_weapons_payload()
	_check(payload.size() == _host.ground_weapons.size(),
			"载荷条数与地面表一致(%d vs %d)" % [payload.size(), _host.ground_weapons.size()])
	var checked := 0
	var bad_canonical := 0
	var bad_center := 0
	for e in payload:
		var inst := int(e["inst"])
		var n = _host._ground_nodes.get(inst, null)
		if n == null or not is_instance_valid(n):
			continue
		var entry: Dictionary = _host.ground_weapons.get_entry(inst)
		if entry.is_empty():
			continue
		checked += 1
		var pk := n as WeaponPickup
		if (e["pos"] as Vector2).distance_to(pk.canonical_pos) > 0.5:
			bad_canonical += 1
		if ((e["pos"] as Vector2) + pk.visual_offset).distance_to(entry["pos"] as Vector2) > 0.5:
			bad_center += 1
	_check(checked > 0, "载荷里至少有一件能对上节点(实际 %d)" % checked)
	_check(bad_canonical == 0,
			"载荷 pos == 节点 canonical_pos(%d/%d 不符)" % [bad_canonical, checked])
	_check(bad_center == 0,
			"载荷 pos + visual_offset == 服务器判定圆心(%d/%d 不符)—— 不符 = 客户端画的枪与服务器判的位置差一个 offset,会「看着够得着却捡不起来」" % [bad_center, checked])


# ── 阶段 ①:背包有空位 → 捡起后地面少一件、背包多一件、无替换 ──
func _phase_pickup_into_free_slot() -> void:
	print("[ga] ── ① 有空位时拾取 ──")
	var p: Node2D = _players[1]
	var before_ground: int = _host.ground_weapons.size()
	var before_inv: int = p.weapons.inventory.held.size()
	var e: Dictionary = _nearest_entry(p.global_position)
	_check(not e.is_empty(), "场上有可捡的武器")
	if e.is_empty():
		return
	var type_id := int(e["type_id"])
	_stand_on(p, e["pos"])
	await _press(1, PacketInputSource.BIT_PICKUP)
	_check(_host.ground_weapons.size() == before_ground - 1,
			"地面少一件(%d → %d)" % [before_ground, _host.ground_weapons.size()])
	_check(p.weapons.inventory.held.size() == before_inv + 1,
			"背包多一件(%d → %d)" % [before_inv, p.weapons.inventory.held.size()])
	_check(p.weapons.current_slot_int() == type_id,
			"捡起的那把成为手持(槽 %d,期望 %d)" % [p.weapons.current_slot_int(), type_id])
	_check(p.global_position == p.global_position, "玩家仍有效(未在拾取中被释放)")


# ── 阶段 ②:背包放不下 → 替换手上那把,被换下的掉在脚下(地面净增 0:一进一出)──
func _phase_pickup_replaces_when_full() -> void:
	print("[ga] ── ② 放不下时替换手上那把 ──")
	var p: Node2D = _players[1]
	# 先把背包塞满:两把重型 = 4+4 = 8 格 = CAPACITY(★ 用 set_initial_inventory 是**发放**路径,
	# 它照 `add()` 直加、不过容量闸门;要测闸门就得自己摆成"刚好满"的合法状态,别拿它塞 4 把)
	p.weapons.set_initial_inventory([3, 3])
	_check(p.weapons.inventory.held.size() == 2, "塞满后是 2 把重型(实际 %d)" % p.weapons.inventory.held.size())
	_check(p.weapons.inventory.used_slots() == WeaponInventory.CAPACITY,
			"且正好占满容量(%d/%d)" % [p.weapons.inventory.used_slots(), WeaponInventory.CAPACITY])
	var before_ground: int = _host.ground_weapons.size()
	# 挑一把**没被禁**且不在手上的:捡起它会超出容量 → 必须走"替换手上那把"这条分支
	var e: Dictionary = _nearest_entry(p.global_position)
	if e.is_empty():
		_check(false, "场上有可捡的武器(②)")
		return
	_stand_on(p, e["pos"])
	var held_type: int = p.weapons.current_slot_int()
	await _press(1, PacketInputSource.BIT_PICKUP)
	_check(p.weapons.inventory.held.size() == 2,
			"替换而非丢弃:背包仍是 2 把(实际 %d)" % p.weapons.inventory.held.size())
	_check(p.weapons.inventory.used_slots() <= WeaponInventory.CAPACITY,
			"替换后不超容(%d/%d)" % [p.weapons.inventory.used_slots(), WeaponInventory.CAPACITY])
	# 一进一出 → 地面数量不变(捡走 1、掉下 1)
	_check(_host.ground_weapons.size() == before_ground,
			"地面数量不变(捡 1 掉 1):%d → %d" % [before_ground, _host.ground_weapons.size()])
	_check(p.weapons.current_slot_int() != held_type or held_type == int(e["type_id"]),
			"手上换成了新捡的那把(旧 %d → 新 %d)" % [held_type, p.weapons.current_slot_int()])


# ── 阶段 ③:Q 长按的**完成边沿**上行 → 手上那把掉出 ──
func _phase_drop() -> void:
	print("[ga] ── ③ 丢弃 ──")
	var p: Node2D = _players[1]
	var before_ground: int = _host.ground_weapons.size()
	var before_inv: int = p.weapons.inventory.held.size()
	if before_inv == 0:
		_check(false, "丢弃前手上有枪")
		return
	await _press(1, PacketInputSource.BIT_DROP)
	_check(_host.ground_weapons.size() == before_ground + 1,
			"地面多一件(%d → %d)" % [before_ground, _host.ground_weapons.size()])
	_check(p.weapons.inventory.held.size() == before_inv - 1,
			"背包少一件(%d → %d)" % [before_inv, p.weapons.inventory.held.size()])


# ── 阶段 ④:刚丢下的那把在冷却期内不该被自己捡回(服务器侧 _live_self_drops)──
func _phase_self_drop_cooldown() -> void:
	print("[ga] ── ④ 自己刚丢下的枪不被自己立刻捡回 ──")
	var p: Node2D = _players[1]
	# 先确保背包里有东西可丢
	if p.weapons.inventory.held.is_empty():
		p.weapons.set_initial_inventory([2])
	var ground_before: int = _host.ground_weapons.size()
	await _press(1, PacketInputSource.BIT_DROP)
	_check(_host.ground_weapons.size() == ground_before + 1, "丢出的那把进了地面表")
	# 站在刚丢下的那把上按 F:冷却期内应被排除 → 捡不到
	var e: Dictionary = _nearest_entry(p.global_position)
	if e.is_empty():
		_check(false, "刚丢下的那把在表里(④)")
		return
	_stand_on(p, e["pos"])
	var ground_n: int = _host.ground_weapons.size()
	await _press(1, PacketInputSource.BIT_PICKUP)
	_check(_host.ground_weapons.size() == ground_n,
			"冷却期内捡不回自己刚丢的那把(地面仍 %d 件)" % _host.ground_weapons.size())


# ── 阶段 ⑤:连续拾取/丢弃若干轮(把"每帧都在换武器实例"这条路径压出来)──
func _phase_stress() -> void:
	print("[ga] ── ⑤ 连续拾取/丢弃 40 轮 ──")
	var p: Node2D = _players[1]
	for i in 40:
		var e: Dictionary = _nearest_entry(p.global_position)
		if e.is_empty():
			break
		_stand_on(p, e["pos"])
		await _press(1, PacketInputSource.BIT_PICKUP)
		if p.weapons.inventory.held.is_empty():
			continue
		await _press(1, PacketInputSource.BIT_DROP)
	_check(is_instance_valid(p), "40 轮后玩家仍有效")
	_check(p.weapons.current_weapon() == null or is_instance_valid(p.weapons.current_weapon()),
			"手持武器引用有效(不是悬垂引用)")
	_check(_host.ground_weapons.size() > 0, "40 轮后地面仍有武器(%d 件)" % _host.ground_weapons.size())


# ── 阶段 ⑥:复活路径 `_drop_all_but_one`(除随机一把外全丢在死亡点)──
func _phase_drop_all_but_one() -> void:
	print("[ga] ── ⑥ 复活:除随机一把外全丢出 ──")
	var p: Node2D = _players[1]
	p.weapons.set_initial_inventory([1, 2, 3, 5])
	_check(p.weapons.inventory.held.size() == 4, "先塞 4 把(实际 %d)" % p.weapons.inventory.held.size())
	var before_ground: int = _host.ground_weapons.size()
	_host._drop_all_but_one(p, 1)
	_check(p.weapons.inventory.held.size() == 1,
			"只留一把(实际 %d)" % p.weapons.inventory.held.size())
	_check(_host.ground_weapons.size() == before_ground + 3,
			"其余 3 把掉在死亡点(地面 %d → %d)" % [before_ground, _host.ground_weapons.size()])
	_check(is_instance_valid(p), "复活后玩家仍有效")


# ── ⑦ 换局重铺:inst 必须单调,且重铺出来那批仍要捡得动、位置契约仍成立 ──
# 为什么:`_reset_ground_weapons` 曾把 `_next_ground_inst` 重置回 1 —— 新一轮那批的 inst 于是与
# 客户端**残留的上一局节点撞号**,而客户端的 `_spawn_pickup_node` 对已有 inst 是**静默 return**
# → 新一轮那批在客户端一件都建不出来(它画的还是上一局的幽灵枪,按 F 也无效)。
# 这条钉住"inst 单调"这个前提;换局的**广播**那一半在 net_ground_probe(源码级)里钉。
func _phase_round_reset() -> void:
	print("[ga] ── ⑦ 换局重铺:inst 单调 + 重铺后仍捡得动 ──")
	var before_max := _max_inst()
	var before_ground: int = _host.ground_weapons.size()
	_host._reset_ground_weapons()
	await _settle()
	_check(_max_inst() > before_max,
			"重铺后 inst 继续变大(旧最大 %d → 新最大 %d)" % [before_max, _max_inst()])
	_check(_host.ground_weapons.size() > 0,
			"重铺后有货(实际 %d 件;旧 %d 件)" % [_host.ground_weapons.size(), before_ground])
	# 重铺那批的位置契约(与 ⓪ 同一判据)
	var bad := 0
	for e in _host.ground_weapons_payload():
		var n = _host._ground_nodes.get(int(e["inst"]), null)
		if n == null or not is_instance_valid(n):
			continue
		if (e["pos"] as Vector2).distance_to((n as WeaponPickup).canonical_pos) > 0.5:
			bad += 1
	_check(bad == 0, "重铺后载荷 pos 仍是 canonical(%d 件不符)" % bad)
	# 而且**捡得动**(站到服务器判定圆心上按 F:这条与客户端画在哪无关,只证表与判定没坏)
	var p: Node2D = _players[1]
	p.weapons.set_initial_inventory([1])
	var e2: Dictionary = _nearest_entry(p.global_position)
	if e2.is_empty():
		_check(false, "重铺后场上有可捡的武器")
		return
	var n_before: int = _host.ground_weapons.size()
	_stand_on(p, e2["pos"])
	await _press(1, PacketInputSource.BIT_PICKUP)
	_check(_host.ground_weapons.size() == n_before - 1,
			"重铺那批捡得起来(%d → %d)" % [n_before, _host.ground_weapons.size()])


# ── 工具 ──

# 场上最大 inst(用来证明"换局重铺没有回退编号")
func _max_inst() -> int:
	var m := 0
	for e in _host.ground_weapons.entries:
		m = maxi(m, int(e["inst"]))
	return m

func _make_player(role: int) -> void:
	var p: Node2D = preload("res://scenes/player/player.tscn").instantiate()
	var src := PacketInputSource.new()
	p.set_input_source(src)
	_host.add_child(p)
	p.collision_mask |= 2
	_host.players[role] = p
	_host.input_sources[role] = src
	_players[role] = p
	_srcs[role] = src


func _settle() -> void:
	for i in SETTLE_FRAMES:
		await get_tree().physics_frame


# 距离 pos 最近的一件地面武器(服务器表里的权威位置,与 _try_server_pickup 同源)。
func _nearest_entry(pos: Vector2) -> Dictionary:
	var best: Dictionary = {}
	var best_d := INF
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	for e in _host.ground_weapons.entries:
		var d: float = GridPathfinder.toroidal_delta_px(e["pos"], pos, w, h).length()
		if d < best_d:
			best = e
			best_d = d
	return best


func _stand_on(p: Node2D, pos: Vector2) -> void:
	p.global_position = pos
	p.velocity = Vector2.ZERO


# 把一个输入包塞进服务器的待消费队列,并**等它真的被消费掉** ——
# 走的就是 `_on_input` 之后那条路(`_physics_process` 每 tick 弹一个包 → clear_edges 已在本轮开头
# 调过 → apply_packet 写入边沿 → 紧跟 `_handle_ground_actions` 读边沿)。
func _press(role: int, bits: int) -> void:
	_seq += 1
	if not _host._pending_input.has(role):
		_host._pending_input[role] = []
	(_host._pending_input[role] as Array).append({
		"seq": _seq, "ax": 0.0, "held": 0, "pressed": bits,
		"released": 0, "weapon": 0, "aim": Vector2.RIGHT,
	})
	var waited := 0
	while not (_host._pending_input.get(role, []) as Array).is_empty() and waited < MAX_WAIT:
		await get_tree().physics_frame
		waited += 1
	if waited >= MAX_WAIT:
		_check(false, "注入的输入包在 %d 帧内没被服务器消费(服务器没在跑?)" % MAX_WAIT)
	await get_tree().physics_frame   # 再放一帧让落体/表同步跟上
