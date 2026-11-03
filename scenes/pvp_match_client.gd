class_name PvpMatchClient
extends Node2D

# PvP 对局客户端的共享基类(1v1 pvp_client / 大乱斗 royale_game / 3v3 team_game 都 extends 它)。
# ★ 判据是"剔掉注释后的代码是否逐字相同"(不是"看起来像"):凡两个模式语义相同的都上提到这里,子类只留真正的差异(1 个固定副本 vs N 个按 role 动态、HUD 类、退场是否锁 _match_ended、_ready)。要再上提一批,先按同样口径量一遍差异(剔注释后逐行 diff),别凭印象搬。

const LaserVisual := preload("res://core/present/laser_visual.gd")   # 远端光束视觉副本(与本地激光同款)
const HitShape := preload("res://core/sim/hit_shape.gd")   # 受击判定几何唯一入口(客户端 cull)

# ── 共享状态(两个模式同名同义;子类不要再声明一次)──
var _local: Node2D = null
var _world: Node = null   # WorldViewport(视觉子弹/TileHitFx 副本挂这里)
var _level0: Node = null  # 世界(Level0):补态那一路要还原可破坏砖(见 _on_match_sync)
# ── 副本表(大乱斗 / 3v3 两个 N-副本模式共用;1v1 走单副本 _remote_replica,本表恒空)──
# _replicas 由 _replica_set 单写;字段留在宿主是因为 tests/harness/team_match_watcher.gd 直接读它数副本。
var _replicas: Dictionary = {}
var _replica_set: ReplicaSet = null   # 副本集合 / 快照消费 / 头顶标签(已 bind 到上面那份 _replicas)
var _names: Dictionary = {}           # role(int) -> 昵称(match_sync 下发;击杀播报与结算页取名字用)
var _round_locked := false      # COUNTDOWN 冻结态(别把倒计时里提前解锁)
var _ping_acc := 0.0
# C2 客户端预测:见 core/prediction_rollback.gd 与 docs/eng/netcode-snapshots.md。
var _rollback = null            # PredictionRollback
# 受击事件队列:网络回调跑在 idle 帧,而注入要重放(内部 move_and_slide)—— 物理帧外 move_and_slide 位移恒 0(实测),
# 故回调只入队,统一在下一个物理帧开头注入(反馈最多晚 1 帧 ≈16.7ms)。
var _pending_hit_events: Array = []   # [[source_pos: Vector2, damage: int, seq: int], ...]
const PredictionContact := preload("res://core/net/prediction_contact.gd")   # 贴身判据/动态容差(纯函数)
const ReplicaScript := preload("res://scenes/player/player_replica.gd")      # 要它的 GROUP 常量(副本没 class_name)
var _contact_grace_left := 0.0   # 贴身容差迟滞剩余秒(见 PredictionContact.CONTACT_GRACE_S;纯本地量,不上行)
# ── 输入上行(每 tick 采样 → PacketInputSource.pack_record → encode_input → 发包(60Hz) → ack/seq 记账 → netstat)──
var _input_uplink: InputUplink = null


func _ensure_input_uplink() -> InputUplink:
	if _input_uplink == null:
		_input_uplink = InputUplink.new()
		_input_uplink.bind(self)
	return _input_uplink


# 本端**最近成功解码并应用**的服务器世界快照 tick(2026-10-24 从子类上提到基类 — 输入包要带 st;P1.5 起合并判定在 NetBus)。
# ★ 解码失败/基准断了被丢弃的包不算(st 与增量基线都读它;三个模式的 _on_snapshot_world 仍按"每包完整"处理)。
# ★ 数据入口:由三个子类的 _on_snapshot_world / ReplicaSet 写;输入上行组件经 bind 读它组输入包的 st 字段 —— 别搬进组件。
var _last_snap_tick := 0
# MATCH_OVER 之后回菜单途中:忽略对手断线播报,也让输入锁把它算作一维(见 _refresh_input_lock)。
var _match_ended := false
# 暂停菜单是否开着(PvP 下菜单不暂停树,靠它锁本地输入;见 _refresh_input_lock)。
var _menu_open := false
# ESC 暂停菜单(打开时锁本地输入;MATCH_OVER 后销毁以失效)。2026-10-22 从三个子类各一份收上来 ——
# 回合状态模板要在基类里销毁它(ESC 双语义的硬依赖),基类拿不到子类声明的字段。
var _pause_menu: PauseMenu = null
var _last_round_state: Dictionary = {}      # 最近一条 round_state(结算载荷的输入之一)
# 「新一局」分支(清子弹 / 复位砖 / 3v3 重拉 match_sync)已经跑过的局号 —— 边沿触发的记账,见 _on_round_state。
var _countdown_round_seen := 0

# 玩家本体精灵(player.png)的主色(RGB)。
const BODY_BASE_COLOR := UiFactory.C_TEAM_A   # #639BFF(本体主色 == 队 1 token)


# 通用身体染色:只给角色本体 AnimatedSprite2D 上色(武器/预瞄线不染)。唯一机制 = modulate 比值(目标色 / 本体主色):
# 输出 = 主色像素 × 比值 = 恰好目标色本身,且与头顶 ID / 小地图点位同源同一个常量;队 1 的比值恰为 (1,1,1) ⇒ 队 1 的身体就是默认蓝。
# ★★ 颜色不再由玩家自选:1v1 固定 P1 蓝 / P2 青,3v3 用队色,大乱斗按 role 从 ROLE_COLORS 自动取 —— 故本函数只有 color_override 一条路。
func _apply_tint(body: Node, color_override: Color) -> void:
	var canvas := body as CanvasItem
	if canvas == null:
		return
	canvas.modulate = Color(color_override.r / BODY_BASE_COLOR.r,
			color_override.g / BODY_BASE_COLOR.g,
			color_override.b / BODY_BASE_COLOR.b)

func _correct_local_spawn() -> void:
	if _local == null or not _round_locked:
		return
	var ts := GameParameters.TILE_SIZE
	_local.global_position = Vector2(PvpSession.spawn.x * ts + ts / 2.0,
			PvpSession.spawn.y * ts + ts / 2.0)
	# 校正后立刻落稳:只摆到格子中心会再差一层地面高度(见 _settle_local_spawn)。

	_settle_local_spawn(_local)


# ── 三模式同构引导(2026-11-02 从三个子类 _ready 上提:三个文件原先各有一份 ~95 行逐字相同的引导)──
func _boot_world() -> void:
	CombatComponent.pvp_arena = true   # PvP:取消命中无敌帧(每发结算一次)
	MazeGenerator.set_map_file(PvpSession.map_path)
	# 重算世界尺寸:_ready 启动时算的是随机 demo 图(8000 宽),PvP 固定图是 9600 宽;不重算则本地插值/回绕按错边界 ⇒ 玩家在图中间被空气墙弹走。
	GameParameters.refresh_map_size()
	Level0.pvp_mode = true
	var level0: Node = load("res://scenes/level_0.tscn").instantiate()
	add_child(level0)
	_level0 = level0
	_world = level0.get_node("WorldViewport")
	var local: Node2D = _world.get_node("Player")
	var ts := GameParameters.TILE_SIZE
	local.position = Vector2(PvpSession.spawn.x * ts + ts / 2.0, PvpSession.spawn.y * ts + ts / 2.0)
	# 出生即落稳(见 _settle_local_spawn):服务器已站地面,客户端从格子中心自由落体会差几 px ⇒ 首条 ack 判一次回滚。
	_settle_local_spawn(local)
	# 与对手(层 2)物理碰撞:服务器侧已给每个玩家 mask |= 2,客户端本地玩家也必须,否则本地预测直接穿过对手副本、服务器却挡住 ⇒ 每帧分歧回滚(C2 的无限回滚循环);对手那侧由 player_replica 的幽灵碰撞体提供。
	local.collision_mask |= 2
	_local = local
	_rollback = PredictionRollback.new()
	_rollback.bind(_local)
	# 环面尺寸:分歧判定要用它取最短向量,否则跨接缝那一帧客户端与服务器相差一整幅地图宽会被误判成分歧、白跑一次回滚(见 PredictionRollback._pos_dist)。
	_rollback.map_px = Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	# pvp_mode 下 Level0 不建后处理,这里补(否则 SubViewport 不显示)。
	var pp := PostProcess.new()
	pp.world_viewport = level0.get_node("WorldViewport")
	add_child.call_deferred(pp)
	# 快照拆两条:① 世界包 = 全部玩家的渲染字段(副本/血条);② 本人包 = 自己的 ack_seq + c2(只有本人需要,C2 rollback 拿它锚定/重放)。
	NetBus.local_snapshot_world.connect(_on_snapshot_world)
	NetBus.local_snapshot_own.connect(_on_snapshot_own)
	NetBus.local_bullet_spawn.connect(_on_bullet_spawn)
	NetBus.local_beam_fired.connect(_on_beam_fired)
	NetBus.local_hit_event.connect(_on_hit_event)
	_subscribe_tile_events()   # 拆砖的两条(格级 + 子格级)必须成对,见基类注释
	NetBus.local_round_state.connect(_on_round_state)
	NetBus.local_kill_event.connect(_on_kill_event)
	# 扩展节点(NetBusExt)载荷:命中确认。
	NetBusExt.local_hit_confirm.connect(_on_hit_confirm)
	NetBus.local_match_sync.connect(_on_match_sync)   # 进场拉取的应答(取代旧的推送+大厅缓存交接)
	_subscribe_ground_weapons()   # 地面武器事件(开局那批走 match_sync,见 _on_match_sync)
	_subscribe_reconnect()        # 断线重连:服务器断开检测 + reclaim 成功后那条 match_start
	# ★ 进场主动拉一次(昵称/角色色/生效选项/出生点/地面武器/destroyed):订阅齐了才开口要,故没有「推给一个正在切场景的客户端」那个竞态。
	# 本行之后的子类装配(HUD / 小地图 / 暂停菜单)不受影响:应答要走网络 poll,最早也在下一帧,本帧内不存在"应答比 HUD 先到"的窗口。
	if NetBus.can_send_to_server():
		NetBus.rpc_id(1, "match_sync")

# 出生落稳:用同一套物理把下落提前跑完(≤8 步,超了放弃 —— 悬空出生点不传送)。必须在 _rollback.bind 之前调用。

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
		CombatFeedback.hit_marker()   # 命中 X 固定画屏幕中心(用户裁定;别搬到目标/对手身上)

func _enter_tree() -> void:
	# 权威爆炸表现同步(服务器在哪炸的,画面就在哪炸)。三个子类各有自己的 _ready,故接线放 _enter_tree。
	NetBusExt.local_explosion.connect(_on_network_explosion)


# 服务器权威爆炸:先收掉本端那颗视觉榴弹(避免它稍后在别处再炸一次),再在权威位置补画爆炸。
# 自己那发若本地视觉榴弹已消失(已自炸过)⇒ 不再补播 —— 专治"双爆"。
func _on_network_explosion(pos: Vector2, shooter_role: int, visual_path: String) -> void:
	if _world == null or _local == null:
		return
	var p := MazeGenerator.anchor_to_nearest(pos, _local.global_position,
			float(GameParameters.MAP_WIDTH), float(GameParameters.MAP_HEIGHT))
	var shooter := _replica_for(shooter_role)
	var want: Node = shooter if shooter != null else (_local if shooter_role == PvpSession.role else null)
	# ★ 2026-10-30 修:对手副本还没建出来时 want == null —— 旧代码仍进下面的筛选,而那一瞬视觉子弹的
	#   `shooter` 也是 null ⇒ `b.shooter != want` 恒 false ⇒ 最近那颗**别人的**榴弹被 queue_free()
	#   (提前消失 / 双爆),大乱斗多榴弹时最易撞。只在能定位射手时才做子弹回收;本机那发(want == _local)照旧回收。
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
			return   # 本机视觉榴弹已自炸过:再补一次就是"双爆"
	if visual_path == "":
		return
	var scene: PackedScene = load(visual_path)
	if scene == null:
		return
	var fx: Node2D = scene.instantiate() as Node2D
	if fx == null:
		return
	_world.add_child(fx)
	fx.global_position = p


func _apply_match_options(opts: Dictionary) -> void:
	var disabled: Array[int] = []
	for v in opts.get("disabled_weapons", []):
		disabled.append(int(v))
	if _local != null:
		_local.weapons.set_enabled_types(disabled)

func _on_snapshot_own(own: Dictionary) -> void:
	if _rollback == null:
		return
	# ★★ 跨纪元的旧 ack 必须丢掉 —— 判据与理由**逐字**搬在 core/net/input_uplink.gd 的 accept_ack()(S-17 第一刀):
	#   本函数只留数据入口,ack 记账(含跨纪元闸)走组件。
	var ack := int(own.get("ack_seq", 0))
	if not _ensure_input_uplink().accept_ack(ack):
		return
	var c2: Dictionary = own.get("c2", {})
	if not c2.is_empty():
		_rollback.on_authoritative(ack, c2)


# silent=true 用于"重连后补破坏态":那些砖是掉线期间被拆的,不是刚被拆的 —— 逐格播碎片会变成一屏不该有的粒子(且几十格同时炸)。
# ── Beta 时间玩法:怀表 HUD(显示镜像;数值权威在服务器,10Hz 下发)── SP 的 WatchHud 直读静态 Level0.grain_account ⇒ PvP 侧就往这个静态挂一份镜像账户,服务器 time_state 到一帧写字段一次,怀表自己在 _process 里滚动/重绘。★ 只在 PvpSession.beta_mode 挂(单机那份由 Level0._ready 建)。
var _time_mirror: GrainAccount = null
var _time_watch: WatchHud = null
var _time_rewinding := false        # 本地预测的回溯态(免伤闸 + 世界底片)
var _haste_dim_t := 0.0             # 加速压暗 ramp(只在发动者本人的视角;他人屏幕不受影响)
var _time_film_t := 0.0             # 底片覆盖度 ramp(≤0.2s 推满)
var _time_mat: ShaderMaterial = null
var _time_sym: Label = null
var _time_haste_mult := 3.0          # 服务器下发的加速倍率(time_state 的 m;预测与视效共用)


func _setup_beta_time_hud() -> void:
	# ★★ 怀表**不再按会话级 PvpSession.beta_mode 决定**:那个标志是跨场景的,从 Beta 菜单进来后转建 1v1 的房主
	NetBusExt.local_time_state.connect(_on_time_state)


func _on_time_state(payload: Dictionary) -> void:
	var m: Dictionary = payload.get(PvpSession.role, {})
	if m.is_empty():
		return
	_time_haste_mult = float(m.get("m", 3.0))
	if _time_mirror == null:
		_time_mirror = GrainAccount.new()
		Level0.grain_account = _time_mirror
		# 首帧 time_state = 这局确实是 Beta 时间玩法 ⇒ 这时才挂怀表(账户已就位,WatchHud._ready 不会再把自己藏起来)。
		if _time_watch == null:
			_time_watch = WatchHud.new()
			_time_watch.position = Vector2(24.0, 124.0)   # 与单机同位:左上边距 (24,24) + 血条下方 +100
			add_child(_time_watch)
		else:
			_time_watch.visible = true
	_time_mirror.cap = float(m.get("cap", 1800.0))
	_time_mirror.window = float(m.get("win", 250.0))
	_time_mirror.balance = float(m.get("b", 0.0))
	_time_mirror.short_used = float(m.get("w", 0.0))
	_time_mirror.loan_used = float(m.get("l", 0.0))
	_time_mirror.locked = bool(m.get("k", false))


# Beta 时间玩法:本地预测加速(与服务器同一判据 —— 按住 + 镜像账户可耗)。
func _tick_beta_time(delta: float) -> void:
	if not PvpSession.beta_mode or _local == null:
		return
	var on := Input.is_action_pressed("haste") 			and _time_mirror != null and _time_mirror.can_spend()
	# ★ 这里从前是 (_local as Node2D).set("pvp_haste_mult", …) 字符串反射,现改点访问:玩家根没有 class_name,但 _local 的静态类型是 Node2D ⇒ 点访问可用,拼错成员名当场报错,不再静默。
	_local.pvp_haste_mult = _time_haste_mult if on else 1.0
	# 压暗(用户裁定:PvP 也补,但只在发动者本人视角)—— 100ms ramp 与单机同款。
	_haste_dim_t = clampf(_haste_dim_t + (delta / 0.1 if on else -delta / 0.1), 0.0, 1.0)
	var pp := get_tree().get_first_node_in_group("post_process") as PostProcess
	if pp != null and _haste_dim_t > 0.001:   # CM-17:原条件恒等于 pp != null(每帧无条件写 uniform)
		# 只碰三个时间 uniform 里的 haste_dim;film / loan 恒 0(PvP 未接那两个的全屏版)。
		pp.set_time_effects(0.0, 0.0, _haste_dim_t)
	_tick_beta_rewind(delta)
	_tick_time_fx(delta, on)


# 本地回溯预测:按住 + 镜像可耗 + 未倒地 ⇒ 冻结本地输入源、置免伤闸、世界 + 自己上底片。
func _tick_beta_rewind(delta: float) -> void:
	# ★ 进 / 出两条路读的必须是宿主自己那一个 input_source(刻意不改成"注入源"):换成另一个对象去冻结,解冻就落不到玩家真读的那个源上 ⇒ 死锁(同一函数 src.frozen = true 与 player.set_controls_locked() 是同一个对象的两条写路)。
	var downed: bool = _local.is_downed()
	var want := Input.is_action_pressed("rewind") 			and _time_mirror != null and _time_mirror.can_spend() and not downed
	if want and not _time_rewinding:
		_time_rewinding = true
		var src: PlayerInput = _local.input_source
		if src != null:
			src.frozen = true
		(_local as Node).set_meta("time_rewinding", true)
	elif not want and _time_rewinding:
		_time_rewinding = false
		var src2: PlayerInput = _local.input_source
		if src2 != null:
			src2.frozen = false
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


# 底片只作用于世界图层 + 自己(用户裁定:敌方单位颜色不变化)。
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


# ── 他人视效状态 / 生成 / 清理:实现落在组合件 scenes/mp_client/time_fx.gd(2026-10-30 抽出;S-19)──
var _time_fx: TimeFx = null


func _ensure_time_fx() -> TimeFx:
	if _time_fx == null:
		_time_fx = TimeFx.new()
		_time_fx.bind(self)
	return _time_fx


func _tick_time_fx(delta: float, self_hasting: bool) -> void:
	# 双侧视效(节拍与单机同源:残影 0.03s / 红蓝交替;他人的红蓝重影 0.06s 一对)。
	_ensure_time_fx().tick(delta, self_hasting)


# 副本拆前清理(调用方 = ReplicaSet.remove;必须先于 queue_free,见上)。
func _time_fx_replica_rewind_off(rep: Node2D) -> void:
	_ensure_time_fx().detach(rep)


# ── 副本模式(大乱斗 / 3v3)共用的那一批(2026-11-02 从两个子类各一份上提;剔注释后逐行 diff 相同才搬)──
func _all_replicas() -> Array:
	return _replicas.values()   # Beta 时间视效:遍历全部对手副本


# 对手副本访问器(N-副本模式:按 role 动态)。★ 1v1 覆写成单副本版本(见 pvp_game)。
func _replica_for(role: int) -> Node2D:
	var r = _replicas.get(int(role))
	return r if r is Node2D else null


# 世界快照的公共段(懒建/拆副本、套 apply_snapshot、血条、掉线清理)在 ReplicaSet.apply_world_snapshot。
func _on_snapshot_world(snap: Dictionary) -> void:
	_replica_set.apply_world_snapshot(snap)


# 昵称表。★ 应用函数(不是信号回调):唯一入口 = _on_match_sync(进场拉取 / 换局重拉 / 重连补态)。
# ★ 不要连回 NetBus.local_peer_info —— 那条推送路径在本项目已不存在(worker 不再广播),连上去会让本载荷走两条路。
func _apply_peer_names(names: Dictionary) -> void:
	_names = names
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


# ── K = 自杀脱困:卡进墙/夹缝时主动放弃生命,走服务器权威 2s 复活(不计入任何人击杀;3v3 按「不分死因」给对方队 +1)──
# ★ 1v1 没有这条路径(PvpHost 不处理 suicide_request)⇒ 用能力钩子显式声明,而不是让基类顺手给 1v1 加一个新按键(那是行为变化,不是重构)。
func _supports_k_suicide() -> bool:
	return false


# ★ 判活再发(全仓纪律):按 K 的那一刻连接可能已经不可用,而这是定向可靠包 ⇒ 不判就是那条 channel 0 错误。
func _unhandled_input(event: InputEvent) -> void:
	if not _supports_k_suicide():
		return
	if _match_ended or _local == null:
		return
	if not NetBus.can_send_to_server():
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and event.physical_keycode == KEY_K:
		NetBusExt.rpc_id(1, "suicide_request")


# ── 拆砖:实现落在组合件 scenes/mp_client/tile_sync.gd(2026-10-22 拆出;Task 7) ──
var _tile_sync: TileSync = null


func _ensure_tile_sync() -> TileSync:
	if _tile_sync == null:
		_tile_sync = TileSync.new()
		_tile_sync.bind(self)
	return _tile_sync


# ★★ 拆砖的**两条订阅必须成对**,所以收在这一处给三个子类各调一次(原先三份手抄 ⇒ 1v1 那份漏了子格那条)。
func _subscribe_tile_events() -> void:
	_ensure_tile_sync().subscribe()


func _on_remote_tile_destroyed(cell: Vector2i, silent: bool = false) -> void:
	_ensure_tile_sync().on_cell(cell, silent)


func _on_remote_sub_destroyed(sub: Vector2i, silent: bool = false) -> void:
	_ensure_tile_sync().on_sub(sub, silent)

func _physics_process(delta: float) -> void:
	_tick_beta_time(delta)   # Beta 时间玩法:加速预测 + 双侧视效(普通局自短路)
	if _local == null:
		return
	# 受击事件必须在物理帧里注入(见 _pending_hit_events 的注释):排在 note_post_step 之前,
	# 这样被注入刷新后的当前态就是本帧该记录的"上一 tick 整态"。
	_drain_hit_events()
	_ping_acc += delta
	if _ping_acc >= 0.5:
		_ping_acc = 0.0
		if NetBus.can_send_to_server():
			NetBus.send_ping()
	# U1:本地预测**不锁存** —— 每物理 tick 现读真输入,60Hz 与服务器逐 tick 同序。
	# ★ 顺序不能反:先记上一 tick 的预测整态(玩家还没步进),reconcile 才比得上 ring[C];采样本 tick 输入后玩家才步进。
	var uplink := _ensure_input_uplink()
	if uplink.have_prev_seq and _rollback != null:
		# 贴身提示:只在接触期放宽容差(见 core/prediction_rollback.gd 的 contact_pos_tol)。★ 必须在 reconcile() 之前 —— 它是消费方。
		_rollback.in_contact = _update_contact_state()
		_rollback.note_post_step(uplink.prev_sent_seq, _local.capture_state())
		_rollback.reconcile()
	uplink.begin_tick()
	var src: PlayerInput = _local.input_source
	# 位打包收在 PacketInputSource.pack_record(协议编码端的唯一来源;解码端本来就只有一份)。
	var aim: Vector2 = _local.get_current_aim_dir()
	# st = 最近成功解码并应用的世界快照 tick(命中回放时间基准 + 增量基线);ct = 本帧客户端物理帧号(只落位)。
	var need_full := NetBus.snapshot_need_full()   # 恒 false(v7 起保留位,见 BIT_NEED_FULL)
	var rec := PacketInputSource.pack_record(src, uplink.seq, aim, _last_snap_tick,
			Engine.get_physics_frames(), need_full)
	# 滚轮 / 数字键切枪:本地解析成目标那把的 inst 再随输入包上行。★ 位置不能过网 —— 两端 held 的顺序可能不同(拾取 / 丢弃只由服务器裁决),同一下标会解出不同的枪。
	var switch_inst: int = _local.weapons.take_uplink_switch(src.get_switch_index_pressed())
	if switch_inst > 0:
		rec["winst"] = switch_inst
	uplink.submit(rec, aim)      # 记录 predict 输入 + 30Hz 流水线组包(submit 内逐字搬自原函数中段)
	uplink.take_packet()         # 本 tick 该发就发(encode_input → can_send → send_input;原 send_now 分支)
	# 地面武器:锚点 + 落点同步 + F 提示(纯本地表现,不参与预测)。
	_tick_ground_weapons()
	_cull_bullet_contacts()
	uplink.netstat_tick(delta)


func _on_bullet_spawn(data: Dictionary) -> void:
	if _world == null:
		return
	var b := _take_visual_bullet(String(data["scene"]))
	if b == null:
		return
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
	# ★ 视觉副本也要认射手:指向射手副本而不是本地玩家 —— BulletBase 里凡是用 shooter 的地方都自带类型 / 分组守卫(见 _wrap 的 is_in_group("player") 与 _check_player_contact 的 n == shooter),拿副本当射手不会破坏它们。
	b.shooter = _replica_for(int(data.get("shooter_role", 0)))
	# 尾迹不在此挂:BulletBase._ready 统一接线,副本弹与本地弹同一处。


# 视觉子弹取实例的唯一入口:池优先,池拿不到(路径空 / 加载失败)时退回一次性实例。
# ★ 所有"新建一颗视觉弹"的路径都必须走这里:绕过它就等于一半复用一半新建,池也永远攒不到闲置。
# 返回值尚未进树,调用方负责 setup / 定位 / add_child。
func _take_visual_bullet(scene_path: String) -> BulletBase:
	var b: BulletBase = BulletPool.shared().acquire(scene_path)
	if b != null:
		return b
	var scene: PackedScene = load(scene_path) as PackedScene
	if scene == null:
		return null
	return scene.instantiate() as BulletBase


# ── 本地视觉子弹撞到"该打的人" → 立刻消失(否则画面看起来还是像穿透)──
var _contact_targets: Array = []
var _contact_targets_frame := -1


# 本帧的受击候选(player + 对手副本),按 BulletBase.CONTACT_GROUPS 的组序 + 组内顺序收集 —— 与旧逐次查询同序。
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
			b.despawn()   # pool 回池(queue_free 会绕过池);两者都在本帧绘制前生效,不会多亮一帧


# 这颗视觉子弹的上一帧位移有没有穿过"该打的人";候选 = BulletBase.CONTACT_GROUPS(player / player_replica),排掉射手本人,
# 再叠一层队别过滤(3v3 队友穿透)。
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


# 目标受击面:对手副本用 hurt_rect_rendered(尺寸取幽灵体、位置取渲染位置),实体用自己的 hurt_rect。
func _bullet_hurt_rect(n: Node2D) -> Rect2:
	if n.has_method("hurt_rect_rendered"):
		return n.hurt_rect_rendered()
	if n.has_method("hurt_rect"):
		return n.hurt_rect()
	return HitShape.hurt_rect_of(n)


# 这颗视觉子弹能不能停在那个实体上。默认能(1v1 / 大乱斗:除了射手谁都能挡);3v3 覆写:与射手同队的排掉(规则:队友不互挡 + 子弹穿透队友)—— 不覆写的话队友副本会把自己的子弹吃掉(与服务器裁决相反,且不报错)。
func _bullet_hits_entity(_b: BulletBase, _ent: Node2D) -> bool:
	return true


# ── 回合状态:三模式共用的四态编排(2026-10-22 从三个子类各一份收上来) ──
func _update_contact_state() -> bool:
	if _rollback == null or _local == null:
		return false
	var lr: Rect2 = _local.hurt_rect()
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	var best_gap := INF
	var rel_speed := 0.0
	var anchor_speed := 0.0
	for n in get_tree().get_nodes_in_group(ReplicaScript.GROUP):
		var rep := n as Node2D
		if rep == null or not is_instance_valid(rep) or not rep.has_method("ghost_rect"):
			continue
		var gr: Rect2 = rep.ghost_rect()
		var center := MazeGenerator.anchor_to_nearest(gr.get_center(), _local.global_position, w, h)
		gr = Rect2(center - gr.size * 0.5, gr.size)
		var gap := PredictionContact.rect_gap(lr, gr)
		if gap < best_gap:
			best_gap = gap
			var gv: Vector2 = rep.ghost_velocity() if rep.has_method("ghost_velocity") else Vector2.ZERO
			rel_speed = (_local.velocity - gv).length()
			anchor_speed = gv.length()
	var horizon := PredictionContact.ghost_horizon_s(NetBus.ping_ms)
	_rollback.contact_pos_tol = PredictionContact.contact_tol(rel_speed, anchor_speed, horizon)
	# ★ 2026-10-31 迟滞:离开贴身区后的一小段仍按贴身容差(理由见 PredictionContact.CONTACT_GRACE_S)。
	#   没有它:脱离那一瞬速度差还没收敛、而容差已掉回 2px/20 ⇒ soak 里每个 ack 一次回滚的连发。
	var now_contact: bool = _local.touching_player() or PredictionContact.is_contact(best_gap)
	_contact_grace_left = PredictionContact.grace_after(_contact_grace_left,
			get_physics_process_delta_time(), now_contact)
	return now_contact or _contact_grace_left > 0.0


func _on_round_state(data: Dictionary) -> void:
	_last_round_state = data
	var state := int(data.get("state", 0))
	_round_locked = state == 0
	_refresh_input_lock()
	# ★★ 这条分支必须**边沿触发**(同一局只跑一次):COUNTDOWN 期间服务器每 0.5s 重播一条(倒计时锚点)⇒ 按条触发的
	#   旧写法会每 0.5s 清一次子弹、复位一次砖,3v3 还每 0.5s 重拉一次 match_sync(六端 ×6 次/局)。
	var round := int(data.get("round", 1))
	if state == 0 and round > 1 and round != _countdown_round_seen:
		_countdown_round_seen = round
		_clear_bullets_for_new_round()
		_on_countdown_round()
	elif state == 3 and _should_handle_match_over():
		_enter_match_over_state(data)
	_refresh_input_lock()


# 新一局开始:清本地子弹(服务器同刻也清)。三模式相同,故不留钩子。
# ★ 这里仍用 queue_free 而不是 despawn:换局是低频重活,回收到池省不出什么,直接销毁不会把上一局状态带进来。
func _clear_bullets_for_new_round() -> void:
	for b in get_tree().get_nodes_in_group("bullet"):
		if is_instance_valid(b):
			(b as Node).queue_free()


# 新一局 COUNTDOWN 的模式差异:默认只复位可破坏砖;3v3 覆写并在 super 之后重拉 match_sync。
func _on_countdown_round() -> void:
	if _level0 != null and _level0.has_method("reset_destructibles"):
		_level0.reset_destructibles()


# 是否消费这一条 MATCH_OVER。默认 true(1v1/3v3:第二条载荷仍要刷新结算页);
# 大乱斗覆写成"首次才消费"(它把 _match_ended 当幂等闩,门内只做一次挂载)。
func _should_handle_match_over() -> bool:
	return true


# MATCH_OVER 的公共段:置终局 → 销毁暂停菜单(ESC 双语义的硬依赖)→ 弹/刷结算页。
# ★ `_show_result()` 是"挂载一次、每次刷新";写成 `if _result != null: return` 就会让第二条载荷永远到不了屏幕。
func _enter_match_over_state(_data: Dictionary) -> void:
	_match_ended = true
	if _pause_menu != null and is_instance_valid(_pause_menu):
		_pause_menu.queue_free()
		_pause_menu = null
	_menu_open = false
	_show_result()


# 本地输入锁的单一口(三个维度:冻结期 / 菜单打开 / 结算后回菜单途中)。
func _refresh_input_lock() -> void:
	if _local != null and _local.has_method("set_controls_locked"):
		_local.set_controls_locked(_round_locked or _menu_open or _match_ended)



# ── 结算页:挂载/刷新/离场接线落在组合件 scenes/mp_client/result_screen.gd(2026-10-22 拆出;Task 6) ──
# 三个模式共用,各自只覆写 _build_result_payload();离场仍走本类的 _leave_to_main_menu(组件经 bind 的
# leave_scene Callable 接 leave_requested ⇒ 组件不 import NetBus / Level0,也不知道"回主菜单"怎么回)。
var _result_screen: ResultScreen = null


func _ensure_result_screen() -> ResultScreen:
	if _result_screen == null:
		_result_screen = ResultScreen.new()
		_result_screen.bind(self, Callable(self, "_build_result_payload"),
				Callable(self, "_leave_to_main_menu"))
	return _result_screen


# 结算页:玩家自己退(不再是 N 秒后自动回主菜单)。
# ★★ 挂载一次、但每次都要刷新 —— 语义逐字保留在 ResultScreen.show():`if _result == null` 只包住"建 + 连线"。
func _show_result() -> void:
	_ensure_result_screen().show()


# 结算页 → 主菜单。
func _leave_to_main_menu() -> void:
	if NetBus != null:
		NetBus.stop()
	if not is_inside_tree():
		return
	Level0.safe_change_scene(get_tree(), "res://scenes/main_menu.tscn")


# 结算页载荷(默认空)。三个子类各覆写一份 —— 模式差异只有这一点。
func _build_result_payload() -> Dictionary:
	return {}


# ── 副本访问器 _replica_for() / 快照消费 _on_snapshot_world() / 昵称 _apply_peer_names() 已上提到上面的「副本模式」段
#   (2026-11-02):1v1 与两个 N-副本模式的形状差异由 pvp_game 覆写那三处表达,这里不再各留一份。


func _on_hit_event(victim_role: int, damage: int, source_pos: Vector2, seq: int) -> void:
	if _local == null:
		return
	if victim_role == PvpSession.role:
		# 网络回调在 idle 帧:只入队,由 _drain_hit_events() 在下一个物理帧开头注入(帧外 move_and_slide 位移恒 0)。
		_pending_hit_events.append([source_pos, damage, seq])
		return
	var r := _replica_for(victim_role)
	if r != null and r.has_method("play_hit"):
		r.play_hit(source_pos)


# 击杀播报:显示名兜底文案按模式不同(1v1「对手」/ 大乱斗与 3v3「玩家%d」)⇒ 实现留在三个子类。
# ★ 基类必须声明这个名字:_boot_world() 里 `NetBus.local_kill_event.connect(_on_kill_event)` 要能解析到它,
#   否则整个脚本解析失败(实测:"Identifier _on_kill_event not declared")。和 _apply_role_colors 同属"子类必须覆写"的口。
func _on_kill_event(_killer: int, _victim: int) -> void:
	push_error("PvpMatchClient: 子类必须覆写 _on_kill_event")


func _drain_hit_events() -> void:
	if _pending_hit_events.is_empty():
		return
	var events: Array = _pending_hit_events
	_pending_hit_events = []
	for ev in events:
		_apply_local_hit_event(ev[0], int(ev[1]), int(ev[2]))


# 本地受击:优先按服务器命中时刻的 seq 注入预测历史(restore 到该 tick → take_hit → 重放),让本地击退曲线与权威同源;
# seq 不能安全注入(环外 / 已 ack / 乱序)时只播反馈 —— 权威 c2 可能已包含这一发,再完整 take_hit 会二次扣血、下个 ack 再回滚。
# ★ 守卫在 tests/probe/rollback_fidelity_probe.gd 的源码检查里:删掉注入会静默退回旧行为(不报错,只是回滚变多)。
func _apply_local_hit_event(source_pos: Vector2, damage: int, seq: int) -> void:
	if _rollback != null and _rollback.apply_external_event(seq, func() -> void:
			_local.take_hit(source_pos, damage, false, -1.0)) \
			== PredictionRollback.EventApply.APPLIED:
		return
	_local.take_hit(source_pos, damage, false, -1.0, true)


# 服务器权威开火(即时光束武器):对手端据此画光束视觉副本(不开物理子弹)。
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


# ── 子类必须覆写的那一口:角色颜色(形状随"对手 1 个 vs N 个"而定,故实现留在子类)──
# ★ 2026-11-02:_apply_peer_names() 的 N-副本版本已上提到「副本模式」段(1v1 覆写自己的单副本版);这里只剩颜色。
func _apply_role_colors() -> void:
	push_error("PvpMatchClient: 子类必须覆写 _apply_role_colors")


# ── 「每个角色的颜色」那一段的唯一分叉点(基类钩子):_on_match_sync 只调它一次。默认(1v1 / 大乱斗)走 `_apply_role_colors`
# (两种模式都是固定色:1v1 = P1 蓝/P2 青,大乱斗 = 按 role 从 ROLE_COLORS 自动取色);3v3 覆写本钩子消费 teams(队色)。
# ★ 颜色已无"玩家自选"这一路:大厅不再有改色控件,载荷里也没有 hues 键。
func _apply_peer_hues_or_team(_payload: Dictionary) -> void:
	_apply_role_colors()


func _on_match_sync(payload: Dictionary) -> void:
	# 本应答是进场建态还是重连补态?(见 _resync_pull_pending;读一次即清)
	var resync := _resync_pull_pending
	_resync_pull_pending = false
	var names: Dictionary = payload.get("names", {})
	if not names.is_empty():
		_apply_peer_names(names)
	# 颜色那一段走基类钩子(默认 = 按 role 固定/自动色;3v3 覆写成队色)。
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
	# ★★ 补态那一路:先把本地世界还原成建局基线,再应用 destroyed。
	# ★「先还原 + 再应用」恰好等于服务器的 grid(还原给基线、destroyed 给差异),不上线任何新字节;顺序反过来会把刚补好的洞又填回去,症状与"根本没还原"逐字相同。★ 只在补态这一路做(闸门 = 读一次即清的 resync);reset_destructibles() 只重铺瓦片层 + 整层重建碰撞,不碰玩家 / 子弹 / 地面武器,非 COUNTDOWN 时刻调用安全。
	if resync and _level0 != null and _level0.has_method("reset_destructibles"):
		_level0.reset_destructibles()
	elif resync:
		# ★ 该还原而没还原 —— 留一条告警:_level0 是由子类赋值的共享状态字段(三个子类各自 _ready 里写),漏赋值 / 赋错类型时上面那道闸静默不成立,症状(幻影空洞拖到下一个回合边界)与"根本没写这段"逐字相同。
		var why := ("_level0 为 null(子类 _ready 漏赋值?)" if _level0 == null
				else "_level0 没有 reset_destructibles()(类型不对?)")
		push_warning("match_sync(补态): 世界未还原 —— %s;幻影空洞不会填回" % why)
	# 掉线窗口内被拆的墙(以及"换局还原"之后本局重新拆的那些):重连后补回(进场那次该字段为空)。★ 复用 _on_remote_tile_destroyed 的静默形态,不另写一套清瓦片 / 清碰撞的逻辑。
	var destroyed: Array = payload.get("destroyed", [])
	for c in destroyed:
		if c is Vector2i:
			_on_remote_tile_destroyed(c, true)
	# ★★ BUG-03(2026-10-30):destroyed 只覆盖"整格与基线不同";只被打掉部分子格的砖(榴弹 32px 洞)
	#   不在那一份里 —— 不补这一份,客户端会留下幽灵墙(贴图/碰撞都在,服务器上早已是洞)⇒ 预测每帧回滚。
	#   静默补(不播碎片,与 destroyed 同款);应用顺序在整格之后,重复子格无害。
	var destroyed_subs: Array = payload.get("destroyed_subs", [])
	for s in destroyed_subs:
		if s is Vector2i:
			_on_remote_sub_destroyed(s, true)


# ── 拾取(地面武器):实现落在组合件 scenes/mp_client/pickup_sync.gd(2026-10-22 拆出;Task 7)──
var _pickup_sync: PickupSync = null


func _ensure_pickup_sync() -> PickupSync:
	if _pickup_sync == null:
		_pickup_sync = PickupSync.new()
		_pickup_sync.bind(self)
	return _pickup_sync


# 订阅服务器的两条地面武器事件。
func _subscribe_ground_weapons() -> void:
	_ensure_pickup_sync().subscribe()


func _spawn_pickup_node(data: Dictionary) -> void:
	_ensure_pickup_sync().on_spawned(data)


# 清空本端的地面武器表与全部拾取物节点(_on_match_sync 的"先清后灌"用)。
func _clear_ground_weapons() -> void:
	_ensure_pickup_sync().clear()


func _remove_pickup_node(inst: int) -> void:
	_ensure_pickup_sync().remove(inst)


# 每帧:① 把锚点推给所有地面武器(接缝另一侧的枪要画在身边那一份上);② 把落体的实际位置同步回本地表(提示的"最近一把"要跟着落点走);③ 更新 F 提示。
func _tick_ground_weapons() -> void:
	_ensure_pickup_sync().tick()


# ── 断线重连(局内自动重连:与 worker 的连接闪断 → 自己连回去、重新认领 role、重置本地 C2 —— 不切场景、不重建世界)──
var _reconnect_driver: ReconnectDriver = null
# ★ 下一条 match_sync 应答属于重连补态(而非进场建态)。
var _resync_pull_pending := false

# ── 本地状态横幅── ★ 它只有一个数据源:本类的 _set_status()(由 ReconnectDriver 的四个转折点驱动:begin / retry_tick / resumed / cancel|abort)。
# ★ 它由 _subscribe_reconnect() 里建(三个子类都已经在各自 _ready 里调它)⇒ 不加新调用点,也就不存在"某个模式漏调 ⇒ 那个模式静默没有提示"这一档。
var _banner: StatusBanner = null


func _ensure_reconnect_driver() -> ReconnectDriver:
	if _reconnect_driver == null:
		_reconnect_driver = ReconnectDriver.new()
		_reconnect_driver.bind(self, Callable(self, "_set_status"), Callable(self, "_pull_resync"))
	return _reconnect_driver


# 三个子类各自 _ready 里调一次(与 _subscribe_ground_weapons() 并列)。
func _subscribe_reconnect() -> void:
	_ensure_reconnect_driver().subscribe()   # 三条订阅随组件走(local_server_message / server_disconnected / local_match_start)
	_setup_status_banner()   # 本地状态横幅(3.2 / 3.4);建在这里 = 三个模式零新调用点


# 建横幅(幂等)。
func _setup_status_banner() -> void:
	if _banner != null:
		return
	_banner = preload("res://ui/hud/status_banner.tscn").instantiate() as StatusBanner
	add_child(_banner)


func _set_status(text: String) -> void:
	if _banner != null:
		_banner.set_text(text)


# 重连成功后的补态拉取(由 ReconnectDriver._on_resumed 经 Callable 调;S-17 第二刀拆出)。
# 逐字搬自原 _on_resumed 中段:重置本地 C2 状态(不重置会把断线前的记录当"未确认输入"重放)+ 拉一次 match_sync。
func _pull_resync() -> void:
	# ★ 必须重置:worker 在 reclaim 时把 _ack_seq[role] 归 0 重协商锚点,而客户端这边的 _acked 还停在断线前那个数 —— 不重置的话新快照的 ack 一律 <= _acked,on_authoritative 全数丢弃(C2 静默失效,要等 seq 重新爬过那个数才恢复),同时环里断线前的记录会被当成未确认输入重放,与服务器的新锚点错位。
	_ensure_input_uplink().reset_epoch()   # seq 归零 + 流水线 / 节拍作废(逐字见 InputUplink.reset_epoch)
	_pending_hit_events.clear()   # 旧 seq 空间的受击事件作废(新 rollback 的 _last_applied=0,注入不进去)
	# ★ 新实例必须重新 bind + 设 map_px,照抄三个子类 _ready 里那三行。
	_rollback = PredictionRollback.new()
	_rollback.bind(_local)
	_rollback.map_px = Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	_rollback.ticks_per_record = PacketInputSource.TICKS_PER_RECORD
	NetBus.reset_snapshot_state()   # P1.5:增量合并基准作废(重连可能连到已跑过一段时间的 worker)
	_last_snap_tick = 0
	# ★ 路径甲(局内自动重连)原来不需要 match_sync —— 场景没重建、本地世界还在;现在需要了:世界在掉线那 GraceWindow.DEFAULT_SECONDS 秒里变过。
	# ★ 顺序:上面已经把 C2 重置完了(新 rollback / seq=0),再拉。★ 别把这一行删掉:它不在"进场建态"那条老路上,漏了不报错,只是世界悄悄不一致。
	if NetBus.can_send_to_server():
		# ★ 先置位再发:这条应答是补态口径,_on_match_sync 据此跳过出生点校正(它按 spawns 校正 / 告警的前提在这里不成立)。
		_resync_pull_pending = true
		NetBus.rpc_id(1, "match_sync")


# 菜单关掉时补一次(ReconnectDriver.recheck_disconnect 的委托;判据与那两个"菜单开着时真掉线"的理由随组件走)。
func _recheck_disconnect() -> void:
	_ensure_reconnect_driver().recheck_disconnect()


# 「对手已离开」是终局信号:把正在跑的重连循环停掉(并收起状态横幅) —— 判据与理由随组件走(含"两条消息到达顺序不保证"那一节);
# 本口是 pvp_game._on_opponent_left 的调用点,名字 / 签名逐字不变。
func _cancel_reconnect() -> void:
	_ensure_reconnect_driver().cancel()


# 场景离开(ESC / MATCH_OVER / 对手离开 / 进程退出)→ 停掉正在跑的重连(ReconnectDriver.on_exit_tree 的委托;
# "为什么必须有 / 为什么只在真在重连时断连"随组件走)。★ 这是引擎回调,名字不能改。
func _exit_tree() -> void:
	if _reconnect_driver != null:
		_reconnect_driver.on_exit_tree()
