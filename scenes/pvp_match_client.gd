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
var _round_locked := false      # COUNTDOWN 冻结态(别把倒计时里提前解锁)
var _ping_acc := 0.0
# C2 客户端预测:见 core/prediction_rollback.gd 与 docs/pvp-c2-retrospective.md。
var _rollback = null            # PredictionRollback
# 受击事件队列:网络回调跑在 idle 帧,而注入要重放(内部 move_and_slide)—— 物理帧外 move_and_slide 位移恒 0(实测),
# 故回调只入队,统一在下一个物理帧开头注入(反馈最多晚 1 帧 ≈16.7ms)。
var _pending_hit_events: Array = []   # [[source_pos: Vector2, damage: int, seq: int], ...]
const PredictionContact := preload("res://core/net/prediction_contact.gd")   # 贴身判据/动态容差(纯函数)
const ReplicaScript := preload("res://scenes/player/player_replica.gd")      # 要它的 GROUP 常量(副本没 class_name)
# ── 输入上行(每 tick 采样 → PacketInputSource.pack_record → packet_input_source.pack_pair → 发包 → ack/seq 记账 → netstat)──
# 实现落在组合件 core/net/input_uplink.gd(2026-10-30 拆出;S-17 第一刀)。本类只留采样口(_physics_process 里现读
# src / aim / winst)与 C2 预步(它要宿主的 `_rollback` 与 `_update_contact_state()`),其余三步调组件:
# begin_tick() → submit(rec, aim) → take_packet()。★ seq 归零时机 / `_prev_tick_rec` 流水线 / ack 纪元 /
# netstat 统计窗口全部随组件走(不变量写在组件文件头,改之前先读那一节)。
# ★ 组件懒建:基类没有 _ready(三个子类各有一个,在基类再加会被覆盖掉、静默失效)⇒ 第一次用到时 new + bind;
#   bind 只存引用、没有副作用,与"实例化时就建"在行为上不可分。
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

# 玩家本体精灵(player.png)的主色(RGB)。★ 数值是实测的不是拍的:主色 #639BFF 占 12987 个不透明像素里的 10875(83.6%),次色 #5585D9 是它的暗调同色;复测办法 = 按 alpha>200 过滤 player.png 全部像素取众数。换 sprite 素材要重测这一行 —— 它错了不报错,只是队色整体偏色(整队一起偏,更容易漏)。★ 唯一源是 UiFactory.C_TEAM_A(队 1 token,同值),这里是别名不存字面量;零守卫:hue_tint_probe 的守卫 D(钉 C_TEAM_A == 本常量 == png 众数)已随该探针删除(2026-10-09)。
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
			best.queue_free()
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
	if not PvpSession.beta_mode:
		return
	_time_watch = WatchHud.new()
	_time_watch.position = Vector2(24.0, 124.0)   # 与单机同位:左上边距 (24,24) + 血条下方 +100
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
		# WatchHud._ready 那会儿账户还没到(挂表早于首包)→ 它把自己藏了;首包到时点亮。
		if _time_watch != null:
			_time_watch.visible = true
	_time_mirror.cap = float(m.get("cap", 1800.0))
	_time_mirror.window = float(m.get("win", 250.0))
	_time_mirror.balance = float(m.get("b", 0.0))
	_time_mirror.short_used = float(m.get("w", 0.0))
	_time_mirror.loan_used = float(m.get("l", 0.0))
	_time_mirror.locked = bool(m.get("k", false))


# Beta 时间玩法:本地预测加速(与服务器同一判据 —— 按住 + 镜像账户可耗)。倍率写进 pvp_haste_mult,player 的速度域 / 武器 tick 会吃它;烧颗粒只由服务器做(镜像 10Hz 校正,本地不扣,避免双份漂移)。
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


# 本地回溯预测:按住 + 镜像可耗 + 未倒地 ⇒ 冻结本地输入源、置免伤闸、世界 + 自己上底片。★ 位置不本地预测 —— 服务器每帧权威写回(C2 的 on_authoritative 就是那条路);本地只负责"站着 + 看底片 + 免伤"。
func _tick_beta_rewind(delta: float) -> void:
	# ★ 进 / 出两条路读的必须是宿主自己那一个 input_source(刻意不改成"注入源"):换成另一个对象去冻结,解冻就落不到玩家真读的那个源上 ⇒ 死锁(债单 §六.7,同一函数 src.frozen = true 与 player.set_controls_locked() 是同一个对象的两条写路)。点访问取代反射:拼错成员名当场报错。
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
# 以副本节点为键的三张表 + 两份节拍器原挂在本类根上、清理散在两处 —— 漏一处就是节点泄漏(BUG-19)。
# ★ 组件懒建(基类没有 _ready:三个子类各有一个,在基类再加会被覆盖):第一次用到时 new + bind,只存引用、无副作用。
# ★ _time_fx_replica_rewind_off 这个名字保留:ReplicaSet.remove() 按名调它,它是「先 detach 再 queue_free」
#   那条 BUG-19 顺序的调用口(顺序在拆除方,别倒过来:节点释放后表键再也碰不到)。
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


# 本类全部对手副本(视效遍历用)。子类覆写;基类空。
func _all_replicas() -> Array:
	return []


# ── 拆砖:实现落在组合件 scenes/mp_client/tile_sync.gd(2026-10-22 拆出;Task 7) ──
# 本类只留这三个委托口(名字/签名逐字不变:三个子类 _ready 调 _subscribe_tile_events(),
# _on_match_sync 直接调 _on_remote_tile_destroyed(cell, true);原 resync_world_probe 也调它,该探针已于 2026-10-24 删除)。
# ★ 组件懒建:基类没有 _ready(三个子类各有一个,在基类再加会被覆盖掉、静默失效)⇒ 第一次用到时
#   new + bind;bind 只存引用、没有副作用,与"实例化时就建"在行为上不可分。
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
		# ★ 2026-10-28 起判据不只靠 touching_player():幽灵体滞后会让你追人时预测穿过去、本帧根本没撞上 ⇒ 旧写法判不到
		#   贴身、按 2px 容差挨回滚。`_update_contact_state()` 用"预测身位到幽灵 AABB 的间隙"兜住这种贴身,并按相对速度
		#   动态抬高 contact_pos_tol(上限 48px)。touching_player() 仍是它内部的兜底分支。
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
	uplink.take_packet()         # 本 tick 该发就发(pack_pair → can_send → send_input;原 send_now 分支)
	# 地面武器:锚点 + 落点同步 + F 提示(纯本地表现,不参与预测)。
	_tick_ground_weapons()
	_cull_bullet_contacts()
	uplink.netstat_tick(delta)


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
	# ★ 视觉副本也要认射手:指向射手副本而不是本地玩家 —— BulletBase 里凡是用 shooter 的地方都自带类型 / 分组守卫(见 _wrap 的 is_in_group("player") 与 _check_player_contact 的 n == shooter),拿副本当射手不会破坏它们。
	b.shooter = _replica_for(int(data.get("shooter_role", 0)))
	# 尾迹不在此挂:BulletBase._ready 统一接线,副本弹与本地弹同一处。


# ── 本地视觉子弹撞到"该打的人" → 立刻消失(否则画面看起来还是像穿透)──
# 子弹 mask=1 只撞地形、对手在客户端只是幽灵体 ⇒ 物理上撞不到;服务器按"线段 vs 受击面"裁决,客户端 cull 必须用同一套 HitShape + 同一段位移。★ 榴弹不走这条(引信/反弹由 _check_player_contact 管)。
func _cull_bullet_contacts() -> void:
	for n in get_tree().get_nodes_in_group("bullet"):
		var b := n as BulletBase
		if b == null or b.apply_damage or b.explodes:
			continue
		if _bullet_contact_target(b) != null:
			b.queue_free()   # 立刻:queue_free 在本帧绘制之前生效,不会多亮一帧


# 这颗视觉子弹的上一帧位移有没有穿过"该打的人";候选 = BulletBase.CONTACT_GROUPS(player / player_replica),排掉射手本人,
# 再叠一层队别过滤(3v3 队友穿透)。
func _bullet_contact_target(b: BulletBase) -> Node2D:
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	for group in BulletBase.CONTACT_GROUPS:
		for n in get_tree().get_nodes_in_group(group):
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
# ★ 顺序是承重的,逐字保持旧实现:状态处理**前后各刷一次**输入锁(它是幂等的;这样 3v3 旧版末尾
#   那一次也不丢,pvp 旧版开头那一次也不丢)。三个钩子之外的 if 一律不许加进来。
# ★ 模式差异只通过钩子表达:
#   · _should_handle_match_over():大乱斗忽略第二条 MATCH_OVER,1v1/3v3 要处理(第二条载荷要刷新结算页);
#   · _on_countdown_round():三模式都复位砖,3v3 额外重拉 match_sync(换边);
#   · _enter_match_over_state():置终局、销毁暂停菜单(ESC 双语义的硬依赖)、弹/刷结算页。
# 贴身判据 + 动态容差(2026-10-28)。返回"是否贴身",调用处写成 `_rollback.in_contact = _update_contact_state()`。
# 旧实现只看 `touching_player()`(客户端本帧真的撞上幽灵体):幽灵体滞后会让你追人时预测穿过去 ⇒ 判不到贴身 ⇒
# 仍按 2px 容差、每 ack 验证点回滚。这里改用"预测身位到幽灵 AABB 的间隙"进贴身区,并按相对速度抬高容差
# (容差 = 8 + 相对速度×滞后,封顶 48px);touching_player() 保留为兜底(确实撞上的那一帧)。
func _update_contact_state() -> bool:
	if _rollback == null or _local == null:
		return false
	var lr: Rect2 = _local.hurt_rect()
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	var best_gap := INF
	var rel_speed := 0.0
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
	var horizon := PredictionContact.ghost_horizon_s(NetBus.ping_ms)
	_rollback.contact_pos_tol = PredictionContact.contact_tol(rel_speed, horizon)
	return _local.touching_player() or PredictionContact.is_contact(best_gap)


func _on_round_state(data: Dictionary) -> void:
	_last_round_state = data
	var state := int(data.get("state", 0))
	_round_locked = state == 0
	_refresh_input_lock()
	if state == 0 and int(data.get("round", 1)) > 1:
		_clear_bullets_for_new_round()
		_on_countdown_round()
	elif state == 3 and _should_handle_match_over():
		_enter_match_over_state(data)
	_refresh_input_lock()


# 新一局开始:清本地子弹(服务器同刻也清)。三模式相同,故不留钩子。
func _clear_bullets_for_new_round() -> void:
	for b in get_tree().get_nodes_in_group("bullet"):
		if is_instance_valid(b):
			(b as Node).queue_free()


# 新一局 COUNTDOWN 的模式差异:默认只复位可破坏砖;3v3 覆写并在 super 之后重拉 match_sync。
# ★ 地面武器**不要**在这里清:服务器换局是「先 _reset_ground_weapons(广播 removed×旧 + spawned×新)、
#   再 _broadcast_round_state」,两条走同一条可靠通道、保序到达 ⇒ 本条到达时新一轮那批早已在本地建好,
#   再清一次会让第 2 局起客户端地面恒空(服务器有 10 把、客户端一把都看不见)。
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


# 本地输入锁的单一口(三个维度:冻结期 / 菜单打开 / 结算后回菜单途中)。★ 合并时把大乱斗那版多出的 _match_ended 一并带进 1v1 —— 这是本步唯一的行为差异(1v1 在 MATCH_OVER 之后那几秒输入也被锁),与 _match_ended 的语义一致,属有意统一。
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


# 结算页 → 主菜单。★ 离开仍走 Level0.safe_change_scene —— 游戏世界含全量碰撞,裸 change_scene_to_file 会同步 memdelete → 偶发原生段错误。★ 防重入由 MatchResult 那次发信号 + safe_change_scene 的 _switching 双层兜住;这里只负责"在树上才切"。
func _leave_to_main_menu() -> void:
	if NetBus != null:
		NetBus.stop()
	if not is_inside_tree():
		return
	Level0.safe_change_scene(get_tree(), "res://scenes/main_menu.tscn")


# 结算页载荷(默认空)。三个子类各覆写一份 —— 模式差异只有这一点。
func _build_result_payload() -> Dictionary:
	return {}


# ── 对手副本访问器:两个模式唯一的结构性差异就收在这一个口上(1v1 一个固定副本 _remote_replica;大乱斗按 role 动态建 _replicas)── 语义:role 是对手的 role(不是自己的);没有对应副本(未建 / 已移除)时返回 null,调用方一律判空。★ 子类必须覆写。
func _replica_for(_role: int) -> Node2D:
	return null   # 基类无副本;三个子类各自实现


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


# 服务器权威开火(即时光束武器):对手端据此画光束视觉副本(不开物理子弹)。原始 pts 在射手 canonical 系(可能隔整幅地图跨接缝)⇒ 逐点锚到射手副本当前渲染位置(副本位置已由 player_replica 每帧归到本地玩家最近副本);光束整条路径 ≤ bullet_range 远小于半图 ⇒ 逐点 anchor_to_nearest 会把整条折线搬到可见副本、跨接缝连续。★ 只画对手那发:自己那发已由本地预测自画,再收服务器版会双光束。
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


# ── 子类必须覆写的两口:昵称表 / 角色颜色(形状随"对手 1 个 vs N 个"而定,故实现留在子类;在这里声明,否则基类调用未声明的函数 = 编译不过)──
func _apply_peer_names(_names: Dictionary) -> void:
	push_error("PvpMatchClient: 子类必须覆写 _apply_peer_names")


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
	# 出生点校正只对进场那次做:那时 spawns[role] 与 PvpSession.spawn 确实同源(都由服务器同一次摆位产生),不一致就是 bug —— 留痕 + 以 sync 为准。★ 重连补态那次必然不一致,而那不是 bug:1v1 每局换边(role_spawns() 在 player / player2 之间对调),而 PvpSession.spawn 只在进场写一次 —— 按它硬拉 = 把玩家瞬移走,而服务器那具身体从掉线起就没动过 ⇒ 这条路既不校正、也不告警、也不回写 PvpSession.spawn。
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
	# ★★ 补态那一路:先把本地世界还原成建局基线,再应用 destroyed。顺序不可换 —— destroyed 表达的是「与建局基线不同的格」,客户端在宽限期内错过一次换局时服务器已把可破坏砖还原成基线,那些格等于基线、永不进载荷,而客户端本地还留着上一局拆出来的破洞(幻影空洞);客户端唯一的还原路径是新回合 COUNTDOWN 里的 Level0.reset_destructibles(),而重连回来时那一局可能已打到 PLAYING ⇒ 那条分支不触发。
	# ★「先还原 + 再应用」恰好等于服务器的 grid(还原给基线、destroyed 给差异),不上线任何新字节;顺序反过来会把刚补好的洞又填回去,症状与"根本没还原"逐字相同。★ 只在补态这一路做(闸门 = 读一次即清的 resync);reset_destructibles() 只重铺瓦片层 + 整层重建碰撞,不碰玩家 / 子弹 / 地面武器,非 COUNTDOWN 时刻调用安全。
	if resync and _level0 != null and _level0.has_method("reset_destructibles"):
		_level0.reset_destructibles()
	elif resync:
		# ★ 该还原而没还原 —— 留一条告警:_level0 是由子类赋值的共享状态字段(三个子类各自 _ready 里写),漏赋值 / 赋错类型时上面那道闸静默不成立,症状(幻影空洞拖到下一个回合边界)与"根本没写这段"逐字相同。只告警,不改行为。
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
# 本类只留五个委托口(名字/签名逐字不变):三个子类 _ready 调 _subscribe_ground_weapons();
# _on_match_sync 调 _clear_ground_weapons() / _spawn_pickup_node();_physics_process 每帧调 _tick_ground_weapons()。
# 节点表 / F 提示 / `[pkd]` 诊断行全部随组件走,文本逐字未改;宿主只提供 _world / _local。
# ★ 组件懒建:基类没有 _ready(三个子类各有一个,在基类再加会被覆盖掉、静默失效)⇒ 第一次用到时
#   new + bind;bind 只存引用、没有副作用,与"实例化时就建"在行为上不可分。
var _pickup_sync: PickupSync = null


func _ensure_pickup_sync() -> PickupSync:
	if _pickup_sync == null:
		_pickup_sync = PickupSync.new()
		_pickup_sync.bind(self)
	return _pickup_sync


# 订阅服务器的两条地面武器事件。★ 必须走 NetBus,不是 NetBusExt —— 后者(NetBusExt)里曾有同名遗留的 beam_fired,2026-10-30 已删,挂错节点的表现是静默 no-op(对手的枪凭空消失 / 永不再现,且不报错)。三个子类各自 _ready 里调一次。
func _subscribe_ground_weapons() -> void:
	_ensure_pickup_sync().subscribe()


func _spawn_pickup_node(data: Dictionary) -> void:
	_ensure_pickup_sync().on_spawned(data)


# 清空本端的地面武器表与全部拾取物节点(_on_match_sync 的"先清后灌"用)。★ 为什么必须先清:match_sync 的 ground_weapons 是全量,不清就直接 add,掉线期间已被服务器移除的那些会变成永久幽灵枪(看着在、按 F 无效);进场那次本地本来是空的,清一遍是 no-op。
func _clear_ground_weapons() -> void:
	_ensure_pickup_sync().clear()


func _remove_pickup_node(inst: int) -> void:
	_ensure_pickup_sync().remove(inst)


# 每帧:① 把锚点推给所有地面武器(接缝另一侧的枪要画在身边那一份上);② 把落体的实际位置同步回本地表(提示的"最近一把"要跟着落点走);③ 更新 F 提示。
func _tick_ground_weapons() -> void:
	_ensure_pickup_sync().tick()


# ── 断线重连(局内自动重连:与 worker 的连接闪断 → 自己连回去、重新认领 role、重置本地 C2 —— 不切场景、不重建世界)──
# 实现落在组合件 scenes/mp_client/reconnect_driver.gd(2026-10-30 拆出;S-17 第二刀)。本类只留委托口 + 横幅那两口:
# 三个子类 _ready 调 _subscribe_reconnect()、关菜单回调调 _recheck_disconnect()、pvp_game._on_opponent_left 调
# _cancel_reconnect()、_exit_tree 停掉在飞的重连。★ 组件经 bind 拿两个 Callable:`_set_status`(横幅文本,本类唯一
# 数据源)与 `_pull_resync`(重连成功后的补态拉取:C2 重置 + 发 match_sync)。什么时候进 / 退出重连循环、重试预算
# 与两个定时器时长全部随组件走(不变量写在组件文件头;★ 与对局场景解耦的只有"横幅文本"与"补态拉取"两个口)。
# ★ 组件懒建:与 tile_sync / pickup_sync 同款 —— 基类没有 _ready,第一次用到时 new + bind(bind 只存引用、无副作用)。
var _reconnect_driver: ReconnectDriver = null
# ★ 下一条 match_sync 应答属于重连补态(而非进场建态)。两口共用同一条信号(重连不重建场景 ⇒ 子类 _ready 里那个订阅还在),而 _on_match_sync 里的出生点校正对两种口径的答案相反,故必须让应答自己知道是哪一次拉的。取用点:_on_match_sync 首行(读一次、当场清掉);置位点:_pull_resync() 发送前那一行,以及 3v3 team_game._on_round_state 的「新一轮 COUNTDOWN」那一拉(换边后 spawns 是新一侧,与 PvpSession.spawn 手里的旧一侧必然不一致)。
var _resync_pull_pending := false

# ── 本地状态横幅── ★ 它只有一个数据源:本类的 _set_status()(由 ReconnectDriver 的四个转折点驱动:begin / retry_tick / resumed / cancel|abort)。服务器侧的「谁掉线了」走 round_state 的 grace 字段(见 MatchState.grace_snapshot),两者刻意不共用同一个节点 —— 一条是"我这边断了",一条是"对面断了",同时显示会互相覆盖。
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


# 建横幅(幂等)。★ 必须从场景实例化:层位 140 只住在 ui/status_banner.tscn 里,.new() 建出来的是 CanvasLayer 默认的 layer 1 —— 画在三个对局 HUD(130)与小地图(131)底下,横幅被盖住且不报错。零守卫:hud_declarative_probe ⑧ 已删(2026-10-09)。
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
	# ★ 新实例必须重新 bind + 设 map_px,照抄三个子类 _ready 里那三行。漏了都不报错:没 bind → _handle_ack 里 _p == null 直接 _trim 返回,分歧永不修复(静默失去 C2);没设 map_px → 跨接缝那一帧按裸距离比,白跑一次回滚。
	_rollback = PredictionRollback.new()
	_rollback.bind(_local)
	_rollback.map_px = Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	_rollback.ticks_per_record = PacketInputSource.TICKS_PER_RECORD
	NetBus.reset_snapshot_state()   # P1.5:增量合并基准作废(重连可能连到已跑过一段时间的 worker)
	_last_snap_tick = 0
	# ★ 路径甲(局内自动重连)原来不需要 match_sync —— 场景没重建、本地世界还在;现在需要了:世界在掉线那 GraceWindow.DEFAULT_SECONDS 秒里变过。这一拉把两类丢掉的可靠事件一次补回:destroyed(被拆的墙,不补 → 幻影墙 → 预测分歧)、ground_weapons(掉落 / 被捡走的枪,不补 → 幽灵枪 / 看不见的枪)。
	# ★ 顺序:上面已经把 C2 重置完了(新 rollback / seq=0),再拉。★ 别把这一行删掉:它不在"进场建态"那条老路上,漏了不报错,只是世界悄悄不一致。
	if NetBus.can_send_to_server():
		# ★ 先置位再发:这条应答是补态口径,_on_match_sync 据此跳过出生点校正(它按 spawns 校正 / 告警的前提在这里不成立)。
		_resync_pull_pending = true
		NetBus.rpc_id(1, "match_sync")


# 菜单关掉时补一次(ReconnectDriver.recheck_disconnect 的委托;判据与那两个"菜单开着时真掉线"的理由随组件走)。
func _recheck_disconnect() -> void:
	_ensure_reconnect_driver().recheck_disconnect()


# 「对手已离开」是终局信号:把在飞的重连循环停掉(并收起状态横幅) —— 判据与理由随组件走(含"两条消息到达顺序不保证"那一节);
# 本口是 pvp_game._on_opponent_left 的调用点,名字 / 签名逐字不变。
func _cancel_reconnect() -> void:
	_ensure_reconnect_driver().cancel()


# 场景离开(ESC / MATCH_OVER / 对手离开 / 进程退出)→ 停掉在飞的重连(ReconnectDriver.on_exit_tree 的委托;
# "为什么必须有 / 为什么只在真在重连时断连"随组件走)。★ 这是引擎回调,名字不能改。
func _exit_tree() -> void:
	if _reconnect_driver != null:
		_reconnect_driver.on_exit_tree()
