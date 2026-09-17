class_name PvpMatchClient
extends Node2D

# PvP 对局客户端的**共享基类**(1v1 `pvp_client` / 大乱斗 `royale_game` 都 extends 它)。
#
# ★ 为什么:两个客户端本是一份代码按「对手 1 个 / N 个」叉开的,叉开时**复制**了整份实现 ——
#   于是同一处修正要改两遍,漏一处**不报错**(表现是"1v1 里好了、大乱斗里没变",或反过来)。
#   2026-09-14 收口:凡是两个模式**语义相同**的都上提到这里;子类只留真正的差异。
#
# ★ 判据是"剔掉注释后的代码是否逐字相同"(不是"看起来像")。本步上提的 7 个函数**代码逐字相同**,
#   合计 58 行,其中 `_physics_process` 是 C2 循环的心脏(3.1 把组包收进 pack_record 之后两份就
#   一模一样了)。
#
# ★ **子类保留的差异**(刻意不在这里):
#   · 对手副本是 1 个固定(`_remote_replica`)还是 N 个按 role 动态(`_replicas`)—— 这决定了
#     `_process` / `_on_snapshot_world` / `_on_round_state` / `_apply_peer_hues` 等的形状;
#   · HUD 类(`PvpHud` vs `RoyaleHud`)、退场是否额外锁 `_match_ended`、`_unhandled_input` 的自杀键;
#   · `_ready`(差异最大,各建各的世界/副本/HUD)。
#   要再上提一批,先按同样的口径量一遍差异(剔注释后逐行 diff),别凭印象搬。

const TileHitFx := preload("res://scenes/effects/tile_hit_fx.gd")
const LaserVisual := preload("res://core/present/laser_visual.gd")   # 远端光束视觉副本(与本地激光同款)

# ── 共享状态(两个模式同名同义;子类不要再声明一次)──
var _local: Node2D = null
var _world: Node = null   # WorldViewport(视觉子弹/TileHitFx 副本挂这里)
var _round_locked := false      # COUNTDOWN 冻结态(别把倒计时里提前解锁)
var _ping_acc := 0.0
# C2 客户端预测:见 core/prediction_rollback.gd 与 docs/pvp-c2-retrospective.md
var _rollback = null            # PredictionRollback
var _input_seq := 0             # 本地每物理帧单调的输入序号(服务器 1/tick 消费并回带 ack)
var _have_prev_seq := false
var _prev_sent_seq := 0
# MATCH_OVER 之后回菜单途中:忽略对手断线播报;也让输入锁把它算作一维(见 _refresh_input_lock)。
# 1v1 里它只在 MATCH_OVER 那一刻置 true;大乱斗同。
var _match_ended := false
# 暂停菜单是否开着(PvP 下菜单不暂停树,靠它锁本地输入;见 _refresh_input_lock)
var _menu_open := false

func _apply_tint(body: Node, hue_deg: float) -> void:
	var canvas := body as CanvasItem
	if canvas == null or is_zero_approx(hue_deg):
		return
	var mat := ShaderMaterial.new()
	mat.shader = load("res://scenes/player/player_p2_hue.gdshader")
	mat.set_shader_parameter("hue_shift", hue_deg)
	canvas.material = mat

func _correct_local_spawn() -> void:
	if _local == null or not _round_locked:
		return
	var ts := GameParameters.TILE_SIZE
	_local.global_position = Vector2(PvpSession.spawn.x * ts + ts / 2.0,
			PvpSession.spawn.y * ts + ts / 2.0)

func _on_hit_confirm(shooter_role: int, _victim_role: int) -> void:
	if shooter_role == PvpSession.role:
		CombatFeedback.hit_marker()

func _apply_match_options(opts: Dictionary) -> void:
	var disabled: Array[int] = []
	for v in opts.get("disabled_weapons", []):
		disabled.append(int(v))
	if _local != null:
		_local.weapons.set_enabled_slots(disabled)

func _on_snapshot_own(own: Dictionary) -> void:
	if _rollback == null:
		return
	var c2: Dictionary = own.get("c2", {})
	if not c2.is_empty():
		_rollback.on_authoritative(int(own.get("ack_seq", 0)), c2)

func _on_remote_tile_destroyed(cell: Vector2i) -> void:
	if _world == null:
		TileDefs.damage_tile(cell, 999999, "explosion")
		return
	# 取被拆砖原纹理(决定碎片颜色:树叶绿/树干棕),再清砖
	var tex := 0
	var grid := MazeGenerator.current_grid
	if not grid.is_empty() and cell.y >= 0 and cell.y < grid.size():
		var row: Array = grid[cell.y]
		if cell.x >= 0 and cell.x < row.size():
			tex = MazeGenerator.texture_of(int(row[cell.x]))
	TileDefs.damage_tile(cell, 999999, "explosion")
	# PvP 拆砖是服务器权威、客户端不本地拆 → 这里补播碎片粒子(只播视觉,不影响权威)
	var ts := GameParameters.TILE_SIZE
	TileHitFx.spawn(_world, Vector2(cell.x * ts + ts * 0.5, cell.y * ts + ts * 0.5), tex)

func _physics_process(_delta: float) -> void:
	if _local == null:
		return
	# 周期测延迟(右下角 HUD)
	_ping_acc += _delta
	if _ping_acc >= 0.5:
		_ping_acc = 0.0
		if NetBus.can_send_to_server():
			NetBus.send_ping()
	# C2:玩家由引擎自步进(读真实 Input)。这里在它本帧步进前——先把上一 seq 的预测整态入 ring,
	# 再 reconcile 到期权威(分歧 → restore+重放重对齐)。顺序:先记预测态,reconcile 才比得上 ring[C]。
	if _rollback != null:
		if _have_prev_seq:
			_rollback.note_post_step(_prev_sent_seq, _local.capture_state())
			_rollback.reconcile()
	var src: PlayerInput = _local.input_source
	# 位打包收在 PacketInputSource.pack_record(协议**编码端**唯一来源;解码端本来就只有一份)。
	var aim: Vector2 = _local.get_current_aim_dir()
	_input_seq += 1
	var pkt := PacketInputSource.pack_record(src, _input_seq, aim)
	# 滚轮切枪:目标槽位随输入包上行(滚轮事件不在协议里,只本地切会被快照切回)
	var net_slot: int = _local.weapons.consume_net_slot()
	if net_slot > 0:
		pkt["weapon"] = net_slot
	# ★ 只有真发得出去时才发:离场的三条路(ESC / MATCH_OVER / 对手离开)都会先 `NetBus.stop()`,
	#   而本场景到帧末才被换掉 —— 中间这一两帧 `rpc_id` 会打引擎错误
	#   (`Trying to call an RPC while no multiplayer peer is active`),包本来也发不出去。
	#   预测与记账照常走完(seq 照增),只是不上行 —— 不影响 seq 的单调性。
	if NetBus.can_send_to_server():
		NetBus.rpc_id(1, "send_input", pkt)
	_prev_sent_seq = _input_seq
	_have_prev_seq = true
	if _rollback != null:
		_rollback.note_input(_input_seq, pkt)
	# 地面武器:锚点 + 落点同步 + F 提示(纯本地表现,不参与预测)
	_tick_ground_weapons()


func _on_bullet_spawn(data: Dictionary) -> void:
	if _world == null:
		return
	var scene: PackedScene = load(data["scene"])
	if scene == null:
		return
	var b: BulletBase = scene.instantiate()
	b.setup(data["vel"].normalized(), data["speed"], data["range"], data["size"], data["color"], null)
	b.gravity_factor = data["gravity"]
	b.hit_damage = data["hit_damage"]
	b.hit_impact = data["hit_impact"]
	b.apply_damage = false   # 视觉副本:不裁决伤害
	if data["explodes"]:
		b.explodes = true
		b.direct_hit_damage = data["direct_damage"]
		b.fuse_time = data["fuse"]
		b.hit_fuse_time = data["hit_fuse"]
		b.explosion_radius = data["radius"]
		b.explosion_damage = data["expl_damage"]
		b.explosion_knockback = data["expl_knock"]
		if data.has("visual"):
			b.explosion_visual = load(data["visual"])
	b.global_position = data["pos"]
	_world.add_child(b)
	# 敌方武器轨迹(设置开启时):轨迹线挂在视觉副本子弹上
	if Settings.pvp_show_trajectories:
		BulletTrail.attach(b, data["color"])


# 本地输入锁的单一口(三个维度:冻结期 / 菜单打开 / 结算后回菜单途中)。
# 2026-09-14 从两个子类合并:**大乱斗那版多一个 `_match_ended`** —— 合并后 1v1 也带上它。
# ★ 这是本步唯一的行为差异:1v1 在 MATCH_OVER 之后的那几秒里输入现在也被锁(此前没有)。
#   与 `_match_ended` 的语义一致(那段时间正在回菜单),且与大乱斗**同款** —— 属有意统一,不是顺手改。
func _refresh_input_lock() -> void:
	if _local != null and _local.has_method("set_controls_locked"):
		_local.set_controls_locked(_round_locked or _menu_open or _match_ended)


# ── 对手副本访问器:两个模式**唯一的结构性差异**就收在这一个口上 ──
# 1v1 只有固定那一个副本(`_remote_replica`),大乱斗按 role 动态建(`_replicas`)。下面那些
# 消费快照/事件的函数原先因此各写两份,现在都改问这个口 —— ★ 子类**必须覆写**。
# 语义:`role` 是**对手**的 role(不是自己的);没有对应副本(未建/已移除)时返回 null,
# 调用方一律判空(不返回 null 会被下游 `.global_position` 打成崩溃)。
func _replica_for(_role: int) -> Node2D:
	return null   # 基类无副本;两个子类各自实现


func _on_hit_event(victim_role: int, damage: int, source_pos: Vector2) -> void:
	if _local == null:
		return
	if victim_role == PvpSession.role:
		_local.take_hit(source_pos, damage, false, -1.0)
		return
	# 对手被打:让它的副本闪一下,射手看得见"打中了"
	var r := _replica_for(victim_role)
	if r != null and r.has_method("play_hit"):
		r.play_hit(source_pos)


# 服务器权威开火(即时光束武器,激光):对手端据此画光束视觉副本(不开物理子弹,
# 无 bullet_spawn 实体可跟)。原始 pts 在射手 canonical 系(可能隔整幅地图跨接缝)→
# 逐点锚到射手副本当前渲染位置(副本位置已由 player_replica 每帧归到本地玩家最近副本、
# 滞后 ~1 tick 无碍)。光束整条路径 ≤ bullet_range 远小于半图 → 逐点 anchor_to_nearest 会把
# 整条折线搬到可见副本、跨接缝连续。
# 只画对手那发:自己(射手)这发已由本地预测自画,再收服务器版会双光束。
func _on_beam_fired(data: Dictionary) -> void:
	if _world == null:
		return
	var shooter := int(data.get("shooter_role", 0))
	if shooter == PvpSession.role:
		return
	var replica := _replica_for(shooter)
	if replica == null or not is_instance_valid(replica):
		return   # 射手副本还没建(快照未到)→ 丢本发
	var raw: PackedVector2Array = data.get("pts", PackedVector2Array())
	if raw.is_empty():
		return
	var anchor: Vector2 = replica.global_position
	var w := GameParameters.MAP_WIDTH
	var h := GameParameters.MAP_HEIGHT
	var pts := PackedVector2Array()
	for p in raw:
		pts.append(MazeGenerator.anchor_to_nearest(p, anchor, w, h))
	var color: Color = data.get("color", Color(0.1, 0.35, 1.0, 1.0))
	var half_width := float(data.get("half_width", 2.0))
	var lifetime := float(data.get("lifetime", 0.25))
	LaserVisual.spawn_muzzle_orb(_world, pts[0], color, half_width, lifetime)
	LaserVisual.spawn_beam(_world, pts, half_width, color, lifetime, int(data.get("style", 0)))


# ── 子类**必须覆写**的两口:昵称表 / 角色色相 ──
# 判据同 `_replica_for` —— 形状随"对手 1 个 vs N 个"而定,故实现留在子类;
# `_on_match_sync` 要用它们,故在这里声明(否则基类调用未声明的函数 = 编译不过)。
func _apply_peer_names(_names: Dictionary) -> void:
	push_error("PvpMatchClient: 子类必须覆写 _apply_peer_names")


func _apply_peer_hues(_hues: Dictionary) -> void:
	push_error("PvpMatchClient: 子类必须覆写 _apply_peer_hues")


func _on_match_sync(payload: Dictionary) -> void:
	var names: Dictionary = payload.get("names", {})
	if not names.is_empty():
		_apply_peer_names(names)
	var hues: Dictionary = payload.get("hues", {})
	if not hues.is_empty():
		_apply_peer_hues(hues)
	var opts: Dictionary = payload.get("options", {})
	if not opts.is_empty():
		_apply_match_options(opts)
	var sp: Dictionary = payload.get("spawns", {})
	if sp.has(PvpSession.role):
		var want: Vector2i = sp[PvpSession.role]
		if want != PvpSession.spawn:
			# 不一致就是 bug(两者同源),别静默 —— 留痕后以 sync 为准
			push_warning("match_sync: 出生点与 match_start 不一致(%s vs %s),以 sync 为准" % [
					str(PvpSession.spawn), str(want)])
			PvpSession.spawn = want
			_correct_local_spawn()
	# 地面武器**开局那批随本条拉取一并到达**(不走 weapon_spawned 推送 —— 推送会撞上
	# "客户端正在帧末切场景 → 订阅方还不存在 → 静默丢失"那类事故,见 CoreNet 的注释)。
	var gw: Array = payload.get("ground_weapons", [])
	for e in gw:
		if e is Dictionary:
			_spawn_pickup_node(e)


# ── 地面武器(2026-09-15):服务器权威,本端只渲染 + 等事件(不做客户端预测)──
var ground_weapons := GroundWeaponField.new()
var _pickup_nodes: Dictionary = {}    # inst -> WeaponPickup
var _self_drop_until: Dictionary = {} # inst -> 解禁时刻(ms):**自己刚丢下**的那把,
                                      # 冷却期内不提示(与服务器 _live_self_drops 同口径;
                                      # 不排的话刚丢下的枪会显示 F 却捡不起来)

const PICKUP_SCENE := preload("res://scenes/weapons/weapon_pickup.tscn")


# 订阅服务器的两条地面武器事件。
# ★ **必须走 NetBus**,不是 NetBusExt —— 后者里有同名遗留的 beam_fired,挂错节点的
#   表现是**静默 no-op**(对手的枪凭空消失/永不再现,且不报错)。两个子类各自 _ready 里调一次。
func _subscribe_ground_weapons() -> void:
	NetBus.local_weapon_spawned.connect(_on_weapon_spawned)
	NetBus.local_weapon_removed.connect(_on_weapon_removed)


func _on_weapon_spawned(data: Dictionary) -> void:
	_spawn_pickup_node(data)


func _on_weapon_removed(data: Dictionary) -> void:
	_remove_pickup_node(int(data.get("inst", 0)))


func _spawn_pickup_node(data: Dictionary) -> void:
	if _world == null:
		return
	var inst := int(data.get("inst", 0))
	if inst <= 0 or _pickup_nodes.has(inst):
		return
	var type_id := int(data.get("type_id", 1))
	var node: WeaponPickup = PICKUP_SCENE.instantiate()
	node.configure(type_id, inst, int(data.get("mag", 0)), data.get("vel", Vector2.ZERO))
	_world.add_child(node)
	# 权威位置与渲染位置分开(见 WeaponPickup 的字段注释):事件里的 pos 是 canonical。
	node.canonical_pos = data.get("pos", Vector2.ZERO)
	node.set_anchor((_local as Node2D).global_position if _local != null else Vector2.ZERO)
	node.sync_render_from_canonical()
	ground_weapons.map_size = Vector2(float(GameParameters.MAP_WIDTH), float(GameParameters.MAP_HEIGHT))
	ground_weapons.add({"inst": inst, "type_id": type_id, "mag": int(data.get("mag", 0)),
			"pos": node.canonical_pos, "vel": data.get("vel", Vector2.ZERO)})
	_pickup_nodes[inst] = node
	# 服务器告诉我们"这把是谁刚丢下的":若是**自己**,冷却期内不给提示(与它自己的判定一致)。
	if int(data.get("by_role", -1)) == int(PvpSession.role):
		_self_drop_until[inst] = Time.get_ticks_msec() 				+ int(PlayerParams.weapon_pickup_self_delay * 1000.0)


func _remove_pickup_node(inst: int) -> void:
	ground_weapons.remove(inst)
	var n = _pickup_nodes.get(inst, null)
	if n != null and is_instance_valid(n):
		n.queue_free()
	_pickup_nodes.erase(inst)
	_self_drop_until.erase(inst)


# 每帧:① 把锚点推给所有地面武器(接缝另一侧的枪要画在身边那一份上);
#        ② 把落体的实际位置同步回本地表(提示的"最近一把"要跟着落点走);
#        ③ 更新 F 提示。
func _tick_ground_weapons() -> void:
	if _local == null:
		return
	var lp: Vector2 = (_local as Node2D).global_position
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
	_update_pickup_prompt(lp)


# F 提示:贴到"**按 F 会捡到的那一把**"上方。★ 与服务器 `_try_server_pickup` 用同一个
# `nearest_within` + 同一个半径,否则会出现"提示了 A、服务器却捡了 B"。
# (客户端不预测,所以提示的语义是"服务器会同意的那一把"。)
# F 提示:**每把能捡的**各自一个(用户 2026-09-16「只要能捡起就会显示 F」)。
# 判据 = 在拾取半径内 + 该类型没被禁用。★ 客户端不知道服务器侧的"自己刚丢下"冷却
# (那条只有权威知道),所以刚丢下的那把会短暂显示提示但捡不起来 —— 已知的小缺口,
# 要消掉得让 `weapon_spawned` 带上 by_role。
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
		if _local != null and not _live_self_drops().has(int(inst)) 				and _local.weapons.is_slot_enabled(int(pk.type_id)):
			var d := GridPathfinder.toroidal_delta_px(pk.canonical_pos, lp, w, h).length()
			can = d <= PlayerParams.weapon_pickup_radius
		pk.set_prompt_visible(can)


# 仍在冷却期内的"自己刚丢下的" inst(与服务器 MatchGround._live_self_drops 同口径)。
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


# ── 断线重连(2026-09-17;spec §3.4 **路径甲**:局内自动重连)──
# 「与 worker 的连接闪断」→ 自己连回去、重新认领 role、重置本地 C2 —— **不切场景、不重建世界**。
# (路径乙"回大厅后回局、重建场景"是 spec §3.5,归下一阶段,不在本文件。)
#
# ★ 触发点只有"服务器断开"一条(`NetBus.local_server_message`,由 `multiplayer.server_disconnected`
#   驱动)。对局场景此前**没人订阅**它 —— 那条信号的消费者只有 `lobby_page`,所以服务器一断客户端
#   毫无反应:快照停更、输入自停(`_physics_process` 的 `can_send_to_server()` 转 false),玩家卡在
#   一个静止的世界里只能按 ESC 自救。这正是 spec §1.3 记的既有缺陷。
const RECONNECT_RETRY_MS := 2000   # 重试间隔
var _reconnecting := false
var _reconnect_started_ms := 0
var _reclaim_sent := false   # ★ **本条连接上**是否已发过 reclaim(判据见 _on_reconnect_retry_tick)
var _pending_disconnect := false   # 断线时菜单开着 → 记账,关菜单再来(见 _recheck_disconnect)


# 两个子类各自 `_ready` 里调一次(与 `_subscribe_ground_weapons()` 并列)。
func _subscribe_reconnect() -> void:
	NetBus.local_server_message.connect(_on_server_message)
	# ★ worker 在宽限期内接受 reclaim 后会**重发一条 match_start**(载荷与首次开局同源)。
	#   **实读确认**:对局里 `local_match_start` 此前**零订阅者** —— 它唯一的消费者是
	#   `lobby_page._on_match_start`(`matchmaking`/`royale_lobby` 的公共基类),而那个页面在对局
	#   场景里**不在树上** → 这条信号到对局里是**静默 no-op**。所以"重连成功"的收尾必须在这里接
	#   (`_on_match_start_event`)—— 不能指望既有入口。
	NetBus.local_match_start.connect(_on_match_start_event)


func _on_server_message(msg: String) -> void:
	if _match_ended or _reconnecting:
		return
	# 服务器文本播报也走这条信号,但对局期间服务器只发「对局开始」/「大乱斗开始」(已核);
	# 大厅那些「房间已满」之类不会到对局场景。
	if msg.contains("断开") or msg.contains("断开连接"):
		_pending_disconnect = true
		_begin_reconnect()


# 菜单关掉时补一次:真掉线正好落在"菜单开着"那段窗口里时,上面那次 `_begin_reconnect` 会被挡下
# (见它的守卫),账记在 `_pending_disconnect` 上,关菜单这一刻补上。不补的话玩家会留在一个
# 快照停更的静止世界里 —— 正是本功能要消掉的那个状态。
func _recheck_disconnect() -> void:
	if _pending_disconnect:
		_pending_disconnect = false
		_begin_reconnect()


# 局内自动重连:不切场景、不重建世界 —— 本地世界原样保留,只把连接接回去。
# ★ 这条路径下破坏态/地面武器/副本位置全都还在原地,所以**不需要** match_sync 的
#   `destroyed` 那一套(那是路径乙"回大厅后回局"才需要的,见 spec §3.5)。
func _begin_reconnect() -> void:
	# ★ MATCH_OVER / 对手离开那两条延时回菜单的路子会先 `NetBus.stop()`,而它断开的是我们自己。
	if _match_ended:
		return
	# ★ 菜单开着**先不动,但不是放弃**(放弃会把真掉线也一起漏掉):按 ESC →「回到主菜单」也走
	#   `NetBus.stop()`,此刻若接着重连,会在回主菜单的路上把连接接回 worker —— 本机/UDP 握手
	#   快于一帧,reclaim 会**成功**,于是人已经在大厅、worker 却认为这个 role 有人管(对手那边
	#   就此卡死,且全程无报错)。真"该重连"的那种断开由 `_recheck_disconnect` 在关菜单时补。
	#   (另一侧:`_exit_tree` 兜"重连已经在飞、玩家又按 ESC 走了"。)
	if _menu_open:
		return
	_pending_disconnect = false
	if PvpSession.token == "" or PvpSession.worker_port <= 0:
		_abort_reconnect("重连失败(无会话令牌)")   # 原版 worker / 老大厅 → 优雅降级
		return
	_reconnecting = true
	_reconnect_started_ms = Time.get_ticks_msec()
	print("[pvp] 连接断开,开始重连(role=%d port=%d)" % [PvpSession.role, PvpSession.worker_port])
	_retry_connect.call_deferred()


# 连一轮(先把上一轮拆干净)。★ 与 `lobby_page` 转连 worker 那一处同款:
# `start_client` 的地址/端口取自 `PvpSession`(大厅填好的,不重新走大厅)。
func _retry_connect() -> void:
	if not _reconnecting:
		return
	NetBus.stop()
	_reclaim_sent = false   # 新连接 = 新的一次 reclaim 额度(旧连接上那次的成败已无意义)
	var err := NetBus.start_client(PvpSession.server_address, PvpSession.worker_port)
	if err != OK:
		_schedule_reconnect_retry()
		return
	multiplayer.connected_to_server.connect(_try_reclaim, CONNECT_ONE_SHOT)
	multiplayer.connection_failed.connect(_on_reconnect_failed, CONNECT_ONE_SHOT)


func _on_reconnect_failed() -> void:
	_schedule_reconnect_retry()


func _try_reclaim() -> void:
	if not _reconnecting:
		return   # 期间已收场(超时/已离开) → 不发
	_reclaim_sent = true
	NetBusExt.rpc_id(1, "reclaim_role", PvpSession.role, PvpSession.token)
	# ★ 等 worker 回的 match_start(它带 spawn/map_path)。等到了才算成功,见 _on_resumed。
	_schedule_reconnect_retry()


# 重试节拍(单一定时器;每一拍自己判"再连一轮"还是"只等应答")。
func _schedule_reconnect_retry() -> void:
	if not _reconnecting:
		return
	get_tree().create_timer(RECONNECT_RETRY_MS / 1000.0).timeout.connect(_on_reconnect_retry_tick)


func _on_reconnect_retry_tick() -> void:
	if not _reconnecting:
		return
	# ★ 宽限期到了就别再试 —— 服务器那边的 `_expire_graces` 会把你移出,再连上去
	#   也会被 reclaim 拒(不该在宽限外偷偷续上)。
	if Time.get_ticks_msec() - _reconnect_started_ms > int(GraceWindow.DEFAULT_SECONDS * 1000.0):
		_abort_reconnect("重连超时,对局已结束")
		return
	# ★★ **同一个 role 只许发一次 reclaim**(本功能最易写错、且症状最怪的一处):
	#   worker 接受第一次时就 `_grace.leave(role)` 了,第二次进 `_on_reclaim` 的判据②
	#   ("该 role 必须在宽限期里")必不成立 → 它**踢连接**。表现是"刚重连上几秒又断",
	#   看着像网络抖动,实则是自己把自己踢了,而且因为 token 是对的,查 token 查不出问题。
	#   判据:这条连接**还活着**、且**已发过** reclaim → 该做的是**等**它的 match_start
	#   (可靠的定向应答,连着就一定到),而不是重连一轮再发一次。
	#   真发不出去(连接没了 / 被服务器踢了)`can_send_to_server()` 即为 false,自然走到下面重连。
	if _reclaim_sent and NetBus.can_send_to_server():
		_schedule_reconnect_retry()
		return
	_retry_connect()


# worker 接受 reclaim 后重发的那条 match_start 到达 → 重连成功。
func _on_match_start_event(_role: int, _spawn: Vector2i, _map_path: String) -> void:
	# 非重连态收到它 = 首次进场那一份(由 `lobby_page` 消费;本场景那时还没建出来)或异常来源,
	# 两种都**不动本地世界** —— 本路径不重建场景,故 role/spawn/map_path 一个都不回写
	# (`PvpSession.spawn` 在大乱斗里是"动态复活点"语义,回写只会让下一次 `_correct_local_spawn`
	#  把玩家瞬移走)。
	if not _reconnecting:
		return
	_on_resumed()


# 重置本地 C2 状态(spec §3.4 的 ★:不重置会把断线前的记录当"未确认输入"重放)。
func _on_resumed() -> void:
	_reconnecting = false
	_reconnect_started_ms = 0
	_reclaim_sent = false
	# ★ 必须重置:worker 在 reclaim 时把 `_ack_seq[role]` 归 0 重协商锚点,而客户端这边的 `_acked`
	#   还停在断线前那个数 —— 不重置的话新快照的 ack 一律 `<= _acked`,`on_authoritative` 全数丢弃
	#   (C2 静默失效,要等 seq 重新爬过断线前那个数才恢复),同时环里那些断线前的记录会被当成
	#   未确认输入重放,与服务器的新锚点错位。
	_input_seq = 0
	_have_prev_seq = false
	_prev_sent_seq = -1
	# ★ 新实例必须**重新 bind + 设 map_px**,照抄两个子类 `_ready` 里那三行。漏了**都不报错**:
	#   没 bind → `_handle_ack` 里 `_p == null` 直接 `_trim` 返回,分歧永不修复(静默失去 C2);
	#   没设 map_px → 跨接缝那一帧按裸距离比,白跑一次回滚(同 `_ready` 里那条注释)。
	_rollback = PredictionRollback.new()
	_rollback.bind(_local)
	_rollback.map_px = Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	print("[pvp] 重连成功")


func _abort_reconnect(reason: String) -> void:
	_reconnecting = false
	NetBus.stop()
	Level0.safe_change_scene(get_tree(), "res://scenes/main_menu.tscn")
	print("[pvp] %s" % reason)


# 场景离开(ESC / MATCH_OVER / 对手离开 / 进程退出)→ 停掉在飞的重连。
# ★ 必须有:`_reconnecting` 期间玩家仍可按 ESC 离场,不停的话重连循环会**从主菜单**继续跑,
#   连上还 reclaim 成功 → worker 认为这个 role 有人管(正是 `_begin_reconnect` 那道守卫要防的
#   同一个后果,只是入口在另一侧:那边防"开始时",这边防"开始后")。
# ★ 只在**真在重连**时断连:本函数跑在新场景 `_ready` **之后**(`safe_change_scene` 先 add 新场景
#   再摘旧场景),无条件 `NetBus.stop()` 会把新场景刚建起来的连接干掉。
func _exit_tree() -> void:
	if _reconnecting:
		_reconnecting = false
		NetBus.stop()
