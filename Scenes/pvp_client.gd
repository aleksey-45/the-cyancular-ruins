extends Node2D
# PvP 客户端对局场景:Level0(pvp_mode) 世界 + 本地玩家(C2 本地模拟) + 后处理 + 输入上报 + 快照消费。

const TileHitFx := preload("res://Scenes/Effects/tile_hit_fx.gd")
const LaserVisual := preload("res://Globals/laser_visual.gd")   # 远端光束视觉副本(与本地激光同款)

# ── 本地玩家渲染方式(开关) ──
# ON(当前):C2 客户端预测 + PredictionRollback 权威锚定重放(移植原作者 main 70e4c75):
#     本地跑全量物理(手感=单机),与服务器权威整态分歧时才 restore + 重放未确认输入纠偏。
# OFF:本地玩家完全由服务器快照驱动(server_rendered)——无回拉,但本地操作含整轮延迟。
# 回退方式:把下面常量改回 false 即回到纯服务器渲染。回滚频次可读 _rollback.rollback_count() 观测。
# C2 本地预测开关:读设置(Settings.pvp_c2_prediction,默认开;设置页可关)。
# 对局开始时捕获(_ready),中途切换下一局生效。关闭 = 纯服务器渲染(无回拉,但操作含整轮延迟)。
var _predict := true
var _rollback = null            # PredictionRollback(开关 ON 时创建)
var _input_seq := 0             # 本地每物理帧单调输入序号(服务器 1/tick 消费并回带 ack)
var _have_prev_seq := false
var _prev_sent_seq := 0
var _last_snap_tick := 0

var _local: Node2D = null
var _remote_replica: Node2D = null
var _enemy_replicas: Dictionary = {}   # bird_id(int) -> EnemyReplica(中立鸟视觉副本)
var _level0: Node = null   # 世界(Level0):换局复位砖用 reset_destructibles
var _world: Node = null   # WorldViewport(视觉子弹副本挂这里)
var _hud: PvpHud = null
var _match_ended := false      # MATCH_OVER 后回菜单途中,忽略对手断线播报
var _ping_acc := 0.0

# ── 头上 ID(自己/对手昵称):世界空间文字,每帧贴到头顶 ──
const ID_HEAD_OFFSET := Vector2(0.0, -78.0)   # 头顶文字位置(-100 略高,现往下压一点)
const ROLE_COLOR := {1: Color(0.72, 0.93, 1.0), 2: Color(1.0, 0.82, 0.62)}
var _id_self: Node2D = null
var _id_opp: Node2D = null
var _hp_bar: EnemyHpBar = null    # 对手头顶血条(设置开启时创建)
var _minimap: Minimap = null      # 小地图(设置开启时创建)
var _opp_hues: Dictionary = {}    # 双方角色颜色 {role -> 色相}(扩展 peer_hues 下发)
var _names: Dictionary = {}       # role(int) -> 昵称(peer_info 下发;击杀播报取名字用)

func _ready() -> void:
	CombatComponent.pvp_arena = true   # PvP:取消命中无敌帧(每发结算一次)
	Level0.menu_demo = false           # 清主菜单背景演示残留(双保险,见 level_0 判定)
	MazeGenerator.set_map_file(PvpSession.map_path)
	# 重算世界尺寸:_ready 启动时算的是随机 demo 图(8000 宽),PvP 固定图是 9600 宽,
	# 不重算则本地插值/回绕按错边界 → 玩家在图中间被空气墙弹走。
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
	# 本地玩家渲染方式:默认 server_rendered;C2 开启则本地预测 + 回滚控制器。
	_predict = Settings.pvp_c2_prediction
	if not _predict and _local.has_method("set_server_rendered"):
		_local.set_server_rendered(true)
	elif _predict:
		if _rollback == null:
			_rollback = PredictionRollback.new()
		_rollback.bind(_local)
	# pvp_mode 下 Level0 不建后处理,这里补(否则 SubViewport 不显示)
	var pp := PostProcess.new()
	pp.world_viewport = level0.get_node("WorldViewport")
	call_deferred("add_child", pp)
	# 远端副本(角色 = 3 - 自己的 role,1v1)
	var replica := preload("res://Scenes/Player/player_replica.tscn").instantiate()
	replica.name = "RemoteReplica"
	level0.get_node("WorldViewport").add_child(replica)
	_remote_replica = replica
	# 对手头顶血条(设置开启时;挂 WorldViewport 走世界坐标,每帧贴到头顶)
	if Settings.pvp_show_enemy_hp:
		_hp_bar = EnemyHpBar.new()
		_world.add_child(_hp_bar)
	# 快照/事件消费
	NetBus.local_snapshot.connect(_on_snapshot)
	NetBus.local_bullet_spawn.connect(_on_bullet_spawn)
	NetBus.local_hit_event.connect(_on_hit_event)
	NetBus.local_tile_destroyed.connect(_on_remote_tile_destroyed)
	NetBus.local_round_state.connect(_on_round_state)
	NetBus.local_peer_info.connect(_on_peer_info)
	NetBus.local_opponent_left.connect(_on_opponent_left)
	NetBus.local_enemy_spawn.connect(_on_enemy_spawn)
	NetBus.local_enemy_died.connect(_on_enemy_died)
	NetBusExt.local_match_options.connect(_on_match_options)
	NetBusExt.local_explosion_event.connect(_on_explosion_event)   # 权威爆炸视效(本地预测弹道不再自行起爆)
	NetBusExt.local_peer_hues.connect(_on_peer_hues)
	NetBusExt.c2s("request_hues")   # 同上:1v1 进图后补要颜色
	NetBusExt.local_hit_confirm.connect(_on_hit_confirm)
	NetBusExt.local_beam_fired.connect(_on_beam_fired)
	NetBusExt.local_smoke_event.connect(_on_smoke_event)
	NetBus.local_kill_event.connect(_on_kill_event)
	# 小地图(设置开启时;位置提供器给本地玩家/对手副本)
	if Settings.pvp_show_minimap:
		_minimap = Minimap.new()
		_minimap.setup(
			func() -> Vector2: return _local.global_position if _local != null else Vector2.INF,
			func() -> Vector2:
				if _remote_replica != null and is_instance_valid(_remote_replica):
					return (_remote_replica as Node2D).global_position
				return Vector2.INF)
		add_child(_minimap)
	# 回合记分 HUD(层级盖在 PostProcess/单机 HUD 之上)
	_hud = PvpHud.new()
	add_child(_hud)
	# 打击反馈层(命中 X 标记/击杀播报,layer 131 盖在 PvP HUD 之上)
	CombatFeedback.spawn(self)
	# Esc 菜单(PvP:不暂停树,回主菜单=断开连接,worker 检测断线自动拆局)
	add_child(PauseMenu.new(true))
	# P2 本体色相 -20(区分双方;只染角色 AnimatedSprite2D 本体,武器/预瞄不染)
	_apply_p2_tint()
	# 小地图需要在 post_process 之上才可见,但 CanvasLayer 无层级冲突(layer 131)→ 已在 _ready 建好
	print("进入竞技场:角色 %d 出生点 %s" % [PvpSession.role, PvpSession.spawn])

func _physics_process(_delta: float) -> void:
	if _local == null:
		return
	# 周期测延迟(右下角 HUD)
	_ping_acc += _delta
	if _ping_acc >= 0.5:
		_ping_acc = 0.0
		NetBus.send_ping()
	# C2:玩家由引擎自步进(读真实 Input)。这里在它本帧步进前——先把上一 seq 的预测整态入 ring,
	# 再 reconcile 到期权威(分歧 → restore+重放重对齐)。顺序:先记预测态,reconcile 才比得上 ring[C]。
	if _predict and _rollback != null:
		if _have_prev_seq:
			_rollback.note_post_step(_prev_sent_seq, _local.capture_state())
			_rollback.reconcile()
	var src: InputSource = _local.input_source
	# 位映射:NetworkInputSource 的常量(输入包协议与服务器共用)
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
	# 丢弃乱序旧快照(unreliable 通道可能乱序;应用旧快照会把玩家拉回过去位置)
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
				# C2:权威整态/ack 喂控制器(reconcile 在下一帧步进前处理;散字段位置不直接采纳)
				var ack := int(data.get("ack_seq", 0))
				var c2: Dictionary = data.get("c2", {})
				if ack > 0 and not c2.is_empty():
					_rollback.on_authoritative(ack, c2)
			else:
				_apply_local_state(data)
		elif _remote_replica != null and _remote_replica.has_method("apply_snapshot"):
			_remote_replica.apply_snapshot(data, _local.global_position, snap_tick)
			# 对手血条:快照 hp → 比例(上限取 PlayerParams 玩家最大血)
			if _hp_bar != null:
				_hp_bar.ratio = float(data.get("hp", PlayerParams.player_max_hp)) / float(PlayerParams.player_max_hp)
	# 中立鸟副本:按 id 更新(权威位置/动画/朝向;存在性由 enemy_spawn/enemy_died 管)
	var enemies_snap: Dictionary = snap.get("enemies", {})
	for id_str in enemies_snap:
		var bid := int(id_str)
		if _enemy_replicas.has(bid):
			var r: Node = _enemy_replicas[bid]
			if r != null and r.has_method("apply_remote"):
				r.apply_remote(enemies_snap[id_str], _local.global_position, snap_tick)

# 本地玩家完全由服务器快照驱动:权威状态直接采纳,位置/姿态/朝向由 player 插值渲染。
func _apply_local_state(data: Dictionary) -> void:
	if _local == null:
		return
	if _local.has_method("apply_server_snapshot"):
		_local.apply_server_snapshot(data)

# 服务器广播的对手子弹 → 本地生成确定性视觉副本(不裁决伤害,只出轨迹/特效)。
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
		b.blast_force = data.get("blast_force", 0.0)
		b.smoke_duration = data.get("smoke_duration", 0.0)
		if data.has("visual"):
			b.explosion_visual = load(data["visual"])
	b.global_position = data["pos"]
	_world.add_child(b)
	# 敌方武器轨迹(设置开启时):轨迹线挂在视觉副本子弹上
	if Settings.pvp_show_trajectories:
		BulletTrail.attach(b, data["color"])

# 服务器权威开火(即时光束武器,激光):对手端据此画光束视觉副本(不开物理子弹,
# 无 bullet_spawn 实体可跟)。原始 pts 在射手 canonical 系(可能隔整幅地图跨接缝)→
# 逐点锚到射手副本当前渲染位置(_remote_replica.global_position 已由 player_replica 每帧
# 归到本地玩家最近副本、滞后 ~1 tick 无碍)。光束整条路径 ≤ bullet_range 远小于半图 →
# 逐点 anchor_to_nearest 会把整条折线搬到可见副本、跨接缝连续。
# 只画对手那发:自己(射手)这发已由本地预测自画,再收服务器版会双光束。
## 服务器权威烟雾区:本地同步建区(视觉 + 可见性规则用)
func _on_smoke_event(data: Dictionary) -> void:
	if _world == null:
		return
	Smoke.spawn_zone(_world, data.get("pos", Vector2.ZERO), float(data.get("radius", 220.0)),
			float(data.get("duration", 6.0)))

func _on_beam_fired(data: Dictionary) -> void:
	if _world == null or _remote_replica == null:
		return
	if int(data.get("shooter_role", 0)) == PvpSession.role:
		return
	var raw: PackedVector2Array = data.get("pts", PackedVector2Array())
	if raw.is_empty():
		return
	var anchor: Vector2 = (_remote_replica as Node2D).global_position
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

# 服务器裁决命中:被打的是自己 → 即时反馈(白闪/击退),血量以快照权威为准;
# 被打的是对手 → 副本受击闪烁,让射手看到自己打中了。
func _on_hit_event(victim_role: int, damage: int, source_pos: Vector2) -> void:
	if _local == null:
		return
	if victim_role == PvpSession.role:
		_local.take_hit(source_pos, damage, false, -1.0)
	elif _remote_replica != null and _remote_replica.has_method("play_hit"):
		_remote_replica.play_hit(source_pos)

# 命中确认(服务器裁决的弹直击,NetBusExt):我是射手 → 屏幕中心 X 标记(FPS 式命中反馈)
func _on_hit_confirm(shooter_role: int, _victim_role: int) -> void:
	if shooter_role == PvpSession.role:
		CombatFeedback.hit_marker()

# 击杀播报:我击杀对手 → 屏幕中央「击杀 XXX」+ 音效(被击杀的是自己则不播)
func _on_kill_event(killer: int, victim: int) -> void:
	if killer == PvpSession.role and victim != PvpSession.role:
		CombatFeedback.kill(str(_names.get(victim, "对手")))
	elif victim == PvpSession.role:
		CombatFeedback.reset_streak()   # 自己被击杀 → 连杀清零

# 服务器拆墙事件:客户端子弹是视觉副本不判伤害,用大伤害触发 damage_tile 走 Level0 拆墙渲染。
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
			tex = int(row[cell.x]) / 16
	TileDefs.damage_tile(cell, 999999, "explosion")
	# PvP 拆砖是服务器权威、客户端不本地拆 → 这里补播碎片粒子(只播视觉,不影响权威)
	var ts := GameParameters.TILE_SIZE
	TileHitFx.spawn(_world, Vector2(cell.x * ts + ts * 0.5, cell.y * ts + ts * 0.5), tex)

# 回合状态:
#  - COUNTDOWN 且 round>1(新一轮):服务器已把可破坏砖还原 + 清子弹,这里同刻清本地子弹并复位砖,
#    保证两端从同一基线出发,不残留"多拆/少拆"的幽灵碰撞、旧子弹不跨局冒出。
#  - MATCH_OVER → 延时后断连回主菜单(记分/胜利失败显示由 PvpHud 负责)。
func _on_round_state(data: Dictionary) -> void:
	var state := int(data.get("state", 0))
	# COUNTDOWN(开局/换局 3 秒):锁本地武器开火(移动由服务器权威冻结,本地玩家服务器渲染自然不动)。
	if _local != null and _local.has_method("set_controls_locked"):
		_local.set_controls_locked(state == 0)
	if state == 0 and int(data.get("round", 1)) > 1:   # COUNTDOWN,新一轮
		for b in get_tree().get_nodes_in_group("bullet"):
			if is_instance_valid(b):
				(b as Node).queue_free()
		if _level0 != null and _level0.has_method("reset_destructibles"):
			_level0.reset_destructibles()
	elif state == 3:   # MatchHost.RoundState.MATCH_OVER
		_match_ended = true
		get_tree().create_timer(5.0).timeout.connect(func() -> void:
			NetBus.stop()
			Level0.safe_change_scene(get_tree(), "res://Scenes/main_menu.tscn"))

# 对手中途断线:播报 + 短暂停留后回主菜单(1v1 无法继续)。
func _on_opponent_left() -> void:
	if _match_ended or _local == null:
		return
	_match_ended = true
	if _hud != null:
		_hud.show_notice("对手已离开", "对局结束")
	get_tree().create_timer(2.5).timeout.connect(func() -> void:
		NetBus.stop()
		Level0.safe_change_scene(get_tree(), "res://Scenes/main_menu.tscn"))

# ── 中立鸟(服务器权威):roster → 建视觉副本;每帧快照 apply_remote;died → 移除 ──
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

# 角色染色:自己 = 设置里选的色相(即选即用);对手 = 对方 claim_role 上报的色相(见 _on_peer_info)。
# 只给角色 AnimatedSprite2D 挂 hue shader(COLOR 乘回 → 受击白闪/无敌半透明仍正常),武器不染。
func _apply_p2_tint() -> void:
	if _local != null:
		_apply_tint(_local.get_node_or_null("AnimatedSprite2D"), Settings.pvp_color_hue)


func _apply_tint(body: Node, hue_deg: float) -> void:
	var canvas := body as CanvasItem
	if canvas == null or is_zero_approx(hue_deg):
		return
	var mat := ShaderMaterial.new()
	mat.shader = load("res://Scenes/Player/player_p2_hue.gdshader")
	mat.set_shader_parameter("hue_shift", hue_deg)
	canvas.material = mat

# ── 头上 ID:worker 开局广播 peer_info({role:int -> 昵称})(原版协议)──
func _on_peer_info(names: Dictionary) -> void:
	_names = names
	_ensure_id_labels()
	if _id_self == null or _id_opp == null:
		return
	var me := PvpSession.role
	var opp := 3 - me
	var nm_self := str(names.get(me, PvpSession.player_name))
	var nm_opp := str(names.get(opp, "对手"))
	_id_self.set_label(nm_self, ROLE_COLOR.get(me, Color.WHITE))
	_id_opp.set_label(nm_opp, ROLE_COLOR.get(opp, Color.WHITE))
	_apply_opp_hue()

# 对手角色颜色:走扩展 peer_hues(原版 worker 不发 → 缺省回落旧规则 P2 -65)
func _on_peer_hues(hues: Dictionary) -> void:
	_opp_hues = hues
	_apply_opp_hue()

func _apply_opp_hue() -> void:
	if _remote_replica == null:
		return
	var opp := 3 - PvpSession.role
	_apply_tint(_remote_replica.get_node_or_null("AnimatedSprite2D"),
			float(_opp_hues.get(opp, -65.0 if opp == 2 else 0.0)))

# 服务器下发的生效选项:同步禁用武器(本地数字键/滚轮同样被挡,出生枪自动改首个启用槽)
func _on_match_options(opts: Dictionary) -> void:
	var disabled: Array[int] = []
	for v in opts.get("disabled_weapons", []):
		disabled.append(int(v))
	PvpSession.disabled_weapons = disabled
	if _local != null:
		_local.weapons.set_enabled_slots(disabled)

func _ensure_id_labels() -> void:
	if _world == null:
		return
	if _id_self == null:
		_id_self = load("res://Scenes/Player/world_label.gd").new()
		_world.add_child(_id_self)
	if _id_opp == null:
		_id_opp = load("res://Scenes/Player/world_label.gd").new()
		_world.add_child(_id_opp)

func _process(_delta: float) -> void:
	_apply_smoke_visibility()   # 烟雾:烟雾内实体不可见/自己在烟雾内只见地图与自己
	# 贴到头顶:独立于玩家旋转(倒地转体不影响文字);本地玩家恒在中间副本。
	if _id_self != null and _local != null:
		_id_self.global_position = _local.global_position + ID_HEAD_OFFSET
	if _id_opp != null and _remote_replica != null and is_instance_valid(_remote_replica):
		_id_opp.global_position = (_remote_replica as Node2D).global_position + ID_HEAD_OFFSET
	# 对手血条贴在 ID 上方(倒地转体不影响,世界空间独立节点)
	if _hp_bar != null and _remote_replica != null and is_instance_valid(_remote_replica):
		_hp_bar.global_position = (_remote_replica as Node2D).global_position + Vector2(0.0, -116.0)


# 服务器权威爆炸视效:榴弹多次弹开后本地预测与服务器模拟分叉,爆炸位置一律以广播为准
# (伤害本就只在服务器结算;见 bullet_base._explode 与 NetBusExt.explosion_event)。
func _on_explosion_event(pos: Vector2, _radius: float) -> void:
	if _world == null:
		return
	var fx: Node = preload("res://Scenes/Effects/explosion.tscn").instantiate()
	fx.global_position = pos
	_world.add_child(fx)
	Sfx.play("explosion")
