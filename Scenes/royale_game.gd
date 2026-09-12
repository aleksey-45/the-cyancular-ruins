extends Node2D
# 大乱斗对局客户端(RoyaleServer 分支):Level0(pvp_mode) 世界 + 本地玩家(服务器渲染)
# + N-1 个远端副本 + 后处理 + 输入上报 + 快照消费 + RoyaleHud(左上角击杀排行榜)。
# 与 pvp_client 的差别:对手是 1..N 个(按快照 roles 动态建副本),HUD 用 RoyaleHud。

const TileHitFx := preload("res://Scenes/Effects/tile_hit_fx.gd")
const LaserVisual := preload("res://Globals/laser_visual.gd")   # 远端光束视觉副本(与本地激光同款)

var _last_snap_tick := 0
var _local: Node2D = null
var _replicas: Dictionary = {}         # role(int) -> PlayerReplica(自己以外的全部角色)
var _enemy_replicas: Dictionary = {}   # bird_id(int) -> EnemyReplica
var _level0: Node = null
var _world: Node = null
var _hud: RoyaleHud = null
var _match_ended := false
var _ping_acc := 0.0
# C2 本地预测(读设置 Settings.pvp_c2_prediction,默认开):本地自己角色引擎自步进 + 回滚重放;
# 关闭 = 纯服务器渲染(旧行为)。与 pvp_client 同款接线;权威整态来自快照里"自己那份"c2。
var _predict := true
var _rollback = null
var _input_seq := 0
var _prev_sent_seq := 0
var _have_prev_seq := false

# ── 头上 ID / 血条(按 role 管理)──
const ID_HEAD_OFFSET := Vector2(0.0, -78.0)
# 8 人角色色板(头顶 ID;本体染色仍走色相设置/peer_hues)
const ROLE_COLORS: Array[Color] = [
	Color(0.72, 0.93, 1.0), Color(1.0, 0.82, 0.62), Color(0.75, 1.0, 0.7), Color(1.0, 0.7, 0.9),
	Color(0.95, 0.95, 0.6), Color(0.7, 0.8, 1.0), Color(1.0, 0.62, 0.55), Color(0.8, 0.7, 1.0),
]
var _id_labels: Dictionary = {}    # role(int) -> WorldLabel(含自己)
var _hp_bars: Dictionary = {}      # role(int) -> EnemyHpBar(仅他人,设置开启时)
var _hues: Dictionary = {}         # role(int) -> 色相(peer_hues 下发)

func _ready() -> void:
	CombatComponent.pvp_arena = true
	Level0.menu_demo = false
	MazeGenerator.set_map_file(PvpSession.map_path)
	GameParameters.refresh_map_size()
	Level0.pvp_mode = true
	var level0: Node = load("res://Scenes/Level0.tscn").instantiate()
	add_child(level0)
	_level0 = level0
	_world = level0.get_node("WorldViewport")
	var local: Node2D = _world.get_node("Player")
	var ts := GameParameters.TILE_SIZE
	local.position = Vector2(PvpSession.spawn.x * ts + ts / 2.0, PvpSession.spawn.y * ts + ts / 2.0)
	_local = local
	_predict = Settings.pvp_c2_prediction
	if _predict:
		if _rollback == null:
			_rollback = PredictionRollback.new()
		_rollback.bind(_local)
	elif _local.has_method("set_server_rendered"):
		_local.set_server_rendered(true)
	var pp := PostProcess.new()
	pp.world_viewport = level0.get_node("WorldViewport")
	call_deferred("add_child", pp)
	# 血条(他人,设置开启时;具体 role 的实例随副本在快照里懒建)
	# 快照/事件消费
	NetBus.local_snapshot.connect(_on_snapshot)
	NetBus.local_bullet_spawn.connect(_on_bullet_spawn)
	NetBus.local_hit_event.connect(_on_hit_event)
	NetBus.local_tile_destroyed.connect(_on_remote_tile_destroyed)
	NetBus.local_round_state.connect(_on_round_state)
	NetBus.local_peer_info.connect(_on_peer_info)
	NetBus.local_enemy_spawn.connect(_on_enemy_spawn)
	NetBus.local_enemy_died.connect(_on_enemy_died)
	NetBusExt.local_match_options.connect(_on_match_options)
	NetBusExt.local_explosion_event.connect(_on_explosion_event)   # 权威爆炸视效(本地预测弹道不再自行起爆)
	NetBusExt.local_peer_hues.connect(_on_peer_hues)
	NetBusExt.c2s("request_hues")   # 开局广播可能早于本场景加载 → 主动补要一次
	NetBusExt.local_hit_confirm.connect(_on_hit_confirm)
	NetBusExt.local_beam_fired.connect(_on_beam_fired)   # 激光权威开火 → 非射手端画光束副本
	NetBus.local_kill_event.connect(_on_kill_event)
	# 小地图(多目标版)
	if Settings.pvp_show_minimap:
		var minimap := Minimap.new()
		minimap.setup_multi(
			func() -> Vector2: return _local.global_position if _local != null else Vector2.INF,
			func() -> Array:
				var arr: Array = []
				for r in _replicas:
					if is_instance_valid(_replicas[r]):
						arr.append((_replicas[r] as Node2D).global_position)
				return arr)
		add_child(minimap)
	# HUD(左上角击杀排行榜)+ Esc 菜单
	_hud = RoyaleHud.new()
	add_child(_hud)
	add_child(PauseMenu.new(true))
	# 打击反馈层(命中 X 标记/击杀播报,layer 131 盖在排行榜之上)
	CombatFeedback.spawn(self)
	# 自己的染色(设置色相)
	_apply_tint(_local.get_node_or_null("AnimatedSprite2D"), Settings.pvp_color_hue)
	print("进入大乱斗:角色 %d 出生点 %s" % [PvpSession.role, PvpSession.spawn])

func _physics_process(_delta: float) -> void:
	if _local == null:
		return
	_ping_acc += _delta
	if _ping_acc >= 0.5:
		_ping_acc = 0.0
		NetBus.send_ping()
	# C2:引擎本帧步进前,先把上一 seq 的预测整态入 ring,再 reconcile 到期权威
	# (顺序:先记预测态,reconcile 才比得上 ring[C];与 pvp_client 一致)
	if _predict and _rollback != null:
		if _have_prev_seq:
			_rollback.note_post_step(_prev_sent_seq, _local.capture_state())
			_rollback.reconcile()
	var src: InputSource = _local.input_source
	const UP := NetworkInputSource.BIT_UP
	const DOWN := NetworkInputSource.BIT_DOWN
	const CHARGE := NetworkInputSource.BIT_CHARGE
	const ATTACK := NetworkInputSource.BIT_ATTACK
	var held := 0
	var pressed := 0
	var released := 0
	if src.is_action_pressed("up"):
		held |= UP
	if src.is_action_pressed("down"):
		held |= DOWN
	if src.is_action_pressed("charge"):
		held |= CHARGE
	if src.is_action_pressed("attack"):
		held |= ATTACK
	if src.is_action_just_pressed("up"):
		pressed |= UP
	if src.is_action_just_pressed("down"):
		pressed |= DOWN
	if src.is_action_just_pressed("charge"):
		pressed |= CHARGE
	if src.is_action_just_pressed("attack"):
		pressed |= ATTACK
	if src.is_action_just_released("up"):
		released |= UP
	if src.is_action_just_released("down"):
		released |= DOWN
	if src.is_action_just_released("attack"):
		released |= ATTACK
	var aim: Vector2 = _local.get_current_aim_dir()
	_input_seq += 1
	var pkt := {
		"seq": _input_seq,
		"ax": src.get_axis("left", "right"),
		"held": held,
		"pressed": pressed,
		"released": released,
		"weapon": src.get_weapon_slot_pressed(),
		"aim": aim,
	}
	# 滚轮切枪:目标槽位随输入包上行(滚轮事件不在协议里,只本地切会被快照切回)
	var net_slot: int = _local.weapons.consume_net_slot()
	if net_slot > 0:
		pkt["weapon"] = net_slot
	NetBus.rpc_id(1, "send_input", pkt)
	_prev_sent_seq = _input_seq
	_have_prev_seq = true
	if _predict and _rollback != null:
		_rollback.note_input(_input_seq, pkt)   # 供回滚重放使用

func _on_snapshot(snap: Dictionary) -> void:
	if _local == null:
		return
	var snap_tick := int(snap.get("tick", 0))
	if snap_tick < _last_snap_tick:
		return
	_last_snap_tick = snap_tick
	var players_snap: Dictionary = snap["players"]
	for role_str in players_snap:
		var role := int(role_str)
		var data: Dictionary = players_snap[role_str]
		if role == PvpSession.role:
			if _predict and _rollback != null:
				# C2:权威整态/ack 喂控制器(reconcile 在下一帧步进前处理;散字段位置不直接采纳;
				# hp/倒地等也在整态里,随 restore 一并采纳)
				var ack := int(data.get("ack_seq", 0))
				var c2: Dictionary = data.get("c2", {})
				if ack > 0 and not c2.is_empty():
					_rollback.on_authoritative(ack, c2)
			elif _local.has_method("apply_server_snapshot"):
				_local.apply_server_snapshot(data)
		else:
			_ensure_replica(role)
			var r: Node2D = _replicas[role]
			if r != null and r.has_method("apply_snapshot"):
				r.apply_snapshot(data, _local.global_position, snap_tick)
				if _hp_bars.has(role):
					_hp_bars[role].ratio = float(data.get("hp", PlayerParams.player_max_hp)) \
							/ float(PlayerParams.player_max_hp)
	# 清理已离开玩家(掉线者从快照消失):副本/头顶ID/血条一并移除(自检 M3 幽灵残留)
	for role_str in _replicas.keys():
		if not players_snap.has(str(role_str)):
			_remove_replica(int(role_str))
	# 中立鸟(大乱斗默认无鸟;协议保留兼容)
	var enemies_snap: Dictionary = snap.get("enemies", {})
	for id_str in enemies_snap:
		var bid := int(id_str)
		if _enemy_replicas.has(bid):
			var e: Node = _enemy_replicas[bid]
			if e != null and e.has_method("apply_remote"):
				e.apply_remote(enemies_snap[id_str], _local.global_position, snap_tick)

# 懒建远端副本(按快照里出现的 role)—— 大乱斗对手数量不定
func _ensure_replica(role: int) -> void:
	if _replicas.has(role) and is_instance_valid(_replicas[role]):
		return
	var replica: Node2D = preload("res://Scenes/Player/player_replica.tscn").instantiate()
	replica.name = "ReplicaP%d" % role
	_world.add_child(replica)
	_replicas[role] = replica
	# 头顶 ID + 染色(peer_hues 可能未到,先按角色色板,到了再覆盖)
	_ensure_id_label(role)
	_apply_tint(replica.get_node_or_null("AnimatedSprite2D"), float(_hues.get(role, 0.0)))
	if Settings.pvp_show_enemy_hp:
		var bar := EnemyHpBar.new()
		_world.add_child(bar)
		_hp_bars[role] = bar
	_refresh_names()


# 移除已离开玩家的视觉件:副本/头顶ID/血条(自检 M3 幽灵残留)
func _remove_replica(role: int) -> void:
	if _replicas.has(role):
		var r: Node2D = _replicas[role]
		if is_instance_valid(r):
			r.queue_free()
		_replicas.erase(role)
	if _id_labels.has(role):
		var l: Node = _id_labels[role]
		if is_instance_valid(l):
			l.queue_free()
		_id_labels.erase(role)
	if _hp_bars.has(role):
		var b: Node = _hp_bars[role]
		if is_instance_valid(b):
			b.queue_free()
		_hp_bars.erase(role)
	_refresh_names()

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
	if Settings.pvp_show_trajectories:
		BulletTrail.attach(b, data["color"])

# 远端激光:服务器权威开火 → 非射手端画光束视觉副本(与 1v1 pvp_client 同款)。
# 之前 royale 漏订阅 NetBusExt.local_beam_fired:别人开枪时本端收不到、画不出光束。
func _on_beam_fired(data: Dictionary) -> void:
	if _world == null:
		return
	var shooter := int(data.get("shooter_role", 0))
	if shooter == PvpSession.role:
		return
	var anchor_node: Node2D = _replicas.get(shooter) as Node2D
	if anchor_node == null or not is_instance_valid(anchor_node):
		return
	var raw: PackedVector2Array = data.get("pts", PackedVector2Array())
	if raw.is_empty():
		return
	var anchor: Vector2 = anchor_node.global_position
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


func _on_hit_event(victim_role: int, damage: int, source_pos: Vector2) -> void:
	if _local == null:
		return
	if victim_role == PvpSession.role:
		_local.take_hit(source_pos, damage, false, -1.0)
	elif _replicas.has(victim_role) and is_instance_valid(_replicas[victim_role]) \
			and _replicas[victim_role].has_method("play_hit"):
		_replicas[victim_role].play_hit(source_pos)

# 命中确认(服务器裁决的弹直击,NetBusExt):我是射手 → 屏幕中心 X 标记(FPS 式命中反馈)
func _on_hit_confirm(shooter_role: int, _victim_role: int) -> void:
	if shooter_role == PvpSession.role:
		CombatFeedback.hit_marker()

# 击杀播报:我击杀对手 → 屏幕中央「击杀 XXX」+ 音效(被击杀的是自己则不播)
func _on_kill_event(killer: int, victim: int) -> void:
	if killer == PvpSession.role and victim != PvpSession.role:
		CombatFeedback.kill(str(_names.get(victim, "玩家%d" % victim)))
	elif victim == PvpSession.role:
		CombatFeedback.reset_streak()   # 自己被击杀 → 连杀清零

# K = 自杀脱困:卡进墙/夹缝时主动放弃生命,走服务器权威 2s 复活(不计入任何人击杀)。
func _unhandled_input(event: InputEvent) -> void:
	if _match_ended or _local == null:
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and event.physical_keycode == KEY_K:
		NetBusExt.c2s("suicide_request")

func _on_remote_tile_destroyed(cell: Vector2i) -> void:
	if _world == null:
		TileDefs.damage_tile(cell, 999999, "explosion")
		return
	var tex := 0
	var grid := MazeGenerator.current_grid
	if not grid.is_empty() and cell.y >= 0 and cell.y < grid.size():
		var row: Array = grid[cell.y]
		if cell.x >= 0 and cell.x < row.size():
			tex = int(row[cell.x]) / 16
	TileDefs.damage_tile(cell, 999999, "explosion")
	var ts := GameParameters.TILE_SIZE
	TileHitFx.spawn(_world, Vector2(cell.x * ts + ts * 0.5, cell.y * ts + ts * 0.5), tex)

func _on_round_state(data: Dictionary) -> void:
	var state := int(data.get("state", 0))
	if _local != null and _local.has_method("set_controls_locked"):
		_local.set_controls_locked(state == 0)   # COUNTDOWN 锁开火(移动由服务器权威冻结)
	if state == 3 and not _match_ended:   # MATCH_OVER → 展示结果 6s 后回主菜单
		_match_ended = true
		if _local != null and _local.has_method("set_controls_locked"):
			_local.set_controls_locked(true)   # 结算画面锁输入(自检 L6:原还能跑动开枪)
		# 捕获 tree/autoload 引用:玩家若在 6s 内经暂停菜单退出,本节点已释放,
		# 到点时对已释放实例调 get_tree() 会报错(自检 L6)
		var tree := get_tree()
		var netbus := NetBus
		get_tree().create_timer(6.0).timeout.connect(func() -> void:
			netbus.stop()
			Level0.safe_change_scene(tree, "res://Scenes/main_menu.tscn"))

# ── 中立鸟兼容(大乱斗默认无鸟)──
func _on_enemy_spawn(roster: Array) -> void:
	_clear_enemy_replicas()
	if _world == null or _local == null:
		return
	for entry in roster:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var scene_path := str(entry.get("scene", ""))
		var bid := int(entry.get("id", 0))
		if scene_path == "" or bid <= 0:
			continue
		var r: Node2D = preload("res://Scenes/Enemies/enemy_replica.gd").new()
		_world.add_child(r)
		r.setup(bid, scene_path, entry.get("pos", _local.global_position), _local.global_position)
		_enemy_replicas[bid] = r

func _clear_enemy_replicas() -> void:
	for r in _enemy_replicas.values():
		if is_instance_valid(r):
			r.queue_free()
	_enemy_replicas.clear()

func _on_enemy_died(id: int) -> void:
	if not _enemy_replicas.has(id):
		return
	var r: Node = _enemy_replicas[id]
	if is_instance_valid(r):
		r.queue_free()
	_enemy_replicas.erase(id)

# ── 名字 / 颜色 ──
func _on_peer_info(names: Dictionary) -> void:
	_names = names
	_ensure_id_label(PvpSession.role)
	_refresh_names()

var _names: Dictionary = {}   # role(int) -> 昵称(peer_info 下发)

func _on_peer_hues(hues: Dictionary) -> void:
	_hues = hues
	for role in _replicas:
		if is_instance_valid(_replicas[role]):
			_apply_tint(_replicas[role].get_node_or_null("AnimatedSprite2D"),
					float(_hues.get(role, 0.0)))

func _ensure_id_label(role: int) -> void:
	if _world == null or _id_labels.has(role):
		return
	var lbl: Node2D = load("res://Scenes/Player/world_label.gd").new()
	_world.add_child(lbl)
	_id_labels[role] = lbl

func _refresh_names() -> void:
	for role in _id_labels:
		var nm := str(_names.get(role, "玩家%d" % role))
		if role == PvpSession.role:
			nm = str(_names.get(role, PvpSession.player_name))
		var col: Color = ROLE_COLORS[(role - 1) % ROLE_COLORS.size()]
		(_id_labels[role] as Node2D).set_label(nm, col)

func _apply_tint(body: Node, hue_deg: float) -> void:
	var canvas := body as CanvasItem
	if canvas == null or is_zero_approx(hue_deg):
		return
	var mat := ShaderMaterial.new()
	mat.shader = load("res://Scenes/Player/player_p2_hue.gdshader")
	mat.set_shader_parameter("hue_shift", hue_deg)
	canvas.material = mat

# 服务器下发生效选项:同步禁用武器
func _on_match_options(opts: Dictionary) -> void:
	var disabled: Array[int] = []
	for v in opts.get("disabled_weapons", []):
		disabled.append(int(v))
	PvpSession.disabled_weapons = disabled
	if _local != null:
		_local.weapons.set_enabled_slots(disabled)

func _process(_delta: float) -> void:
	# 头顶 ID / 血条贴放(独立于倒地转体)
	for role in _id_labels:
		var target: Node2D = _local if role == PvpSession.role else _replicas.get(role)
		if target != null and is_instance_valid(target):
			(_id_labels[role] as Node2D).global_position = (target as Node2D).global_position + ID_HEAD_OFFSET
	for role in _hp_bars:
		var r: Node2D = _replicas.get(role)
		if r != null and is_instance_valid(r):
			(_hp_bars[role] as Node2D).global_position = r.global_position + Vector2(0.0, -116.0)


# 服务器权威爆炸视效:榴弹多次弹开后本地预测与服务器模拟分叉,爆炸位置一律以广播为准
# (伤害本就只在服务器结算;见 bullet_base._explode 与 NetBusExt.explosion_event)。
func _on_explosion_event(pos: Vector2, _radius: float) -> void:
	if _world == null:
		return
	var fx: Node = preload("res://Scenes/Effects/explosion.tscn").instantiate()
	fx.global_position = pos
	_world.add_child(fx)
	Sfx.play("explosion")
