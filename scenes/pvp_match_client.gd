class_name PvpMatchClient
extends Node2D


var state: ClientState = null
var ports: ClientPorts = null


func _ensure_context() -> void:
	if state == null:
		state = ClientState.new()
	if ports == null:
		ports = ClientPorts.new()
		ports.add_child = Callable(self, "add_child")
		ports.get_tree = Callable(self, "get_tree")
		ports.multiplayer = Callable(self, "_get_multiplayer")
		ports.apply_tint = Callable(self, "_apply_tint")
		ports.time_fx_rewind_off = Callable(self, "_time_fx_replica_rewind_off")
		ports.all_replicas = Callable(self, "_all_replicas")
		ports.build_result_payload = Callable(self, "_build_result_payload")
		ports.leave_scene = Callable(self, "_leave_to_main_menu")
		ports.set_status = Callable(self, "_set_status")
		ports.pull_resync = Callable(self, "_pull_resync")


func _get_multiplayer() -> MultiplayerAPI:
	return multiplayer


const LaserVisual := preload("res://core/present/laser_visual.gd")
const HitShape := preload("res://core/sim/hit_shape.gd")




var _replicas: Dictionary:
	get: return state._replicas
	set(value): state._replicas = value
var _replica_set: ReplicaSet = null


var _ping_acc := 0.0
# C2 客户端预测:见 core/prediction_rollback.gd 与 docs/eng/netcode-snapshots.md。

# 受击事件队列:网络回调跑在 idle 帧,而注入要重放(内部 move_and_slide)—— 物理帧外 move_and_slide 位移恒 0(实测),
# 故回调只入队,统一在下一个物理帧开头注入(反馈最多晚 1 帧 ≈16.7ms)。
var _pending_hit_events: Array = []
var _input_uplink: InputUplink = null


func _ensure_input_uplink() -> InputUplink:
	if _input_uplink == null:
		_input_uplink = InputUplink.new()
		_input_uplink.bind(state)
	return _input_uplink





var _pause_menu: PauseMenu = null
var _last_round_state: Dictionary = {}
var _countdown_round_seen := 0

const BODY_BASE_COLOR := UiFactory.C_TEAM_A


func _apply_tint(body: Node, color_override: Color) -> void:
	var canvas := body as CanvasItem
	if canvas == null:
		return
	canvas.modulate = Color(color_override.r / BODY_BASE_COLOR.r,
			color_override.g / BODY_BASE_COLOR.g,
			color_override.b / BODY_BASE_COLOR.b)

func _correct_local_spawn() -> void:
	if state._local == null or not state._round_locked:
		return
	var ts := GameParameters.TILE_SIZE
	state._local.global_position = Vector2(PvpSession.spawn.x * ts + ts / 2.0,
			PvpSession.spawn.y * ts + ts / 2.0)

	_settle_local_spawn(state._local)


func _boot_world() -> void:
	LoadingScreen.show_loading("正在构建世界…")
	CombatComponent.pvp_arena = true
	MazeGenerator.set_map_file(PvpSession.map_path)
	Level0.pvp_mode = true
	var level0: Node = load("res://scenes/level_0.tscn").instantiate()
	add_child(level0)
	state._level0 = level0
	state._world = level0.get_node("WorldViewport")
	var local: Node2D = state._world.get_node("Player")
	var ts := GameParameters.TILE_SIZE
	local.position = Vector2(PvpSession.spawn.x * ts + ts / 2.0, PvpSession.spawn.y * ts + ts / 2.0)
	_settle_local_spawn(local)
	# 玩家之间不互挡(2026-11-10 用户裁定):客户端与服务器都不给玩家叠「对手身体」那一位 ⇒ 本地玩家只撞地形,
	# 对手副本也不再有碰撞体(见 player_replica.gd 的零碰撞几何探针)。两边掩码一致,C2 才有同一个可走空间。
	state._local = local
	state._rollback = PredictionRollback.new()
	state._rollback.bind(state._local)
	# 环面尺寸:分歧判定要用它取最短向量,否则跨接缝那一帧客户端与服务器相差一整幅地图宽会被误判成分歧、白跑一次回滚(见 PredictionRollback._pos_dist)。
	state._rollback.map_px = Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	var pp := PostProcess.new()
	pp.world_viewport = level0.get_node("WorldViewport")
	add_child.call_deferred(pp)
	NetBus.local_snapshot_world.connect(_on_snapshot_world)
	NetBus.local_snapshot_own.connect(_on_snapshot_own)
	NetBus.local_bullet_spawn.connect(_on_bullet_spawn)
	NetBus.local_beam_fired.connect(_on_beam_fired)
	NetBus.local_hit_event.connect(_on_hit_event)
	_subscribe_tile_events()
	NetBus.local_round_state.connect(_on_round_state)
	NetBus.local_kill_event.connect(_on_kill_event)
	NetBusExt.local_hit_confirm.connect(_on_hit_confirm)
	NetBus.local_match_sync.connect(_on_match_sync)
	_subscribe_ground_weapons()
	_subscribe_reconnect()
	# ★ 进场主动拉一次(昵称/角色色/生效选项/出生点/地面武器/destroyed):订阅齐了才开口要,故没有「推给一个正在切场景的客户端」那个竞态。
	# 本行之后的子类装配(HUD / 小地图 / 暂停菜单)不受影响:应答要走网络 poll,最早也在下一帧,本帧内不存在"应答比 HUD 先到"的窗口。
	if NetBus.can_send_to_server():
		NetBus.rpc_id(1, "match_sync")


func _settle_local_spawn(local: Node2D) -> void:
	var body := local as CharacterBody2D
	if body == null:
		return
	var g: float = float(local.get("gravity"))
	if g <= 0.0:
		return
	for _i in 8:
		if body.is_on_floor():
			return
		body.velocity.y += g * (1.0 / 60.0)
		body.move_and_slide()


func _on_hit_confirm(shooter_role: int, victim_role: int) -> void:
	if shooter_role == PvpSession.role:
		CombatFeedback.hit_marker()

func _enter_tree() -> void:
	_ensure_context()
	NetBusExt.local_explosion.connect(_on_network_explosion)


func _on_network_explosion(pos: Vector2, shooter_role: int, visual_path: String) -> void:
	if state._world == null or state._local == null:
		return
	var p := MazeGenerator.anchor_to_nearest(pos, state._local.global_position,
			float(GameParameters.MAP_WIDTH), float(GameParameters.MAP_HEIGHT))
	var shooter := _replica_for(shooter_role)
	var want: Node = shooter if shooter != null else (state._local if shooter_role == PvpSession.role else null)
	if want != null:
		var best: BulletBase = null
		var best_d := INF
		for n in get_tree().get_nodes_in_group("bullet"):
			var b := n as BulletBase
			if b == null or not b.explodes or b.apply_damage or b.shooter != want:
				continue
			var d := b.global_position.distance_to(p)
			if d < best_d:
				best_d = d
				best = b
		if best != null:
			best.despawn()
		elif shooter_role == PvpSession.role:
			return
	if visual_path == "":
		return
	var scene: PackedScene = load(visual_path)
	if scene == null:
		return
	var fx: Node2D = scene.instantiate() as Node2D
	if fx == null:
		return
	state._world.add_child(fx)
	fx.global_position = p


func _apply_match_options(opts: Dictionary) -> void:
	var disabled: Array[int] = []
	for v in opts.get("disabled_weapons", []):
		disabled.append(int(v))
	if state._local != null:
		state._local.weapons.set_enabled_types(disabled)

func _on_snapshot_own(own: Dictionary) -> void:
	if state._rollback == null:
		return
	var ack := int(own.get("ack_seq", 0))
	if not _ensure_input_uplink().accept_ack(ack):
		return
	var c2: Dictionary = own.get("c2", {})
	if not c2.is_empty():
		state._rollback.on_authoritative(ack, c2)


var _time_mirror: GrainAccount = null
var _time_watch: WatchHud = null
var _time_rewinding := false
var _haste_dim_t := 0.0
var _time_film_t := 0.0
var _time_mat: ShaderMaterial = null
var _time_sym: Label = null



func _setup_beta_time_hud() -> void:
	NetBusExt.local_time_state.connect(_on_time_state)


func _on_time_state(payload: Dictionary) -> void:
	var m: Dictionary = payload.get(PvpSession.role, {})
	if m.is_empty():
		return
	state._time_haste_mult = float(m.get("m", 3.0))
	if _time_mirror == null:
		_time_mirror = GrainAccount.new()
		Level0.grain_account = _time_mirror
		if _time_watch == null:
			_time_watch = WatchHud.new()
			_time_watch.position = Vector2(24.0, 124.0)
			add_child(_time_watch)
		else:
			_time_watch.visible = true
	_time_mirror.cap = float(m.get("cap", 1800.0))
	_time_mirror.window = float(m.get("win", 250.0))
	_time_mirror.balance = float(m.get("b", 0.0))
	_time_mirror.short_used = float(m.get("w", 0.0))
	_time_mirror.loan_used = float(m.get("l", 0.0))
	_time_mirror.locked = bool(m.get("k", false))


func _tick_beta_time(delta: float) -> void:
	if not PvpSession.beta_mode or state._local == null:
		return
	var on := Input.is_action_pressed("haste") 			and _time_mirror != null and _time_mirror.can_spend()
	# ★ 这里从前是 (_local as Node2D).set("pvp_haste_mult", …) 字符串反射,现改点访问:玩家根没有 class_name,但 _local 的静态类型是 Node2D ⇒ 点访问可用,拼错成员名当场报错,不再静默。
	state._local.pvp_haste_mult = state._time_haste_mult if on else 1.0
	_haste_dim_t = clampf(_haste_dim_t + (delta / 0.1 if on else -delta / 0.1), 0.0, 1.0)
	var pp := get_tree().get_first_node_in_group("post_process") as PostProcess
	if pp != null and _haste_dim_t > 0.001:
		pp.set_time_effects(0.0, 0.0, _haste_dim_t)
	_tick_beta_rewind(delta)
	_tick_time_fx(delta, on)


func _tick_beta_rewind(delta: float) -> void:
	var downed: bool = state._local.is_downed()
	var want := Input.is_action_pressed("rewind") 			and _time_mirror != null and _time_mirror.can_spend() and not downed
	if want and not _time_rewinding:
		_time_rewinding = true
		var src: PlayerInput = state._local.input_source
		if src != null:
			src.frozen = true
		(state._local as Node).set_meta("time_rewinding", true)
	elif not want and _time_rewinding:
		_time_rewinding = false
		var src2: PlayerInput = state._local.input_source
		if src2 != null:
			src2.frozen = false
		if (state._local as Node).has_meta("time_rewinding"):
			(state._local as Node).remove_meta("time_rewinding")
	_time_film_t = clampf(_time_film_t + (delta / 0.2 if _time_rewinding else -delta / 0.1), 0.0, 1.0)
	_apply_own_film(_time_film_t)
	if _time_sym != null:
		_time_sym.visible = _time_film_t > 0.05
	if _time_rewinding and _time_sym == null:
		_time_sym = UiFactory.label("◁ ◁", 48, Color(0.85, 0.9, 0.95))
		_time_sym.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
		_time_sym.offset_top = 60.0
		_time_sym.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_time_sym)


func _apply_own_film(coverage: float) -> void:
	var targets := _film_targets()
	if coverage <= 0.001:
		if _time_mat != null:
			for n in targets:
				if is_instance_valid(n) and (n as CanvasItem).material == _time_mat:
					(n as CanvasItem).material = null
			_time_mat = null
		return
	if _time_mat == null:
		_time_mat = ShaderMaterial.new()
		_time_mat.shader = load("res://scenes/effects/time_film.gdshader")
	_time_mat.set_shader_parameter("coverage", coverage)
	for n in targets:
		if is_instance_valid(n):
			(n as CanvasItem).material = _time_mat


func _film_targets() -> Array:
	var out: Array = []
	for n in [Level0.wall_layer, Level0.water_surface_layer, state._local]:
		if n != null and is_instance_valid(n):
			out.append(n)
	return out


var _time_fx: TimeFx = null


func _ensure_time_fx() -> TimeFx:
	if _time_fx == null:
		_time_fx = TimeFx.new()
		_time_fx.bind(state, ports)
	return _time_fx


func _tick_time_fx(delta: float, self_hasting: bool) -> void:
	# 双侧视效(节拍与单机同源:残影 0.03s / 红蓝交替;他人的红蓝重影 0.06s 一对)。
	_ensure_time_fx().tick(delta, self_hasting)


func _time_fx_replica_rewind_off(rep: Node2D) -> void:
	_ensure_time_fx().detach(rep)


func _all_replicas() -> Array:
	return _replicas.values()


func _replica_for(role: int) -> Node2D:
	var r = _replicas.get(int(role))
	return r if r is Node2D else null


func _on_snapshot_world(snap: Dictionary) -> void:
	_replica_set.apply_world_snapshot(snap)


func _apply_peer_names(names: Dictionary) -> void:
	state._names = names
	_replica_set.ensure_label(PvpSession.role)
	_replica_set.refresh_labels()


# 头部 ID / 血条的跟随与上图都在 ReplicaSet;本场景只留调用(锚点偏移的单一来源 = WorldLabel)。
func _process(_delta: float) -> void:
	_replica_set.follow(WorldLabel.HEAD_OFFSET)


# ── 小地图:两个提供器的共同遍历 —— 一次过滤、一份顺序来源 ──
# ★ 为什么必须共用而不是各写一份 for:ui/minimap.gd 是按下标对应的,两个数组错位一格就是「队友点画成敌人色」—— 不报错、只误导人;而错位最容易发生在「某个副本已 queue_free、尚未从 _replicas 抹掉」那个窗口里。★ 顺序:_replicas 是 Dictionary(保插入序),两次调用之间没有任何写入 ⇒ 两边逐项同序。
func _minimap_entries() -> Array:
	var arr: Array = []
	for role in _replicas:
		var r = _replicas[role]
		if is_instance_valid(r):
			arr.append([int(role), (r as Node2D).global_position])
	return arr


func _minimap_others() -> Array:
	var arr: Array = []
	for e in _minimap_entries():
		arr.append(e[1])
	return arr


func _supports_k_suicide() -> bool:
	return false


func _unhandled_input(event: InputEvent) -> void:
	if not _supports_k_suicide():
		return
	if state._match_ended or state._local == null:
		return
	if not NetBus.can_send_to_server():
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and event.physical_keycode == KEY_K:
		NetBusExt.rpc_id(1, "suicide_request")


var _tile_sync: TileSync = null


func _ensure_tile_sync() -> TileSync:
	if _tile_sync == null:
		_tile_sync = TileSync.new()
		_tile_sync.bind(state, ports)
	return _tile_sync


func _subscribe_tile_events() -> void:
	_ensure_tile_sync().subscribe()


func _on_remote_tile_destroyed(cell: Vector2i, silent: bool = false) -> void:
	_ensure_tile_sync().on_cell(cell, silent)


func _on_remote_sub_destroyed(sub: Vector2i, silent: bool = false) -> void:
	_ensure_tile_sync().on_sub(sub, silent)

func _physics_process(delta: float) -> void:
	_tick_beta_time(delta)
	if state._local == null:
		return
	# 受击事件必须在物理帧里注入(见 _pending_hit_events 的注释):排在 note_post_step 之前,
	# 这样被注入刷新后的当前态就是本帧该记录的"上一 tick 整态"。
	_drain_hit_events()
	_ping_acc += delta
	if _ping_acc >= 0.5:
		_ping_acc = 0.0
		if NetBus.can_send_to_server():
			NetBus.send_ping()
	var uplink := _ensure_input_uplink()
	if uplink.have_prev_seq and state._rollback != null:
		state._rollback.note_post_step(uplink.prev_sent_seq, state._local.capture_state())
		state._rollback.reconcile()
	uplink.begin_tick()
	var src: PlayerInput = state._local.input_source
	# 位打包收在 PacketInputSource.pack_record(协议编码端的唯一来源;解码端本来就只有一份)。
	var aim: Vector2 = state._local.get_current_aim_dir()
	# st = 最近成功解码并应用的世界快照 tick(命中回放时间基准 + 增量基线);ct = 本帧客户端物理帧号(只落位)。
	var need_full := NetBus.snapshot_need_full()
	var rec := PacketInputSource.pack_record(src, uplink.seq, aim, state._last_snap_tick,
			Engine.get_physics_frames(), need_full)
	var switch_inst: int = state._local.weapons.take_uplink_switch(src.get_switch_index_pressed())
	if switch_inst > 0:
		rec["winst"] = switch_inst
	uplink.submit(rec, aim)
	uplink.take_packet()
	_tick_ground_weapons()
	_cull_bullet_contacts()
	uplink.netstat_tick(delta)


func _on_bullet_spawn(data: Dictionary) -> void:
	if state._world == null:
		return
	var b := _take_visual_bullet(String(data["scene"]))
	if b == null:
		return
	b.setup(data["vel"].normalized(), data["speed"], data["range"], data["size"], data["color"], null)
	b.gravity_factor = data["gravity"]
	b.hit_damage = data["hit_damage"]
	b.hit_impact = data["hit_impact"]
	b.apply_damage = false
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
	state._world.add_child(b)
	b.shooter = _replica_for(int(data.get("shooter_role", 0)))


func _take_visual_bullet(scene_path: String) -> BulletBase:
	var b: BulletBase = BulletPool.shared().acquire(scene_path)
	if b != null:
		return b
	var scene: PackedScene = load(scene_path) as PackedScene
	if scene == null:
		return null
	return scene.instantiate() as BulletBase


var _contact_targets: Array = []
var _contact_targets_frame := -1


func _contact_targets_now() -> Array:
	var f := Engine.get_physics_frames()
	if f != _contact_targets_frame:
		_contact_targets_frame = f
		_contact_targets.clear()
		var tree := get_tree()
		if tree != null:
			for group in BulletBase.CONTACT_GROUPS:
				for n in tree.get_nodes_in_group(group):
					if n is Node2D:
						_contact_targets.append(n)
	return _contact_targets


func _cull_bullet_contacts() -> void:
	for n in get_tree().get_nodes_in_group("bullet"):
		var b := n as BulletBase
		if b == null or b.apply_damage or b.explodes:
			continue
		if _bullet_contact_target(b) != null:
			b.despawn()


func _bullet_contact_target(b: BulletBase) -> Node2D:
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	for n in _contact_targets_now():
		if n == b.shooter or not (n is Node2D):
			continue
		if not _bullet_hits_entity(b, n as Node2D):
			continue
		if not HitShape.hurtable(n):
			continue
		if HitShape.segment_hits_rect(b.prev_pos, b.global_position,
				_bullet_hurt_rect(n as Node2D), w, h, b.hit_grow()) >= 0.0:
			return n as Node2D
	return null


func _bullet_hurt_rect(n: Node2D) -> Rect2:
	if n.has_method("hurt_rect_rendered"):
		return n.hurt_rect_rendered()
	if n.has_method("hurt_rect"):
		return n.hurt_rect()
	return HitShape.hurt_rect_of(n)


# 这颗视觉子弹能不能停在那个实体上。默认能(1v1 / 大乱斗:除了射手谁都能挡);3v3 覆写:与射手同队的排掉(规则:队友不互挡 + 子弹穿透队友)—— 不覆写的话队友副本会把自己的子弹吃掉(与服务器裁决相反,且不报错)。
func _bullet_hits_entity(_b: BulletBase, _ent: Node2D) -> bool:
	return true


func _on_round_state(data: Dictionary) -> void:
	_last_round_state = data
	var rs := int(data.get("state", 0))
	state._round_locked = rs == 0
	_refresh_input_lock()
	var round := int(data.get("round", 1))
	if rs == 0 and round > 1 and round != _countdown_round_seen:
		_countdown_round_seen = round
		_clear_bullets_for_new_round()
		_on_countdown_round()
	elif rs == 3 and _should_handle_match_over():
		_enter_match_over_state(data)
	_refresh_input_lock()


func _clear_bullets_for_new_round() -> void:
	for b in get_tree().get_nodes_in_group("bullet"):
		if is_instance_valid(b):
			(b as Node).queue_free()


func _on_countdown_round() -> void:
	if state._level0 != null and state._level0.has_method("reset_destructibles"):
		state._level0.reset_destructibles()


func _should_handle_match_over() -> bool:
	return true


func _enter_match_over_state(_data: Dictionary) -> void:
	state._match_ended = true
	if _pause_menu != null and is_instance_valid(_pause_menu):
		_pause_menu.queue_free()
		_pause_menu = null
	state._menu_open = false
	_show_result()


func _refresh_input_lock() -> void:
	if state._local != null and state._local.has_method("set_controls_locked"):
		state._local.set_controls_locked(state._round_locked or state._menu_open or state._match_ended)



var _result_screen: ResultScreen = null


func _ensure_result_screen() -> ResultScreen:
	if _result_screen == null:
		_result_screen = ResultScreen.new()
		_result_screen.bind(state, ports)
	return _result_screen


func _show_result() -> void:
	_ensure_result_screen().show()


func _leave_to_main_menu() -> void:
	if NetBus != null:
		NetBus.stop()
	if not is_inside_tree():
		return
	Level0.safe_change_scene(get_tree(), "res://scenes/main_menu.tscn")


func _build_result_payload() -> Dictionary:
	return {}




func _on_hit_event(victim_role: int, damage: int, source_pos: Vector2, seq: int) -> void:
	if state._local == null:
		return
	if victim_role == PvpSession.role:
		# 网络回调在 idle 帧:只入队,由 _drain_hit_events() 在下一个物理帧开头注入(帧外 move_and_slide 位移恒 0)。
		_pending_hit_events.append([source_pos, damage, seq])
		return
	var r := _replica_for(victim_role)
	if r != null and r.has_method("play_hit"):
		r.play_hit(source_pos)


func _on_kill_event(_killer: int, _victim: int) -> void:
	push_error("PvpMatchClient: 子类必须覆写 _on_kill_event")


func _drain_hit_events() -> void:
	if _pending_hit_events.is_empty():
		return
	var events: Array = _pending_hit_events
	_pending_hit_events = []
	for ev in events:
		_apply_local_hit_event(ev[0], int(ev[1]), int(ev[2]))


func _apply_local_hit_event(source_pos: Vector2, damage: int, seq: int) -> void:
	if state._rollback != null and state._rollback.apply_external_event(seq, func() -> void:
			state._local.take_hit(source_pos, damage, false, -1.0)) \
			== PredictionRollback.EventApply.APPLIED:
		return
	state._local.take_hit(source_pos, damage, false, -1.0, true)


func _on_beam_fired(data: Dictionary) -> void:
	if state._world == null:
		return
	var shooter := int(data.get("shooter_role", 0))
	if shooter == PvpSession.role:
		return
	var replica := _replica_for(shooter)
	if replica == null or not is_instance_valid(replica):
		return
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
	LaserVisual.spawn_muzzle_orb(state._world, pts[0], color, half_width, lifetime)
	LaserVisual.spawn_beam(state._world, pts, half_width, color, lifetime, int(data.get("style", 0)))


func _apply_role_colors() -> void:
	push_error("PvpMatchClient: 子类必须覆写 _apply_role_colors")


func _apply_peer_hues_or_team(_payload: Dictionary) -> void:
	_apply_role_colors()


func _on_match_sync(payload: Dictionary) -> void:
	var resync := _resync_pull_pending
	_resync_pull_pending = false
	var names: Dictionary = payload.get("names", {})
	if not names.is_empty():
		_apply_peer_names(names)
	_apply_peer_hues_or_team(payload)
	var opts: Dictionary = payload.get("options", {})
	if not opts.is_empty():
		_apply_match_options(opts)
	# 出生点校正只对进场那次做:那时 spawns[role] 与 PvpSession.spawn 确实同源(都由服务器同一次摆位产生),不一致就是 bug —— 留痕 + 以 sync 为准。
	var sp: Dictionary = payload.get("spawns", {})
	if not resync and sp.has(PvpSession.role):
		var want: Vector2i = sp[PvpSession.role]
		if want != PvpSession.spawn:
			push_warning("match_sync: 出生点与 match_start 不一致(%s vs %s),以 sync 为准" % [
					str(PvpSession.spawn), str(want)])
			PvpSession.spawn = want
			_correct_local_spawn()
	# 地面武器开局那批随本条拉取一并到达(不走 weapon_spawned 推送 —— 推送会撞上"客户端正在帧末切场景 → 订阅方还不存在 → 静默丢失")。★ 先清后灌:载荷是全量,本地可能还留着掉线前的条目,不清会产生幽灵枪。
	var gw: Array = payload.get("ground_weapons", [])
	_clear_ground_weapons()
	for e in gw:
		if e is Dictionary:
			_spawn_pickup_node(e)
	if resync and state._level0 != null and state._level0.has_method("reset_destructibles"):
		state._level0.reset_destructibles()
	elif resync:
		# ★ 该还原而没还原 —— 留一条告警:_level0 是由子类赋值的共享状态字段(三个子类各自 _ready 里写),漏赋值 / 赋错类型时上面那道闸静默不成立,症状(幻影空洞拖到下一个回合边界)与"根本没写这段"逐字相同。
		var why := ("state._level0 为 null(子类 _ready 漏赋值?)" if state._level0 == null
				else "state._level0 没有 reset_destructibles()(类型不对?)")
		push_warning("match_sync(补态): 世界未还原 —— %s;幻影空洞不会填回" % why)
	# 掉线窗口内被拆的墙(以及"换局还原"之后本局重新拆的那些):重连后补回(进场那次该字段为空)。★ 复用 _on_remote_tile_destroyed 的静默形态,不另写一套清瓦片 / 清碰撞的逻辑。
	var destroyed: Array = payload.get("destroyed", [])
	for c in destroyed:
		if c is Vector2i:
			_on_remote_tile_destroyed(c, true)
	var destroyed_subs: Array = payload.get("destroyed_subs", [])
	for s in destroyed_subs:
		if s is Vector2i:
			_on_remote_sub_destroyed(s, true)


var _pickup_sync: PickupSync = null


func _ensure_pickup_sync() -> PickupSync:
	if _pickup_sync == null:
		_pickup_sync = PickupSync.new()
		_pickup_sync.bind(state, ports)
	return _pickup_sync


func _subscribe_ground_weapons() -> void:
	_ensure_pickup_sync().subscribe()


func _spawn_pickup_node(data: Dictionary) -> void:
	_ensure_pickup_sync().on_spawned(data)


func _clear_ground_weapons() -> void:
	_ensure_pickup_sync().clear()


func _remove_pickup_node(inst: int) -> void:
	_ensure_pickup_sync().remove(inst)


func _tick_ground_weapons() -> void:
	_ensure_pickup_sync().tick()


var _reconnect_driver: ReconnectDriver = null
var _resync_pull_pending := false

# ── 本地状态横幅── ★ 它只有一个数据源:本类的 _set_status()(由 ReconnectDriver 的四个转折点驱动:begin / retry_tick / resumed / cancel|abort)。
# ★ 它由 _subscribe_reconnect() 里建(三个子类都已经在各自 _ready 里调它)⇒ 不加新调用点,也就不存在"某个模式漏调 ⇒ 那个模式静默没有提示"这一档。
var _banner: StatusBanner = null


func _ensure_reconnect_driver() -> ReconnectDriver:
	if _reconnect_driver == null:
		_reconnect_driver = ReconnectDriver.new()
		_reconnect_driver.bind(state, ports)
	return _reconnect_driver


func _subscribe_reconnect() -> void:
	_ensure_reconnect_driver().subscribe()
	_setup_status_banner()


func _setup_status_banner() -> void:
	if _banner != null:
		return
	_banner = preload("res://ui/hud/status_banner.tscn").instantiate() as StatusBanner
	add_child(_banner)


func _set_status(text: String) -> void:
	if _banner != null:
		_banner.set_text(text)


func _pull_resync() -> void:
	# ★ 必须重置:worker 在 reclaim 时把 _ack_seq[role] 归 0 重协商锚点,而客户端这边的 _acked 还停在断线前那个数 —— 不重置的话新快照的 ack 一律 <= _acked,on_authoritative 全数丢弃(C2 静默失效,要等 seq 重新爬过那个数才恢复),同时环里断线前的记录会被当成未确认输入重放,与服务器的新锚点错位。
	_ensure_input_uplink().reset_epoch()
	_pending_hit_events.clear()
	state._rollback = PredictionRollback.new()
	state._rollback.bind(state._local)
	state._rollback.map_px = Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	state._rollback.ticks_per_record = PacketInputSource.TICKS_PER_RECORD
	NetBus.reset_snapshot_state()
	state._last_snap_tick = 0
	# ★ 路径甲(局内自动重连)原来不需要 match_sync —— 场景没重建、本地世界还在;现在需要了:世界在掉线那 GraceWindow.DEFAULT_SECONDS 秒里变过。
	# ★ 顺序:上面已经把 C2 重置完了(新 rollback / seq=0),再拉。★ 别把这一行删掉:它不在"进场建态"那条老路上,漏了不报错,只是世界悄悄不一致。
	if NetBus.can_send_to_server():
		_resync_pull_pending = true
		NetBus.rpc_id(1, "match_sync")


func _recheck_disconnect() -> void:
	_ensure_reconnect_driver().recheck_disconnect()


func _cancel_reconnect() -> void:
	_ensure_reconnect_driver().cancel()


# 场景离开(ESC / MATCH_OVER / 对手离开 / 进程退出)→ 停掉正在跑的重连(ReconnectDriver.on_exit_tree 的委托;
# "为什么必须有 / 为什么只在真在重连时断连"随组件走)。★ 这是引擎回调,名字不能改。
func _exit_tree() -> void:
	if _reconnect_driver != null:
		_reconnect_driver.on_exit_tree()
