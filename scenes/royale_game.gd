extends Node2D
# 大乱斗对局客户端(RoyaleServer 分支):Level0(pvp_mode) 世界 + 本地玩家(服务器渲染)
# + N-1 个远端副本 + 后处理 + 输入上报 + 快照消费 + RoyaleHud(左上角击杀排行榜)。
# 与 pvp_client 的差别:对手是 1..N 个(按快照 roles 动态建副本),HUD 用 RoyaleHud。

const TileHitFx := preload("res://scenes/effects/tile_hit_fx.gd")
const LaserVisual := preload("res://core/laser_visual.gd")

var _last_snap_tick := 0
var _local: Node2D = null
var _replicas: Dictionary = {}         # role(int) -> PlayerReplica(自己以外的全部角色)
var _enemy_replicas: Dictionary = {}   # bird_id(int) -> EnemyReplica
var _level0: Node = null
var _world: Node = null
var _hud: RoyaleHud = null
var _pause_menu: PauseMenu = null   # ESC 菜单(MATCH_OVER 后销毁以失效,见 _on_round_state)
var _match_ended := false
var _round_locked := false   # COUNTDOWN 冻结态(见 _on_round_state;出生点校正只在这期间做)
var _ping_acc := 0.0

# ── C2 客户端预测(与 pvp_client 同一套;见 docs/superpowers/specs/2026-09-12-royale-c2-migration-design.md)──
# 本地玩家由引擎自步进(读真实 Input,aim/手感=单机);本场景每物理帧在它步进前
# note_post_step + reconcile,把服务器外部事件(复活瞬移/受击/击杀复位)收敛掉。
var _rollback = null            # PredictionRollback
var _input_seq := 0             # 本地每物理帧单调的输入序号(服务器 1/tick 消费并回带 ack)
var _have_prev_seq := false
var _prev_sent_seq := 0
var _menu_open := false         # ESC 菜单是否开着(PvP 下菜单不暂停树,靠这个锁输入)

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
	MazeGenerator.set_map_file(PvpSession.map_path)
	GameParameters.refresh_map_size()
	Level0.pvp_mode = true
	var level0: Node = load("res://scenes/Level0.tscn").instantiate()
	add_child(level0)
	_level0 = level0
	_world = level0.get_node("WorldViewport")
	var local: Node2D = _world.get_node("Player")
	var ts := GameParameters.TILE_SIZE
	local.position = Vector2(PvpSession.spawn.x * ts + ts / 2.0, PvpSession.spawn.y * ts + ts / 2.0)
	# 与对手(层2)物理碰撞:服务器侧 match_host 已给每个玩家 mask |= 2,客户端本地玩家也必须,
	# 否则本地预测直接穿过对手副本、服务器却挡住 → 每帧分歧回滚(C2 的无限回滚循环)。
	# 对手那一侧由 player_replica 的幽灵碰撞体提供(层2)。**不改 Player.tscn**:那会让
	# enemy_logic_smoke 的「player mask == 5」断言变红,且单机不需要这一位。
	local.collision_mask |= 2
	_local = local
	# C2:本地玩家跑预测(engine 自步进),控制器绑定;权威从本人包的 ack_seq/c2 喂入。
	# ★ 这里**不再 set_server_rendered** —— 服务器渲染那条路径已整体删除(设计 §0「彻底删干净」),
	#   全项目只剩一条联机链路。
	_rollback = PredictionRollback.new()
	_rollback.bind(_local)
	# 环面尺寸:分歧判定要用它取最短向量,否则跨接缝那一帧客户端与服务器相差一整幅地图宽
	# 会被误判成分歧、白跑一次回滚(见 PredictionRollback._pos_dist)。**不设 = 静默惰性**:
	# 不报错,只是那修复不生效 —— 故 tests/rollback_fidelity_probe 有源码守卫钉这一行。
	_rollback.map_px = Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	var pp := PostProcess.new()
	pp.world_viewport = level0.get_node("WorldViewport")
	call_deferred("add_child", pp)
	# 血条(他人,设置开启时;具体 role 的实例随副本在快照里懒建)
	# 快照/事件消费
	# 快照**拆两条**(2026-09-12):①世界包=全部玩家的渲染字段(副本/HUD 取它);
	# ②本人包=自己的 ack_seq + c2(**只有本人需要**,C2 rollback 拿它锚定/重放)。
	NetBus.local_snapshot_world.connect(_on_snapshot_world)
	NetBus.local_snapshot_own.connect(_on_snapshot_own)
	NetBus.local_bullet_spawn.connect(_on_bullet_spawn)
	NetBus.local_beam_fired.connect(_on_beam_fired)   # 大乱斗非射手端激光视觉副本(与 pvp_client 同款)
	NetBus.local_hit_event.connect(_on_hit_event)
	NetBus.local_tile_destroyed.connect(_on_remote_tile_destroyed)
	NetBus.local_round_state.connect(_on_round_state)
	NetBus.local_enemy_spawn.connect(_on_enemy_spawn)
	NetBus.local_enemy_died.connect(_on_enemy_died)
	NetBusExt.local_hit_confirm.connect(_on_hit_confirm)
	NetBus.local_kill_event.connect(_on_kill_event)
	NetBus.local_match_sync.connect(_on_match_sync)   # 进场拉取的应答(取代旧的推送+大厅缓存交接)
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
	_pause_menu = PauseMenu.new(true)
	# 本地输入锁必须宿主接线:PvP 不暂停树,不锁就是"菜单开着还能边跑边开枪"。
	# 这一条被 set_server_rendered 掩盖过一整个阶段 —— 服务器渲染下本地玩家本就不走输入物理,
	# 接 C2 后不补就是真的能边跑边开枪。
	_pause_menu.toggled.connect(func(open: bool) -> void:
		_menu_open = open
		_refresh_input_lock())
	add_child(_pause_menu)
	# 自己的染色(设置色相)
	_apply_tint(_local.get_node_or_null("AnimatedSprite2D"), Settings.pvp_color_hue)
	# ★ 进场**主动拉**一次(昵称/色相/生效选项/出生点)。本场景此刻已建好并订阅齐了才开口要,
	#   故不存在"推给一个正在切场景的客户端"那个竞态(B2 的根因)。晚到也无所谓。
	NetBus.rpc_id(1, "match_sync")
	print("进入大乱斗:角色 %d 出生点 %s" % [PvpSession.role, PvpSession.spawn])


# 进场拉取的应答。三个 handler 幂等(改名/染色/设禁用槽位),重复应用无害。
func _on_match_sync(payload: Dictionary) -> void:
	var names: Dictionary = payload.get("names", {})
	if not names.is_empty():
		_on_peer_info(names)
	var hues: Dictionary = payload.get("hues", {})
	if not hues.is_empty():
		_on_peer_hues(hues)
	var opts: Dictionary = payload.get("options", {})
	if not opts.is_empty():
		_on_match_options(opts)
	var sp: Dictionary = payload.get("spawns", {})
	if sp.has(PvpSession.role):
		var want: Vector2i = sp[PvpSession.role]
		if want != PvpSession.spawn:
			push_warning("大乱斗 match_sync: 出生点与 match_start 不一致(%s vs %s),以 sync 为准" % [
					str(PvpSession.spawn), str(want)])
			PvpSession.spawn = want
			_correct_local_spawn()


# 见 pvp_client 的同名方法:只在开局倒计时里校正,已打起来就不硬拉。
func _correct_local_spawn() -> void:
	if _local == null or not _round_locked:
		return
	var ts := GameParameters.TILE_SIZE
	_local.global_position = Vector2(PvpSession.spawn.x * ts + ts / 2.0,
			PvpSession.spawn.y * ts + ts / 2.0)


func _physics_process(_delta: float) -> void:
	if _local == null:
		return
	_ping_acc += _delta
	if _ping_acc >= 0.5:
		_ping_acc = 0.0
		NetBus.send_ping()
	# C2:玩家由引擎自步进(读真实 Input)。这里在它本帧步进前——先把上一 seq 的预测整态入 ring,
	# 再 reconcile 到期权威(分歧 → restore+重放重对齐)。顺序:先记预测态,reconcile 才比得上 ring[C]。
	if _rollback != null:
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
		"seq": _input_seq,   # 单调输入序号(服务器按序消费并回带 ack,rollback 用)
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
	if _rollback != null:
		_rollback.note_input(_input_seq, pkt)   # 供回滚重放使用

func _on_snapshot_world(snap: Dictionary) -> void:
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
		if role != PvpSession.role:
			_ensure_replica(role)
			var r: Node2D = _replicas[role]
			if r != null and r.has_method("apply_snapshot"):
				r.apply_snapshot(data, _local.global_position, snap_tick)
				if _hp_bars.has(role):
					_hp_bars[role].ratio = float(data.get("hp", PlayerParams.player_max_hp)) \
							/ float(PlayerParams.player_max_hp)
		# ★ 自己那一份**刻意不消费**:C2 下本地玩家由引擎自步进,权威整态走**本人包**
		#   (见 _on_snapshot_own)。把世界包里自己那份写进玩家 = "每帧把权威位置强写进正在预测的
		#   玩家" = 橡皮筋 —— 那正是被删掉的那条旧路径的写法。别顺手补回来。
		#   (顺带:"你死了/你活了"这件事服务器经 round_state 的 alive 广播过,但那**不是**给
		#    C2 玩家状态用的第二条入口 —— 权威只走 on_authoritative。见 tests/royale_c2_watcher.gd 的 A②。)
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

# 本人包:只有自己需要的 ack_seq + 权威整态 c2。C2 下喂 rollback 控制器。
# 拆包的一个附带好处:它与世界包**互不连累** —— c2 丢只少一个回滚锚点(下一个快照补上),
# 世界包丢只让副本插值冻结一帧。
func _on_snapshot_own(own: Dictionary) -> void:
	if _rollback == null:
		return
	var c2: Dictionary = own.get("c2", {})
	if not c2.is_empty():
		_rollback.on_authoritative(int(own.get("ack_seq", 0)), c2)


# 懒建远端副本(按快照里出现的 role)—— 大乱斗对手数量不定
func _ensure_replica(role: int) -> void:
	if _replicas.has(role) and is_instance_valid(_replicas[role]):
		return
	var replica: Node2D = preload("res://scenes/player/player_replica.tscn").instantiate()
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

# 服务器权威开火(激光):逐点锚到**射手副本**当前渲染位置再整条画。
# 与 pvp_client._on_beam_fired 的唯一差别:大乱斗有 N 个副本,锚点按 shooter_role 取。
# ★ 必须走 NetBus(不是 NetBusExt):发送端 server/match_host.gd 用的是 NetBus.rpc_id(...);
#   收在 NetBusExt 上会静默 no-op(main 的 core/net_bus_ext.gd 那个同名 RPC 是 KH 遗留重复)。
func _on_beam_fired(data: Dictionary) -> void:
	if _world == null:
		return
	var shooter := int(data.get("shooter_role", 0))
	if shooter == PvpSession.role:
		return                                   # 自己那发已本地预测画过,再收会双光束
	var replica: Node2D = _replicas.get(shooter)
	if replica == null or not is_instance_valid(replica):
		return                                   # 射手副本还没建(快照未到)→ 丢本发
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
		NetBusExt.rpc_id(1, "suicide_request")

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
	_round_locked = state == 0
	if state == 3 and not _match_ended:   # MATCH_OVER → 展示结果 6s 后回主菜单
		_match_ended = true
		# 结算画面的输入锁由下面的 _refresh_input_lock() 统一给(经 _match_ended 那一维)——
		# 自检 L6:这片画面原还能跑动开枪。
		# ★ ESC 菜单随即失效、退出只走定时器这一条路(与 pvp_client 同款):
		#   不销毁菜单的话,玩家能在这 6s 里按 ESC → 回到主菜单(safe_change_scene 已经切过一次),
		#   6s 到点本定时器会**再切一次场景** —— 把刚建出来的主菜单当 old 退役、并 free 掉
		#   _retired 里原本那具游戏世界。后果不致命但结构上是错的,而 pvp_client 正是为此
		#   专门加了这两行(见该文件 MATCH_OVER 分支的注释),大乱斗这条是第三条路径、当年漏了。
		if _pause_menu != null and is_instance_valid(_pause_menu):
			_pause_menu.queue_free()
			_pause_menu = null
		# 捕获 tree/autoload 引用:玩家若已从别的路径离开,本节点会被 safe_change_scene 摘出树,
		# 到点时对不在树上的实例求值会出错(自检 L6)
		var tree := get_tree()
		var netbus := NetBus
		get_tree().create_timer(6.0).timeout.connect(func() -> void:
			netbus.stop()
			if not is_inside_tree():
				return   # 已从别的退出路径离开 → 不再叠加第二次换场
			Level0.safe_change_scene(tree, "res://scenes/main_menu.tscn"))
	_refresh_input_lock()   # 单一收口:三个维度任一成立即锁(见函数定义)


# 本地输入锁的单一收口:冻结期(_round_locked)/ 菜单打开(_menu_open)/ 结算(_match_ended)
# 任一成立就锁。**不要在各调用点各拼一次布尔** —— 那正是"修复波 1 只关住一个方向"的成因。
# ★ 与 pvp_client._refresh_input_lock 的差别:这里多一个 _match_ended —— 大乱斗在 MATCH_OVER
#   要锁住结算画面(自检 L6:原还能跑动开枪),而 pvp_client 的 MATCH_OVER 不锁(它靠别的方式收场)。
func _refresh_input_lock() -> void:
	if _local != null and _local.has_method("set_controls_locked"):
		_local.set_controls_locked(_round_locked or _menu_open or _match_ended)

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
		var r: Node2D = preload("res://scenes/enemies/enemy_replica.gd").new()
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
	var lbl: Node2D = load("res://scenes/player/world_label.gd").new()
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
	mat.shader = load("res://scenes/player/player_p2_hue.gdshader")
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
