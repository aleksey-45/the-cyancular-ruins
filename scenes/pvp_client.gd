extends Node2D
# PvP 客户端对局场景:Level0(pvp_mode) 世界 + 本地玩家(C2 本地模拟) + 后处理 + 输入上报 + 快照消费。

const TileHitFx := preload("res://scenes/effects/tile_hit_fx.gd")
const LaserVisual := preload("res://core/laser_visual.gd")   # 远端光束视觉副本(与本地激光同款)

# ── 本地玩家渲染:完全由服务器快照驱动(放弃客户端预测) ──
# 根因:C2(客户端预测)对梯子等"边沿+位置敏感"机制与服务器权威模拟打架 → 大量回拉。
# 根治:本地玩家不再本地跑移动物理,位置/姿态/朝向由快照插值(与远端副本同款),
#      只保留鼠标瞄准/开火/受击反馈等本地视觉。服务器是唯一真相,天然无回拉。
#
# C2(客户端预测 rollback)开关:true=本地玩家跑本地预测 + PredictionRollback 权威锚定重放;
# false=回落上面这条服务器渲染路径(保底)。复盘见 docs/pvp-c2-retrospective.md(P1-P7)。
# 2026-09-06 使能:服务器 FIFO/ack 已落地、控制器 + reconcile/twin 冒烟全绿、COUNTDOWN 冻结已补。
const LOCAL_PREDICTION_ENABLED := true
var _input_seq := 0   # 本地每物理帧单调的输入序号(服务器 1/tick 消费并回带 ack)
var _last_snap_tick := 0
# C2(开关开):本地玩家跑全量本地 sim 预测 + PredictionRollback 权威锚定重放(见 core/prediction_rollback.gd)。
# 变体 B:不 set_server_rendered、引擎照常自步进(读真实 Input,aim/手感=单机);
# 本客户端每帧在玩家步进前 reconcile,并把每 tick 的预测整态/输入记录喂给控制器。
var _rollback = null
var _have_prev_seq := false
var _prev_sent_seq := 0

var _local: Node2D = null
var _remote_replica: Node2D = null
var _enemy_replicas: Dictionary = {}   # bird_id(int) -> EnemyReplica(中立鸟视觉副本)
var _level0: Node = null   # 世界(Level0):换局复位砖用 reset_destructibles
var _world: Node = null   # WorldViewport(视觉子弹副本挂这里)
var _hud: PvpHud = null
var _pause_menu: PauseMenu = null   # ESC 菜单(打开时锁本地输入;MATCH_OVER 后销毁以失效)
var _match_ended := false      # MATCH_OVER 后回菜单途中,忽略对手断线播报
var _round_locked := false      # COUNTDOWN 冻结态(别把倒计时里提前解锁)
var _menu_open := false         # 暂停菜单是否开着(PvP 下菜单不暂停树,靠这个锁输入)
var _ping_acc := 0.0

# ── 头上 ID(自己/对手昵称):世界空间文字,每帧贴到头顶 ──
const ID_HEAD_OFFSET := Vector2(0.0, -78.0)   # 头顶文字位置(-100 略高,现往下压一点)
# 头顶名字统一中性亮白(不再按角色区分颜色;P2 靠身体色相 shader 区分)。world_label 内部再叠 0.85 alpha。
const NAME_COLOR := Color(0.94, 0.95, 0.98, 1.0)
var _id_self: Node2D = null
var _id_opp: Node2D = null
var _hp_bar: EnemyHpBar = null    # 对手头顶血条(设置开启时创建)
var _minimap: Minimap = null      # 小地图(设置开启时创建)
var _opp_hues: Dictionary = {}    # 双方角色颜色 {role -> 色相}(扩展 peer_hues 下发)
var _names: Dictionary = {}       # role(int) -> 昵称(peer_info 下发;击杀播报取名字用)

func _ready() -> void:
	CombatComponent.pvp_arena = true   # PvP:取消命中无敌帧(每发结算一次)
	MazeGenerator.set_map_file(PvpSession.map_path)
	# 重算世界尺寸:_ready 启动时算的是随机 demo 图(8000 宽),PvP 固定图是 9600 宽,
	# 不重算则本地插值/回绕按错边界 → 玩家在图中间被空气墙弹走。
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
	# 本地玩家改由服务器快照驱动(不做客户端预测):根治梯子等机制"预测 vs 权威"打架回拉。
	# C2(阶段4)开启后:本地玩家跑全量本地 sim 预测,由 pvp_client 接 rollback。
	if not LOCAL_PREDICTION_ENABLED and _local.has_method("set_server_rendered"):
		_local.set_server_rendered(true)
	elif LOCAL_PREDICTION_ENABLED:
		# C2:本地玩家跑预测(engine 自步进),控制器绑定;权威从快照 ack_seq/c2 喂入。
		if _rollback == null:
			_rollback = PredictionRollback.new()
		_rollback.bind(_local)
		# 环面尺寸:分歧判定要用它取最短向量,否则跨接缝那一帧客户端与服务器相差一整幅地图宽
		# 会被误判成分歧、白跑一次回滚(见 PredictionRollback._pos_dist)。**不设 = 静默惰性**:
		# 不报错,只是那修复不生效 —— 故 tests/rollback_fidelity_probe 有源码守卫钉这一行。
		_rollback.map_px = Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	# pvp_mode 下 Level0 不建后处理,这里补(否则 SubViewport 不显示)
	var pp := PostProcess.new()
	pp.world_viewport = level0.get_node("WorldViewport")
	call_deferred("add_child", pp)
	# 远端副本(角色 = 3 - 自己的 role,1v1)
	var replica := preload("res://scenes/player/player_replica.tscn").instantiate()
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
	NetBus.local_beam_fired.connect(_on_beam_fired)
	NetBus.local_hit_event.connect(_on_hit_event)
	NetBus.local_tile_destroyed.connect(_on_remote_tile_destroyed)
	NetBus.local_round_state.connect(_on_round_state)
	NetBus.local_peer_info.connect(_on_peer_info)
	NetBus.local_opponent_left.connect(_on_opponent_left)
	NetBus.local_enemy_spawn.connect(_on_enemy_spawn)
	NetBus.local_enemy_died.connect(_on_enemy_died)
	NetBus.local_kill_event.connect(_on_kill_event)
	# 扩展节点(NetBusExt)三载荷:生效选项/角色色相/命中确认。与 beam_fired 不同节点是**有意的**
	# (发送端 match_host 的 beam_fired 走 NetBus),别顺手把上面那行也统一到 NetBusExt。
	NetBusExt.local_match_options.connect(_on_match_options)
	NetBusExt.local_peer_hues.connect(_on_peer_hues)
	NetBusExt.local_hit_confirm.connect(_on_hit_confirm)
	NetBus.local_match_sync.connect(_on_match_sync)   # 进场拉取的应答(取代旧的推送+大厅缓存交接)
	# 这三条一次性载荷(生效选项/角色色相/昵称表)另有**第二条投递路径**:matchmaking 在换场前
	# 就接住的那一份缓存,由本函数末尾的 _consume_pending_payloads() 取用(见该函数与 PvpSession)。
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
	# 回合记分 HUD(层级盖在 PostProcess/单机 HUD 之上;布局见 pvp_hud.tscn)
	_hud = preload("res://ui/pvp_hud.tscn").instantiate() as PvpHud
	add_child(_hud)
	# 打击反馈层(命中 X 标记/击杀播报)由 Level0 统一挂载,PvP 同样继承它 —— 见 level_0.gd 的
	# _ready:那一挂在建图前、位于 pvp_mode 早退**之前**,而本文件也把该 Level0 挂进世界,
	# 故进 PvP 世界时反馈层已在。**本行有意不写第二次挂载**(不是漏写):CombatFeedback 的早退
	# 要求 current 已非空,而 current 只在 deferred 实例的 _ready 里赋值,同帧第二次调用看到的
	# 还是 null → 真会建出第二份(实测 2 份),并打破「生产路径恰好 1 处挂载点」这条既有断言。
	# 后来者不要照别的分支把这一行补回来。
	# P2 本体色相 -20(区分双方;只染角色 AnimatedSprite2D 本体,武器/预瞄不染)
	_apply_p2_tint()
	# Esc 暂停菜单(PvP:PauseMenu 不暂停树 → 对手实时;回主菜单 = PauseMenu.go_menu 内先
	# NetBus.stop() 断连,worker 检测对局任一方断线即拆局)。开关/退出由 PauseMenu 自理
	# (自带 ui_cancel 处理 + set_input_as_handled),但**本地输入锁必须宿主接线**:PvP 不暂停树,
	# 不锁就是"菜单开着还能边跑边开枪"(旧 EscMenu 靠 toggled 接的正是这一条)。
	_pause_menu = PauseMenu.new(true)
	_pause_menu.toggled.connect(func(open: bool) -> void:
		_menu_open = open
		_refresh_input_lock())
	add_child(_pause_menu)
	# 三载荷的第二条投递路径:载荷早于本场景订阅(一次 poll 吞掉两段 flush)时,matchmaking
	# 已经把它缓存进 PvpSession,这里取用;晚于订阅时走上面三条直接订阅。两条路径互不重叠 ——
	# 一条载荷只被 emit 一次,取用即清空,不会对同一份载荷各应用一次。
	# ⚠ 位置必须在 _apply_p2_tint() **之后**(与 royale_game 把它放在 _apply_tint 之后同理):
	# 那道预染是"无载荷"的落地形态,缓存里的色相要能盖过它(否则对手身体退回 -65 的旧规则)。
	_consume_pending_payloads()
	# ★ 进场**主动拉**一次(昵称/色相/生效选项/出生点)。本场景此刻已经建好、订阅齐了才开口要,
	#   所以不存在"推给一个正在切场景的客户端"那个竞态(B2 的根因)。晚到也无所谓。
	NetBus.rpc_id(1, "match_sync")
	print("进入竞技场:角色 %d 出生点 %s" % [PvpSession.role, PvpSession.spawn])


# 进场拉取的应答。三个 handler 本身幂等(重建禁用表/覆盖染色/重设标签),故与旧的推送路径
# 重复到达也无害(那是迁移期的常态)。
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
			# 不一致就是 bug(两者同源),别静默 —— 留痕后以 sync 为准
			push_warning("match_sync: 出生点与 match_start 不一致(%s vs %s),以 sync 为准" % [
					str(PvpSession.spawn), str(want)])
			PvpSession.spawn = want
			_correct_local_spawn()


# 把本地玩家摆到权威出生点。**只在开局倒计时里做** —— 已经打起来还硬拉,等于把玩家从对局里
# 拽走。正常路径下两者本就相同(同一个源),走到这里说明服务器那边有问题(上面已留警告)。
func _correct_local_spawn() -> void:
	if _local == null or not _round_locked:
		return
	var ts := GameParameters.TILE_SIZE
	_local.global_position = Vector2(PvpSession.spawn.x * ts + ts / 2.0,
			PvpSession.spawn.y * ts + ts / 2.0)

# 取用 matchmaking 缓存的开局三载荷(与 royale_game 的同名函数同款:取用后即清空)。
# 必须在 `_local` / `_remote_replica` / 预染就绪之后调用;三个 handler 自身幂等(重建禁用表/
# 覆盖染色/重设标签文字),故即便载荷两侧都到也只是一次等价重算。
func _consume_pending_payloads() -> void:
	if not PvpSession.pending_peer_info.is_empty():
		_on_peer_info(PvpSession.pending_peer_info)
	if not PvpSession.pending_peer_hues.is_empty():
		_on_peer_hues(PvpSession.pending_peer_hues)
	if not PvpSession.pending_match_options.is_empty():
		_on_match_options(PvpSession.pending_match_options)
	PvpSession.clear_pending_payloads()

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
	if LOCAL_PREDICTION_ENABLED and _rollback != null:
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
		"seq": _input_seq,   # 单调输入序号(阶段3 服务器按序消费并回带 ack,rollback 用)
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
	if LOCAL_PREDICTION_ENABLED and _rollback != null:
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
			if LOCAL_PREDICTION_ENABLED and _rollback != null:
				# C2:权威整态/ack 喂控制器(reconcile 在下一帧步进前处理)
				var ack := int(data.get("ack_seq", 0))
				var c2: Dictionary = data.get("c2", {})
				if not c2.is_empty():
					_rollback.on_authoritative(ack, c2)
			else:
				_apply_local_state(data)
		elif _remote_replica != null and _remote_replica.has_method("apply_snapshot"):
			_remote_replica.apply_snapshot(data, _local.global_position, snap_tick)
			# 对手血条:快照 hp → 比例(上限取 PlayerParams 玩家最大血)
			if _hp_bar != null:
				_hp_bar.ratio = float(data.get("hp", PlayerParams.player_max_hp)) \
						/ float(PlayerParams.player_max_hp)
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

# 击杀播报:我击杀对手 → 屏幕中央「击杀 XXX」+ 音效(被击杀的是自己则不播)
func _on_kill_event(killer: int, victim: int) -> void:
	if killer == PvpSession.role and victim != PvpSession.role:
		CombatFeedback.kill(str(_names.get(victim, "对手")))
	elif victim == PvpSession.role:
		CombatFeedback.reset_streak()   # 自己被击杀 → 连杀清零

# 命中确认(服务器裁决的弹直击,走 NetBusExt):我是射手 → 屏幕中心 X 标记(FPS 式命中反馈)。
# 被射手不是自己(对手打中我)时不播 —— 那条反馈由 hit_event 的受击白闪/击退负责。
func _on_hit_confirm(shooter_role: int, _victim_role: int) -> void:
	if shooter_role == PvpSession.role:
		CombatFeedback.hit_marker()

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
	_round_locked = state == 0
	_refresh_input_lock()   # 单一收口:菜单开着时不解锁(见 _refresh_input_lock)
	if state == 0 and int(data.get("round", 1)) > 1:   # COUNTDOWN,新一轮
		for b in get_tree().get_nodes_in_group("bullet"):
			if is_instance_valid(b):
				(b as Node).queue_free()
		if _level0 != null and _level0.has_method("reset_destructibles"):
			_level0.reset_destructibles()
	elif state == 3:   # MatchHost.RoundState.MATCH_OVER
		_match_ended = true
		# ESC 菜单随即失效(旧 EscMenu 靠 can_toggle=false 挡):否则玩家可提前回主菜单,而下面
		# 这条 5s 定时器仍会再触发一次 safe_change_scene(已在主菜单上再切一次 = 行为可疑)。
		# 直接销毁菜单 —— 退出只走定时器这一条路。
		if _pause_menu != null and is_instance_valid(_pause_menu):
			_pause_menu.queue_free()
		_menu_open = false
		# 菜单没了 → 回到只由 _round_locked(state 3 → false)决定 = 解锁(与旧行为一致)
		_refresh_input_lock()
		# 起定时器**之前**捕获 tree/netbus:lambda 里现取 get_tree() 是到点才求值,而那时本节点
		# 可能已被别的退出路径换场摘树 → 返回 null → 报错(兄弟场景 royale_game 的同一处修法)。
		var tree := get_tree()
		var netbus := NetBus
		get_tree().create_timer(5.0).timeout.connect(func() -> void:
			netbus.stop()
			if not is_inside_tree():
				return   # 已从别的退出路径(ESC/暂停菜单)离开 → 不再叠加第二次换场
			# 游戏世界含全量碰撞,裸 change_scene_to_file 会同步 memdelete → 偶发原生段错误,
			# 故走游戏世界的退役挂起式换场(与路径①同机制)。
			Level0.safe_change_scene(tree, "res://scenes/main_menu.tscn"))

# 本地输入锁的单一收口:冻结期(_round_locked)与菜单打开(_menu_open)任一成立就锁。
# 不要在两个调用点各拼一次布尔 —— 那正是修复波 1 只关住一个方向的原因。
func _refresh_input_lock() -> void:
	if _local != null and _local.has_method("set_controls_locked"):
		_local.set_controls_locked(_round_locked or _menu_open)

# 对手中途断线:播报 + 短暂停留后回主菜单(1v1 无法继续)。
func _on_opponent_left() -> void:
	if _match_ended or _local == null:
		return
	_match_ended = true
	if _hud != null:
		_hud.show_notice("对手已离开", "对局结束")
	# 同 MATCH_OVER 那条:先在起定时器前捕获引用,并让到点的 lambda 在"已经离开"时不再叠加
	# 第二次换场(玩家可以在这 2.5s 内按 ESC → 暂停菜单 → 回到主菜单)。
	var tree := get_tree()
	var netbus := NetBus
	get_tree().create_timer(2.5).timeout.connect(func() -> void:
		netbus.stop()
		if not is_inside_tree():
			return
		Level0.safe_change_scene(tree, "res://scenes/main_menu.tscn"))

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

# P2(role 2)玩家角色本体色相 -20:自己控 P2 → 染本地玩家;自己控 P1 → 染对手副本。
# 只给角色 AnimatedSprite2D 挂 hue shader(COLOR 乘回 → 受击白闪/无敌半透明仍正常),武器不染。
func _apply_p2_tint() -> void:
	var body: Node = null
	if PvpSession.role == 2 and _local != null:
		body = _local.get_node_or_null("AnimatedSprite2D")
	elif PvpSession.role == 1 and _remote_replica != null:
		body = _remote_replica.get_node_or_null("AnimatedSprite2D")
	var canvas := body as CanvasItem
	if canvas == null:
		return
	var mat := ShaderMaterial.new()
	mat.shader = load("res://scenes/player/player_p2_hue.gdshader")
	mat.set_shader_parameter("hue_shift", -65.0)   # P2 本体色相旋转 -65°
	canvas.material = mat

# 通用身体染色:只给角色本体 AnimatedSprite2D 挂 hue shader(COLOR 乘回 → 受击白闪/
# 无敌半透明仍正常),武器/预瞄线不染。色相 0 = 不改色(不挂 shader),故本助手可重复调用。
func _apply_tint(body: Node, hue_deg: float) -> void:
	var canvas := body as CanvasItem
	if canvas == null or is_zero_approx(hue_deg):
		return
	var mat := ShaderMaterial.new()
	mat.shader = load("res://scenes/player/player_p2_hue.gdshader")
	mat.set_shader_parameter("hue_shift", hue_deg)
	canvas.material = mat

# 对手身体颜色:走扩展 peer_hues(每个 role 上报自己选的色相)。载荷未到 / 缺本对手项时,
# 缺省回落与 _apply_p2_tint 同一条旧规则(P2 本体 -65,其余不染)——故 _ready 里那次
# _apply_p2_tint() 是无载荷时的落地形态,本函数是载荷到达后的覆盖。
# 头顶名不在这里上色:名统一中性亮白,色相只区分身体(见 NAME_COLOR 处的说明)。
func _on_peer_hues(hues: Dictionary) -> void:
	_opp_hues = hues
	_apply_opp_hue()

func _apply_opp_hue() -> void:
	if _remote_replica == null:
		return
	var opp := 3 - PvpSession.role
	_apply_tint(_remote_replica.get_node_or_null("AnimatedSprite2D"),
			float(_opp_hues.get(opp, -65.0 if opp == 2 else 0.0)))

# 服务器下发的生效选项:同步禁用武器(本地数字键/滚轮同样被挡,出生枪自动改首个启用槽)。
# ★ 两端必须同表:本端 equip 对禁用槽会当场拒绝,而输入包里的切枪请求是**无条件**上行的 ——
#   服务器若无同一张表就会 equip 成功,两端槽位错位,且权威槽位每帧把我们拉回去 ——
#   每帧重试、永久错位(静默,不报错)。服务器端(MatchHost)已落地,这里补的是客户端这一端。
# 信号可能早于/晚于本场景 _ready 到达,故 _local 判空。
func _on_match_options(opts: Dictionary) -> void:
	var disabled: Array[int] = []
	for v in opts.get("disabled_weapons", []):
		disabled.append(int(v))
	PvpSession.disabled_weapons = disabled
	if _local != null:
		_local.weapons.set_enabled_slots(disabled)

# ── 头上 ID:worker 开局广播 peer_info({role:int -> 昵称}),两端据此显示自己/对手昵称 ──
func _on_peer_info(names: Dictionary) -> void:
	_names = names
	_ensure_id_labels()
	if _id_self == null or _id_opp == null:
		return
	var me := PvpSession.role
	var opp := 3 - me
	var nm_self := str(names.get(me, PvpSession.player_name))
	var nm_opp := str(names.get(opp, "对手"))
	_id_self.set_label(nm_self, NAME_COLOR)
	_id_opp.set_label(nm_opp, NAME_COLOR)

func _ensure_id_labels() -> void:
	if _world == null:
		return
	if _id_self == null:
		_id_self = load("res://scenes/player/world_label.gd").new()
		_world.add_child(_id_self)
	if _id_opp == null:
		_id_opp = load("res://scenes/player/world_label.gd").new()
		_world.add_child(_id_opp)

func _process(_delta: float) -> void:
	# 贴到头顶:独立于玩家旋转(倒地转体不影响文字);本地玩家恒在中间副本。
	if _id_self != null and _local != null:
		_id_self.global_position = _local.global_position + ID_HEAD_OFFSET
	if _id_opp != null and _remote_replica != null and is_instance_valid(_remote_replica):
		_id_opp.global_position = (_remote_replica as Node2D).global_position + ID_HEAD_OFFSET
	# 对手血条贴在 ID 上方(倒地转体不影响,世界空间独立节点)
	if _hp_bar != null and _remote_replica != null and is_instance_valid(_remote_replica):
		_hp_bar.global_position = (_remote_replica as Node2D).global_position + Vector2(0.0, -116.0)

