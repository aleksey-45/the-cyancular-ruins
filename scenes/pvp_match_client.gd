class_name PvpMatchClient
extends Node2D

# 对战客户端共享基类，服务于 1v1 死斗、3v3 团队对抗以及多人大乱斗模式。
# 封装网络快照处理、客户端预测与回滚、地面武器同步、断线重连状态机、通用结算面板挂载以及外观染色处理。
# 子类根据模式特性重写对手副本管理、队伍阵营逻辑、计分面板与结算数据载荷。

const TileHitFx := preload("res://scenes/effects/tile_hit_fx.gd")
const LaserVisual := preload("res://core/present/laser_visual.gd")

# ── 共享状态 ──
var _local: Node2D = null
var _world: Node = null   # 世界视口节点，挂载子弹与破坏粒子副本
var _level0: Node = null  # 地图世界根节点，用于重置瓦片与碰撞
var _round_locked := false      # 倒计时阶段锁定控制
var _ping_acc := 0.0

# ── 客户端预测与回滚 ──
var _rollback = null            # PredictionRollback 控制器
var _input_seq := 0             # 本地单调递增输入序号
var _have_prev_seq := false
var _prev_sent_seq := 0

# ── 网络统计读数（--netstat 参数控制开启） ──
var _netstat := false
var _netstat_checked := false
var _netstat_acc := 0.0
var _netstat_prev_rb := 0
var _last_ack := 0
var _netstat_steps := 0

# ── 流程控制 ──
var _match_ended := false
var _menu_open := false
var _result: MatchResult = null
var _last_round_state: Dictionary = {}

# 角色精灵图基准主色，作为颜色调制算法的基准除数
const BODY_BASE_COLOR := UiFactory.C_TEAM_A


# 通用角色外观着色：仅修改角色精灵本体，不影响武器与准星。
# 若指定 color_override，使用比值调制精确匹配目标颜色；否则根据 hue_deg 应用色相旋转着色。
func _apply_tint(body: Node, hue_deg: float, color_override: Color = Color(0, 0, 0, 0)) -> void:
	var canvas := body as CanvasItem
	if canvas == null:
		return
	if color_override.a > 0.0:
		canvas.modulate = Color(color_override.r / BODY_BASE_COLOR.r,
				color_override.g / BODY_BASE_COLOR.g,
				color_override.b / BODY_BASE_COLOR.b)
		return
	if is_zero_approx(hue_deg):
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
		_local.weapons.set_enabled_types(disabled)

func _on_snapshot_own(own: Dictionary) -> void:
	if _rollback == null:
		return
	# 丢弃超过当前本地输入序号的过时或跨重协商周期的确认包
	var ack := int(own.get("ack_seq", 0))
	if ack > _input_seq:
		return
	_last_ack = ack
	var c2: Dictionary = own.get("c2", {})
	if not c2.is_empty():
		_rollback.on_authoritative(ack, c2)

# ── 时间控制系统（Beta 模式 HUD 镜像与视效） ──
var _time_mirror: GrainAccount = null
var _time_watch: WatchHud = null
var _time_rewinding := false
var _haste_dim_t := 0.0
var _time_film_t := 0.0
var _time_mat: ShaderMaterial = null
var _time_sym: Label = null
var _time_haste_mult := 3.0
var _fx_self_t := 0.0
var _fx_other_t := 0.0
const TIME_GLOW_SELF := Color(0.30, 0.62, 1.0)
const TIME_GLOW_OTHER := Color(1.0, 0.94, 0.86)

func _setup_beta_time_hud() -> void:
	if not PvpSession.beta_mode:
		return
	_time_watch = WatchHud.new()
	_time_watch.position = Vector2(24.0, 124.0)
	add_child(_time_watch)
	NetBusExt.local_time_state.connect(_on_time_state)


func _on_time_state(payload: Dictionary) -> void:
	var m: Dictionary = payload.get(PvpSession.role, {})
	if m.is_empty():
		return
	_time_haste_mult = float(m.get("m", 3.0))
	if _time_mirror == null:
		_time_mirror = GrainAccount.new()
		Level0.grain_account = _time_mirror
		if _time_watch != null:
			_time_watch.visible = true
	_time_mirror.cap = float(m.get("cap", 1800.0))
	_time_mirror.window = float(m.get("win", 250.0))
	_time_mirror.balance = float(m.get("b", 0.0))
	_time_mirror.short_used = float(m.get("w", 0.0))
	_time_mirror.loan_used = float(m.get("l", 0.0))
	_time_mirror.locked = bool(m.get("k", false))


# 本地预测时间加速手感与全屏压暗
func _tick_beta_time(delta: float) -> void:
	if not PvpSession.beta_mode or _local == null:
		return
	var on := Input.is_action_pressed("haste") \
			and _time_mirror != null and _time_mirror.can_spend()
	(_local as Node2D).set("pvp_haste_mult", _time_haste_mult if on else 1.0)
	_haste_dim_t = clampf(_haste_dim_t + (delta / 0.1 if on else -delta / 0.1), 0.0, 1.0)
	var pp := get_tree().get_first_node_in_group("post_process") as PostProcess
	if pp != null and (_haste_dim_t > 0.001 or pp != null):
		pp.set_time_effects(0.0, 0.0, _haste_dim_t)
	_tick_beta_rewind(delta)
	_tick_time_fx(delta, on)


# 本地回溯状态预测：锁定输入源并开启免伤与底片材质
func _tick_beta_rewind(delta: float) -> void:
	var downed: bool = (_local as Node).call("is_downed") if _local.has_method("is_downed") else false
	var want := Input.is_action_pressed("rewind") \
			and _time_mirror != null and _time_mirror.can_spend() and not downed
	if want and not _time_rewinding:
		_time_rewinding = true
		var src = (_local as Node).get("input_source")
		if src != null:
			src.set("frozen", true)
		(_local as Node).set_meta("time_rewinding", true)
	elif not want and _time_rewinding:
		_time_rewinding = false
		var src2 = (_local as Node).get("input_source")
		if src2 != null:
			src2.set("frozen", false)
		if (_local as Node).has_meta("time_rewinding"):
			(_local as Node).remove_meta("time_rewinding")
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


# 底片特效仅作用于世界图层与本地玩家
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
	for n in [Level0.wall_layer, Level0.water_layer, Level0.water_surface_layer, _local]:
		if n != null and is_instance_valid(n):
			out.append(n)
	return out


# 时间加速与回溯的视觉表现处理
func _tick_time_fx(delta: float, self_hasting: bool) -> void:
	if self_hasting:
		if TimeGlow.on(_local) == null:
			TimeGlow.attach(_local, TIME_GLOW_SELF)
		_fx_self_t -= delta
		if _fx_self_t <= 0.0:
			_fx_self_t = 0.03
			var anim: AnimatedSprite2D = _local.get("animator")
			if anim != null:
				var red := int(Time.get_ticks_msec() / 60) % 2 == 0
				AfterImage.spawn((_local as Node).get_parent(), anim,
						Color(1.0, 0.25, 0.25, 0.55) if red else Color(0.3, 0.4, 1.0, 0.55))
	else:
		var g := TimeGlow.on(_local)
		if g != null:
			g.queue_free()
	var any_hasting := false
	for rep_node in _all_replicas():
		if not is_instance_valid(rep_node) or not (rep_node is Node2D):
			continue
		var rep := rep_node as Node2D
		_time_fx_replica_rewind(rep, delta)
		if bool(rep.get_meta("rewind", false)):
			_time_fx_replica_off(rep)
			continue
		if not bool(rep.get_meta("haste", false)):
			_time_fx_replica_off(rep)
			continue
		any_hasting = true
		_time_fx_replica_on(rep)
	if not any_hasting:
		_fx_other_t = 0.0


func _time_fx_replica_off(rep: Node2D) -> void:
	var glow := TimeGlow.on(rep)
	if glow != null:
		glow.queue_free()
	var label := rep.get_node_or_null("HasteTag") as Label
	if label != null:
		label.visible = false


func _time_fx_replica_on(rep: Node2D) -> void:
	if TimeGlow.on(rep) == null:
		TimeGlow.attach(rep, TIME_GLOW_OTHER)
	var label := rep.get_node_or_null("HasteTag") as Label
	if label == null:
		label = UiFactory.label("▶▶ 3x", 16, Color(0.78, 0.55, 1.0))
		label.name = "HasteTag"
		label.position = Vector2(-26, -92)
		rep.add_child(label)
	label.text = "▶▶ %dx" % int(round(_time_haste_mult))
	label.visible = true
	_fx_other_t -= get_process_delta_time()
	if _fx_other_t <= 0.0:
		_fx_other_t = 0.06
		var anim := rep.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
		if anim != null:
			AfterImage.spawn(rep.get_parent(), anim, Color(1.0, 0.25, 0.25, 0.30))
			AfterImage.spawn(rep.get_parent(), anim, Color(0.3, 0.4, 1.0, 0.30))


# 远端副本回溯视效与轨迹残像
var _rw_film_mats: Dictionary = {}
var _rw_ghosts: Dictionary = {}

func _time_fx_replica_rewind(rep: Node2D, delta: float) -> void:
	if not bool(rep.get_meta("rewind", false)):
		_time_fx_replica_rewind_off(rep)
		return
	if not _rw_film_mats.has(rep):
		var m := ShaderMaterial.new()
		m.shader = load("res://scenes/effects/time_film.gdshader")
		m.set_shader_parameter("coverage", 1.0)
		rep.material = m
		_rw_film_mats[rep] = m
	var trail: Array = rep.get_meta("trail_last", [])
	var new_trail: Array = rep.get_meta("trail", [])
	if new_trail.size() > trail.size():
		var anim := rep.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
		if anim != null:
			for i in range(trail.size(), new_trail.size()):
				var pt: Array = new_trail[i]
				var ghost_host := Node2D.new()
				ghost_host.global_position = Vector2(float(pt[0]), float(pt[1]))
				rep.get_parent().add_child(ghost_host)
				AfterImage.spawn(ghost_host, anim, Color(0.82, 0.88, 0.92, 0.35))
				var ghosts: Array = _rw_ghosts.get(rep, [])
				ghosts.append({"node": ghost_host, "t": 0.0})
				_rw_ghosts[rep] = ghosts
	rep.set_meta("trail_last", new_trail.duplicate())
	var ghosts2: Array = _rw_ghosts.get(rep, [])
	for g in ghosts2:
		g["t"] = float(g["t"]) + delta
		var host: Node2D = g["node"]
		if is_instance_valid(host) and host.get_child_count() > 0:
			var spr := host.get_child(0) as Sprite2D
			if spr != null:
				spr.modulate.a = clampf(0.35 * (1.0 - float(g["t"])), 0.0, 1.0)
	var alive: Array = []
	for g in ghosts2:
		if float(g["t"]) < 1.0 and is_instance_valid(g["node"]):
			alive.append(g)
	_rw_ghosts[rep] = alive


func _time_fx_replica_rewind_off(rep: Node2D) -> void:
	if _rw_film_mats.has(rep):
		if is_instance_valid(rep) and rep.material == _rw_film_mats[rep]:
			rep.material = null
		_rw_film_mats.erase(rep)
	if _rw_ghosts.has(rep):
		for g in _rw_ghosts[rep]:
			if is_instance_valid(g["node"]):
				(g["node"] as Node).queue_free()
		_rw_ghosts.erase(rep)
	if rep.has_meta("trail_last"):
		rep.remove_meta("trail_last")


func _all_replicas() -> Array:
	return []


# 处理瓦片破坏网络事件，展开为 16px 子格破坏并触发碎片粒子
func _on_remote_tile_destroyed(cell: Vector2i, silent: bool = false) -> void:
	for sy in 4:
		for sx in 4:
			_on_remote_sub_destroyed(Vector2i(cell.x * 4 + sx, cell.y * 4 + sy), silent)
	if silent or _world == null:
		return
	var tex := 0
	var sgrid := MazeGenerator.current_subgrid
	if not sgrid.is_empty() and cell.y * 4 < sgrid.size():
		var srow: Array = sgrid[cell.y * 4]
		if cell.x * 4 < srow.size():
			tex = int(srow[cell.x * 4])
	var ts := GameParameters.TILE_SIZE
	TileHitFx.spawn(_world, Vector2(cell.x * ts + ts * 0.5, cell.y * ts + ts * 0.5), tex)


# 处理单个 16px 子格破坏网络事件，更新地形数据并按需播放粒子
func _on_remote_sub_destroyed(sub: Vector2i, silent: bool = true) -> void:
	if _world == null:
		TileDefs.damage_sub(sub, 999999, "explosion")
		return
	TileDefs.damage_sub(sub, 999999, "explosion")
	if silent:
		return
	var tex := TileDefs.sub_texture(sub)
	TileHitFx.spawn(_world, Vector2(sub.x * 16.0 + 8.0, sub.y * 16.0 + 8.0), tex)


func _physics_process(delta: float) -> void:
	_tick_beta_time(delta)
	if _local == null:
		return
	_ping_acc += delta
	if _ping_acc >= 0.5:
		_ping_acc = 0.0
		if NetBus.can_send_to_server():
			NetBus.send_ping()
	# 本地预测执行：在物理帧模拟前记录上一帧状态并根据权威快照执行回滚重放
	if _rollback != null:
		if _have_prev_seq:
			_rollback.in_contact = _local.touching_player()
			_rollback.note_post_step(_prev_sent_seq, _local.capture_state())
			_rollback.reconcile()
	var src: PlayerInput = _local.input_source
	var aim: Vector2 = _local.get_current_aim_dir()
	_input_seq += 1
	var pkt := PacketInputSource.pack_record(src, _input_seq, aim)
	var switch_inst: int = _local.weapons.take_uplink_switch(src.get_switch_index_pressed())
	if switch_inst > 0:
		pkt["winst"] = switch_inst
	if NetBus.can_send_to_server():
		NetBus.rpc_id(1, "send_input", pkt)
	_prev_sent_seq = _input_seq
	_have_prev_seq = true
	if _rollback != null:
		_rollback.note_input(_input_seq, pkt)
	_tick_ground_weapons()
	_cull_bullet_contacts()
	_netstat_tick(delta)


# 网络状态诊断输出
func _netstat_tick(delta: float) -> void:
	if not _netstat_checked:
		_netstat_checked = true
		_netstat = OS.get_cmdline_user_args().has("--netstat")
	if not _netstat:
		return
	_netstat_steps += 1
	_netstat_acc += delta
	if _netstat_acc < 1.0:
		return
	_netstat_acc = 0.0
	var gap := _input_seq - _last_ack
	var lag_ms := float(gap) * 1000.0 / 60.0
	var ping := NetBus.ping_ms
	var rb := 0
	if _rollback != null:
		rb = int(_rollback.rollback_count())
	var where := Vector2.ZERO
	if _local != null and is_instance_valid(_local):
		where = (_local as Node2D).global_position
	print("[netstat] seq=%d ack=%d gap=%d(滞后 %.0fms) | ping=%dms | 积压≈%.0fms | 回滚累计=%d (+%d/s) | pos=(%.0f,%.0f) | 物理步/秒=%d 渲染fps=%d"
			% [_input_seq, _last_ack, gap, lag_ms, ping, lag_ms - float(ping), rb, rb - _netstat_prev_rb,
			where.x, where.y, _netstat_steps, Engine.get_frames_per_second()])
	_netstat_steps = 0
	_netstat_prev_rb = rb


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
	_world.add_child(b)
	b.shooter = _replica_for(int(data.get("shooter_role", 0)))


# 清理撞击到可命中实体的本地视觉子弹副本
func _cull_bullet_contacts() -> void:
	for n in get_tree().get_nodes_in_group("bullet"):
		var b := n as BulletBase
		if b == null or b.apply_damage or b.explodes:
			continue
		if _bullet_contact_target(b) != null:
			b.queue_free()


# 检测视觉子弹当前是否接触到合法命中目标
func _bullet_contact_target(b: BulletBase) -> Node2D:
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	for group in BulletBase.CONTACT_GROUPS:
		for n in get_tree().get_nodes_in_group(group):
			if n == b.shooter or not (n is Node2D):
				continue
			if not _bullet_hits_entity(b, n as Node2D):
				continue
			var d := GridPathfinder.toroidal_delta_px(b.global_position,
					(n as Node2D).global_position, w, h).length()
			if d < BulletBase.PLAYER_HIT_RADIUS:
				return n as Node2D
	return null


# 子弹是否命中实体：基类默认允许阻挡，子类（如 3v3）可重写实现队友穿透
func _bullet_hits_entity(_b: BulletBase, _ent: Node2D) -> bool:
	return true


# 统一刷新本地输入锁定状态（倒计时、菜单打开或对局已结束）
func _refresh_input_lock() -> void:
	if _local != null and _local.has_method("set_controls_locked"):
		_local.set_controls_locked(_round_locked or _menu_open or _match_ended)


# ── 结算界面 ──
const RESULT_SCENE := preload("res://ui/screens/match_result.tscn")

# 挂载并展示对局结算面板
func _show_result() -> void:
	if _result == null:
		_result = RESULT_SCENE.instantiate()
		add_child(_result)
		_result.leave_requested.connect(_leave_to_main_menu)
		_result.show_result({})
	_result.show_result(_build_result_payload())


func _leave_to_main_menu() -> void:
	if NetBus != null:
		NetBus.stop()
	if not is_inside_tree():
		return
	Level0.safe_change_scene(get_tree(), "res://scenes/main_menu.tscn")


func _build_result_payload() -> Dictionary:
	return {}


# 远端副本节点访问器，由子类实现
func _replica_for(_role: int) -> Node2D:
	return null


func _on_hit_event(victim_role: int, damage: int, source_pos: Vector2) -> void:
	if _local == null:
		return
	if victim_role == PvpSession.role:
		_local.take_hit(source_pos, damage, false, -1.0)
		return
	var r := _replica_for(victim_role)
	if r != null and r.has_method("play_hit"):
		r.play_hit(source_pos)


# 绘制远端光束武器视觉射线
func _on_beam_fired(data: Dictionary) -> void:
	if _world == null:
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
	LaserVisual.spawn_muzzle_orb(_world, pts[0], color, half_width, lifetime)
	LaserVisual.spawn_beam(_world, pts, half_width, color, lifetime, int(data.get("style", 0)))


# 玩家昵称与角色色相应用虚函数，由子类实现
func _apply_peer_names(_names: Dictionary) -> void:
	push_error("PvpMatchClient: 子类必须覆写 _apply_peer_names")


func _apply_peer_hues(_hues: Dictionary) -> void:
	push_error("PvpMatchClient: 子类必须覆写 _apply_peer_hues")


# 角色颜色与队伍分配钩子，子类可覆盖
func _apply_peer_hues_or_team(payload: Dictionary) -> void:
	var hues: Dictionary = payload.get("hues", {})
	if not hues.is_empty():
		_apply_peer_hues(hues)


# 处理服务端 match_sync 全量同步应答
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
	var sp: Dictionary = payload.get("spawns", {})
	if not resync and sp.has(PvpSession.role):
		var want: Vector2i = sp[PvpSession.role]
		if want != PvpSession.spawn:
			push_warning("match_sync: 出生点与 match_start 不一致(%s vs %s),以 sync 为准" % [
					str(PvpSession.spawn), str(want)])
			PvpSession.spawn = want
			_correct_local_spawn()
	var gw: Array = payload.get("ground_weapons", [])
	_clear_ground_weapons()
	for e in gw:
		if e is Dictionary:
			_spawn_pickup_node(e)
	# 重连状态同步时还原地形基线并补充已被摧毁的瓦片
	if resync and _level0 != null and _level0.has_method("reset_destructibles"):
		_level0.reset_destructibles()
	elif resync:
		var why := ("_level0 为 null" if _level0 == null
				else "_level0 没有 reset_destructibles()")
		push_warning("match_sync(补态): 世界未还原 —— %s" % why)
	var destroyed: Array = payload.get("destroyed", [])
	for c in destroyed:
		if c is Vector2i:
			_on_remote_tile_destroyed(c, true)


# ── 地面武器诊断参数 ──
var _pickup_diag := false
var _pickup_diag_checked := false
var _pickup_diag_frame := 0


func _pickup_diag_on() -> bool:
	if not _pickup_diag_checked:
		_pickup_diag_checked = true
		_pickup_diag = OS.get_cmdline_user_args().has("--pickup-diag")
	return _pickup_diag


# ── 地面武器系统 ──
var ground_weapons := GroundWeaponField.new()
var _pickup_nodes: Dictionary = {}    # 实例 ID 到 WeaponPickup 节点的映射
var _self_drop_until: Dictionary = {} # 刚丢弃武器的拾取保护到期时间

const PICKUP_SCENE := preload("res://scenes/weapons/weapon_pickup.tscn")


# 订阅服务端地面武器生成与移除事件
func _subscribe_ground_weapons() -> void:
	NetBus.local_weapon_spawned.connect(_on_weapon_spawned)
	NetBus.local_weapon_removed.connect(_on_weapon_removed)


func _on_weapon_spawned(data: Dictionary) -> void:
	_spawn_pickup_node(data)


func _on_weapon_removed(data: Dictionary) -> void:
	_remove_pickup_node(int(data.get("inst", 0)))


func _spawn_pickup_node(data: Dictionary) -> void:
	if _pickup_diag_on():
		print("[pkd] ← spawned inst=%s type=%s by_role=%s pos=%s vel=%s | world=%s local=%s 已有=%s" % [
				str(data.get("inst", -1)), str(data.get("type_id", -1)), str(data.get("by_role", -1)),
				str(data.get("pos", Vector2.ZERO)), str(data.get("vel", Vector2.ZERO)),
				"有" if _world != null else "空", "有" if _local != null else "空",
				"是" if _pickup_nodes.has(int(data.get("inst", 0))) else "否"])
	if _world == null:
		return
	var inst := int(data.get("inst", 0))
	if inst <= 0 or _pickup_nodes.has(inst):
		return
	var type_id := int(data.get("type_id", 1))
	var node: WeaponPickup = PICKUP_SCENE.instantiate()
	node.configure(type_id, inst, int(data.get("mag", 0)), data.get("vel", Vector2.ZERO))
	_world.add_child(node)
	node.canonical_pos = data.get("pos", Vector2.ZERO)
	node.set_anchor((_local as Node2D).global_position if _local != null else Vector2.ZERO)
	node.sync_render_from_canonical()
	ground_weapons.map_size = Vector2(float(GameParameters.MAP_WIDTH), float(GameParameters.MAP_HEIGHT))
	ground_weapons.add({"inst": inst, "type_id": type_id, "mag": int(data.get("mag", 0)),
			"pos": node.canonical_pos, "vel": data.get("vel", Vector2.ZERO)})
	_pickup_nodes[inst] = node
	if int(data.get("by_role", -1)) == int(PvpSession.role):
		_self_drop_until[inst] = Time.get_ticks_msec() \
				+ int(PlayerParams.weapon_pickup_self_delay * 1000.0)


# 清空地面武器记录与拾取物节点
func _clear_ground_weapons() -> void:
	for inst in _pickup_nodes:
		var n = _pickup_nodes[inst]
		if n != null and is_instance_valid(n):
			n.queue_free()
	_pickup_nodes.clear()
	ground_weapons.clear()
	_self_drop_until.clear()


func _remove_pickup_node(inst: int) -> void:
	ground_weapons.remove(inst)
	var n = _pickup_nodes.get(inst, null)
	if n != null and is_instance_valid(n):
		n.queue_free()
	_pickup_nodes.erase(inst)
	_self_drop_until.erase(inst)
	if _pickup_diag_on():
		print("[pkd] ← removed inst=%d" % inst)


# 每帧更新地面武器锚点、位置同步与交互提示
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
	_pickup_diag_frame += 1
	_update_pickup_prompt(lp)


# 更新拾取按键提示显示
func _update_pickup_prompt(lp: Vector2) -> void:
	var self_drops := _live_self_drops()
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	for inst in _pickup_nodes:
		var n = _pickup_nodes[inst]
		if n == null or not is_instance_valid(n):
			continue
		var pk := n as WeaponPickup
		var can := false
		if _local != null and not _live_self_drops().has(int(inst)) \
				and _local.weapons.is_type_enabled(int(pk.type_id)):
			var d := GridPathfinder.toroidal_delta_px(pk.canonical_pos, lp, w, h).length()
			can = d <= PlayerParams.weapon_pickup_radius
		pk.set_prompt_visible(can)
		if _pickup_diag_on() and _pickup_diag_frame % 30 == 0:
			var dd := GridPathfinder.toroidal_delta_px(pk.canonical_pos, lp, w, h).length()
			if dd <= 400.0:
				print("[pkd]   inst=%d type=%d d=%.1f can=%s | 冷却=%s 启用=%s | canon=(%.0f,%.0f) render=(%.0f,%.0f) 玩家=(%.0f,%.0f) settled=%s" % [
						int(inst), int(pk.type_id), dd, "是" if can else "否",
						"是" if _live_self_drops().has(int(inst)) else "否",
						"是" if _local.weapons.is_type_enabled(int(pk.type_id)) else "否",
						pk.canonical_pos.x, pk.canonical_pos.y,
						pk.global_position.x, pk.global_position.y, lp.x, lp.y,
						"是" if pk._settled else "否"])


# 获取处于丢弃冷却期的武器实例列表
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


# ── 断线重连状态机 ──
const RECONNECT_RETRY_MS := 2000
const RECONNECT_ATTEMPT_TIMEOUT_MS := 5000
var _reconnecting := false
var _reconnect_started_ms := 0
var _reclaim_sent := false
var _pending_disconnect := false
var _attempt_started_ms := 0
var _retry_timer: SceneTreeTimer = null
var _resync_pull_pending := false

var _banner: StatusBanner = null


# 订阅断线检测与重连响应事件
func _subscribe_reconnect() -> void:
	NetBus.local_server_message.connect(_on_server_message)
	NetBus.local_match_start.connect(_on_match_start_event)
	_setup_status_banner()


func _setup_status_banner() -> void:
	if _banner != null:
		return
	_banner = preload("res://ui/hud/status_banner.tscn").instantiate() as StatusBanner
	add_child(_banner)


func _set_status(text: String) -> void:
	if _banner != null:
		_banner.set_text(text)


func _on_server_message(msg: String) -> void:
	if _match_ended or _reconnecting:
		return
	if msg.contains("断开") or msg.contains("断开连接"):
		_pending_disconnect = true
		_begin_reconnect()


# 关闭菜单后补充触发在菜单打开期间发生的断线重连
func _recheck_disconnect() -> void:
	if _pending_disconnect:
		_pending_disconnect = false
		_begin_reconnect()


# 启动局内自动重连流程
func _begin_reconnect() -> void:
	if _match_ended:
		return
	if _reconnect_started_ms == 0:
		_reconnect_started_ms = Time.get_ticks_msec()
	if _menu_open:
		return
	_pending_disconnect = false
	if PvpSession.token == "" or PvpSession.worker_port <= 0:
		_abort_reconnect("重连失败(无会话令牌)")
		return
	_reconnecting = true
	_set_status("与服务器断线,正在重连…")
	print("[pvp] 连接断开,开始重连(role=%d port=%d)" % [PvpSession.role, PvpSession.worker_port])
	_retry_connect.call_deferred()


# 执行一次连接重试
func _retry_connect() -> void:
	if not _reconnecting:
		return
	NetBus.stop()
	_reclaim_sent = false
	_attempt_started_ms = 0
	if multiplayer.connected_to_server.is_connected(_try_reclaim):
		multiplayer.connected_to_server.disconnect(_try_reclaim)
	if multiplayer.connection_failed.is_connected(_on_reconnect_failed):
		multiplayer.connection_failed.disconnect(_on_reconnect_failed)
	var err := NetBus.start_client(PvpSession.server_address, PvpSession.worker_port)
	if err != OK:
		_schedule_reconnect_retry()
		return
	_attempt_started_ms = Time.get_ticks_msec()
	multiplayer.connected_to_server.connect(_try_reclaim, CONNECT_ONE_SHOT)
	multiplayer.connection_failed.connect(_on_reconnect_failed, CONNECT_ONE_SHOT)
	_schedule_reconnect_retry()


func _on_reconnect_failed() -> void:
	_attempt_started_ms = 0
	_schedule_reconnect_retry()


func _try_reclaim() -> void:
	if not _reconnecting:
		return
	if _reclaim_sent:
		return
	_attempt_started_ms = 0
	_reclaim_sent = true
	NetBusExt.rpc_id(1, "reclaim_role", PvpSession.role, PvpSession.token)
	_schedule_reconnect_retry()


# 安排下一次重试心跳
func _schedule_reconnect_retry() -> void:
	if not _reconnecting:
		return
	if _retry_timer != null and _retry_timer.time_left > 0.0:
		return
	_retry_timer = get_tree().create_timer(RECONNECT_RETRY_MS / 1000.0)
	_retry_timer.timeout.connect(_on_reconnect_retry_tick)


func _on_reconnect_retry_tick() -> void:
	if not _reconnecting:
		return
	var left := int(GraceWindow.DEFAULT_SECONDS) \
			- int((Time.get_ticks_msec() - _reconnect_started_ms) / 1000)
	_set_status("与服务器断线,正在重连…(剩余 %ds)" % maxi(left, 0))
	if Time.get_ticks_msec() - _reconnect_started_ms > int(GraceWindow.DEFAULT_SECONDS * 1000.0):
		_abort_reconnect("重连超时,对局已结束")
		return
	if _reclaim_sent and NetBus.can_send_to_server():
		_schedule_reconnect_retry()
		return
	var attempt_age := Time.get_ticks_msec() - _attempt_started_ms
	if _attempt_started_ms > 0 and attempt_age < RECONNECT_ATTEMPT_TIMEOUT_MS:
		_schedule_reconnect_retry()
		return
	_retry_connect()


func _on_match_start_event(_role: int, _spawn: Vector2i, _map_path: String) -> void:
	if not _reconnecting:
		return
	_on_resumed()


# 成功重连后的状态恢复与增量数据请求
func _on_resumed() -> void:
	_reconnecting = false
	_reconnect_started_ms = 0
	_reclaim_sent = false
	_attempt_started_ms = 0
	_set_status("")
	_input_seq = 0
	_have_prev_seq = false
	_prev_sent_seq = -1
	_rollback = PredictionRollback.new()
	_rollback.bind(_local)
	_rollback.map_px = Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	if NetBus.can_send_to_server():
		_resync_pull_pending = true
		NetBus.rpc_id(1, "match_sync")
	print("[pvp] 重连成功")


# 对手离开时终止重连流程
func _cancel_reconnect() -> void:
	_reconnecting = false
	_reconnect_started_ms = 0
	_reclaim_sent = false
	_attempt_started_ms = 0
	_set_status("")


func _abort_reconnect(reason: String) -> void:
	_reconnecting = false
	_set_status("")
	NetBus.stop()
	Level0.safe_change_scene(get_tree(), "res://scenes/main_menu.tscn")
	print("[pvp] %s" % reason)


func _exit_tree() -> void:
	if _reconnecting:
		_reconnecting = false
		NetBus.stop()
