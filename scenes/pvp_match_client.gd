class_name PvpMatchClient
extends Node2D

# PvP 对局客户端的共享基类(1v1 pvp_client / 大乱斗 royale_game / 3v3 team_game 都 extends 它)。
# ★ 判据是"剔掉注释后的代码是否逐字相同"(不是"看起来像"):凡两个模式语义相同的都上提到这里,子类只留真正的差异(1 个固定副本 vs N 个按 role 动态、HUD 类、退场是否锁 _match_ended、_ready)。要再上提一批,先按同样口径量一遍差异(剔注释后逐行 diff),别凭印象搬。

const LaserVisual := preload("res://core/present/laser_visual.gd")   # 远端光束视觉副本(与本地激光同款)

# ── 共享状态(两个模式同名同义;子类不要再声明一次)──
var _local: Node2D = null
var _world: Node = null   # WorldViewport(视觉子弹/TileHitFx 副本挂这里)
var _level0: Node = null  # 世界(Level0):补态那一路要还原可破坏砖(见 _on_match_sync)
var _round_locked := false      # COUNTDOWN 冻结态(别把倒计时里提前解锁)
var _ping_acc := 0.0
# C2 客户端预测:见 core/prediction_rollback.gd 与 docs/pvp-c2-retrospective.md。
var _rollback = null            # PredictionRollback
var _input_seq := 0             # 本地每 tick 单调的输入序号(60Hz 真输入;服务器每 tick 消费一条记录并回带 ack)
var _have_prev_seq := false
var _prev_sent_seq := 0
# U1:30Hz 发包节拍 = 每 2 个 tick 发一包,包内 [上一 tick, 本 tick] 两条记录。本地预测**不锁存**(每 tick 现读真输入)。
var _input_batch_phase := 1     # 1 = 本 tick 先攒、下一 tick 发包(首包即从 tick0+tick1 开始,不需要伪造 seq0)
var _prev_tick_rec: Dictionary = {}   # 流水线里"上一 tick 的记录",下一包作为低 tick 记录发出去
# 本端**最近成功解码**的服务器世界快照 tick(三个模式的 _on_snapshot_world 各自维护;2026-10-24 从三个子类上提到基类 — 输入包要带 st)。
# ★ 语义是"最近**成功解码**"、不是"最后收到"(解码失败的包不算 —— 增量批会拿它当基线,算错 = 静默错位)。
var _last_snap_tick := 0
# ── 网络统计读数(★ 默认关;开关 -- --netstat,必须写在 -- 之后,写在前面会被 Godot 丢掉、静默失效)──
# 一次打一行四个量:gap = _input_seq − 最后收到的 ack(本端已发、服务器没确认的输入**记录**数;U1 后一条记录 = 1 个物理 tick,
# 故端到端滞后 ≈ gap×16.7ms);ping = NetBus.ping_ms(EWMA 平滑的纯网络 RTT);积压 = gap×16.7 − ping(扣掉网络之后还剩多少是服务器没来得及消费的);
# 回滚 = rollback_count() 的每秒增量(恒为 0 也可能是哑火,见 on_authoritative 的 ack 闸)。★ ack 只在 30Hz 本人包回带 ⇒ gap 有 0~2 条(0~33ms)量化偏置,判趋势不看绝对值。
var _netstat := false
var _netstat_checked := false
var _netstat_acc := 0.0
var _netstat_prev_rb := 0
var _last_ack := 0
var _netstat_steps := 0     # 两次打印之间的物理步数(=物理步/秒,因为本函数每物理步调一次)
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


# 通用身体染色:只给角色本体 AnimatedSprite2D 上色(武器/预瞄线不染)。两条互斥的路:color_override 非透明 = modulate 比值;默认(大乱斗 / 3v3 的个人色相)= 色相旋转(player_p2_hue.gdshader,hue_deg 是旋转量,0 = 不改色,故可重复调用)。
# ★ 队色为什么是"modulate 比值"而不是"直接乘队色":modulate 是乘,只能把身体压暗、改不了色相 —— 本体主色是蓝 #639BFF,蓝 × 队色 ≠ 队色,"一眼看出谁是队友"会落空(拿旧队色实测出来是一坨灰紫)。
# ★ 改成 目标色 / 本体主色 这个比值就精确了:输出 = 主色像素 × 比值 = 恰好目标色本身(复测:队 1 得到 #639BFF 与 C_TEAM_A 逐字节相等)—— 比值法是结构性成立的,而 hue 旋转只是数值上逼近;队色因此与头顶 ID / 小地图点位同源同一个常量,不存在"身体是派生色、柱子上是原色"。
# ★ 队 2 的比值有分量 > 1(g = 244/155 ≈ 1.574、r ≈ 1.293),这是有意的:modulate 收 >1 的值,实测在 rendering/mobile(Forward Mobile)下原样生效;队 1 的比值恰为 (1,1,1) ⇒ 队 1 的身体就是默认蓝。★ 另有一条硬理由:hue 旋转保持饱和度/亮度不变,而本体主色是 S61 V100 ⇒ 它表达不了 S50 这类目标色(队 2 的 #80F4FF 正是 H185 S50 V100)。
func _apply_tint(body: Node, hue_deg: float, color_override: Color = Color(0, 0, 0, 0)) -> void:
	var canvas := body as CanvasItem
	if canvas == null:
		return
	# ① 队色(modulate 比值):精确染成 color_override 本身
	if color_override.a > 0.0:
		canvas.modulate = Color(color_override.r / BODY_BASE_COLOR.r,
				color_override.g / BODY_BASE_COLOR.g,
				color_override.b / BODY_BASE_COLOR.b)
		return
	# ② 色相旋转(1v1 / 大乱斗的既有效果);0 = 不改色
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
	# ★★ 跨纪元的旧 ack 必须丢掉:重连时服务器把 _ack_seq[role] 归 0 重协商锚点,而客户端要到 _on_resumed 才把 _input_seq 归零 —— 这中间它仍在用断线前那个 seq 空间发包,服务器下一 tick 消费到那个大 seq 并立刻广播一条带它的快照,那条落在 _on_resumed 刚重建的 rollback 上(_acked 从 0 起)⇒ _acked 被抬到新纪元追不上的高度,on_authoritative 的 ack <= _acked 把之后所有真实 ack 全丢 —— 断线前活了多久就哑多久(实测 ~560 帧 ≈ 9s),症状是不报错、回滚恒为 0、sync_soft_state 不再被调用(背包/拾取不同步)。
	# 判据:合法 ack 永不超过本端已发的 seq(服务器只可能 ack 它消费过的包)⇒ 超过的一定是上一个 seq 空间的残留,丢掉即正确。★ 两侧复位互为理由(服务端归 0 是为了客户端的 _acked,客户端重置是为了服务端的 0),只改一侧会得到镜像的同一个洞。零守卫:reconnect_probe 已删(2026-10-09),当年它相① 去掉本行即红。
	var ack := int(own.get("ack_seq", 0))
	if ack > _input_seq:
		return
	_last_ack = ack          # 网络统计读数用(诊断,默认关)
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
var _fx_self_t := 0.0                # 自己的残影节拍(0.03s)
var _fx_other_t := 0.0               # 他人重影节拍(0.06s)
const TIME_GLOW_SELF := Color(0.30, 0.62, 1.0)    # 自己加速:冷白蓝(与单机主角同色)
const TIME_GLOW_OTHER := Color(1.0, 0.94, 0.86)   # 他人加速:暖白(与单机敌人同色)

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
	if pp != null and (_haste_dim_t > 0.001 or pp != null):
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


# 双侧视效(节拍与单机同源:残影 0.03s / 红蓝交替;他人的红蓝重影 0.06s 一对)。
func _tick_time_fx(delta: float, self_hasting: bool) -> void:
	# 自己:加色高亮 + 红蓝交替残影(与单机同款节拍)。
	if self_hasting:
		if TimeGlow.on(_local) == null:
			TimeGlow.attach(_local, TIME_GLOW_SELF)
		_fx_self_t -= delta
		if _fx_self_t <= 0.0:
			_fx_self_t = 0.03
			var anim := _local.animator as AnimatedSprite2D
			if anim != null:
				var red := int(Time.get_ticks_msec() / 60) % 2 == 0
				AfterImage.spawn((_local as Node).get_parent(), anim,
						Color(1.0, 0.25, 0.25, 0.55) if red else Color(0.3, 0.4, 1.0, 0.55))
	else:
		var g := TimeGlow.on(_local)
		if g != null:
			g.queue_free()
	# 他人:回溯优先(底片色 + 轨迹残像,不叠加速高亮);否则加速高亮 + 红蓝重影 + ▶▶3x。
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
	# 红蓝重影:同一帧贴红 / 蓝两张淡副本(加色叠加读作色差重影;与自己的交替残影区分)。
	_fx_other_t -= get_process_delta_time()
	if _fx_other_t <= 0.0:
		_fx_other_t = 0.06
		var anim := rep.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
		if anim != null:
			AfterImage.spawn(rep.get_parent(), anim, Color(1.0, 0.25, 0.25, 0.30))
			AfterImage.spawn(rep.get_parent(), anim, Color(0.3, 0.4, 1.0, 0.30))


# 他人回溯视效:副本自身底片色(满覆盖度)+ 沿服务器轨迹的时间切片残像(1 秒渐隐)。轨迹点来自快照 trail(每 3 帧一个 [x,y]),本端为每个新点生成一张底片色残像并自己淡出。
var _rw_film_mats: Dictionary = {}   # replica -> ShaderMaterial(满覆盖度)
var _rw_ghosts: Dictionary = {}      # replica -> Array[{node, t}](生成时刻,1s 渐隐)

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
	# 轨迹残像:快照的 trail 里比上次多出来的点 → 每点一张淡副本(挂在副本父级,位置即轨迹点)。
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
	_ping_acc += delta
	if _ping_acc >= 0.5:
		_ping_acc = 0.0
		if NetBus.can_send_to_server():
			NetBus.send_ping()
	# U1:本地预测**不锁存** —— 每物理 tick 现读真输入,60Hz 与服务器逐 tick 同序。
	# ★ 顺序不能反:先记上一 tick 的预测整态(玩家还没步进),reconcile 才比得上 ring[C];采样本 tick 输入后玩家才步进。
	if _have_prev_seq and _rollback != null:
		# 贴身提示:只在接触期放宽容差(见 core/prediction_rollback.gd 的 contact_pos_tol)。★ 必须在 reconcile() 之前 —— 它是消费方;漏了这一行 = 静默退回 2px 容差,故 rollback_fidelity_probe 有一条源码守卫钉住它的位置与唯一性。
		_rollback.in_contact = _local.touching_player()
		_rollback.note_post_step(_prev_sent_seq, _local.capture_state())
		_rollback.reconcile()
	var send_now := _input_batch_phase == 0
	_input_batch_phase = (_input_batch_phase + 1) % PacketInputSource.INPUT_BATCH_TICKS
	_input_seq += 1
	var src: PlayerInput = _local.input_source
	# 位打包收在 PacketInputSource.pack_record(协议编码端的唯一来源;解码端本来就只有一份)。
	# st = 最近成功解码的服务器快照 tick(增量批的基线来源);ct = 本帧客户端物理帧号。本批只落位、无消费者。
	var aim: Vector2 = _local.get_current_aim_dir()
	var rec := PacketInputSource.pack_record(src, _input_seq, aim, _last_snap_tick,
			Engine.get_physics_frames())
	# 滚轮 / 数字键切枪:本地解析成目标那把的 inst 再随输入包上行。★ 位置不能过网 —— 两端 held 的顺序可能不同(拾取 / 丢弃只由服务器裁决),同一下标会解出不同的枪。
	var switch_inst: int = _local.weapons.take_uplink_switch(src.get_switch_index_pressed())
	if switch_inst > 0:
		rec["winst"] = switch_inst
	if _rollback != null:
		_rollback.note_input(_input_seq, rec)
	_prev_sent_seq = _input_seq
	_have_prev_seq = true
	if send_now:
		# 30Hz 发包 = [上一 tick, 本 tick] 两条记录(流水线;低 tick 记录由上一包之后补齐 ⇒ 服务器收到逐 tick 连续序列)。
		# ★ 只有真发得出去时才发:离场的三条路(ESC / MATCH_OVER / 对手离开)都会先 NetBus.stop(),而本场景到帧末才被换掉 —— 中间这一两帧 rpc_id 会打引擎错误(no multiplayer peer is active),包本来也发不出去。预测与记账照常走完(seq 照增),只是不上行;重连会重建 C2 状态。
		var lo: Dictionary = _prev_tick_rec if not _prev_tick_rec.is_empty() else rec
		var pair := PacketInputSource.pack_pair(lo, rec, aim, _last_snap_tick,
				Engine.get_physics_frames())
		if NetBus.can_send_to_server():
			NetBus.rpc_id(1, "send_input", NetCodec.encode_input(pair))   # 46 B/包(含 2 条 tick 记录)
		_prev_tick_rec = {}
	else:
		_prev_tick_rec = rec
	# 地面武器:锚点 + 落点同步 + F 提示(纯本地表现,不参与预测)。
	_tick_ground_weapons()
	_cull_bullet_contacts()
	_netstat_tick(delta)


# 网络统计读数:开关走 OS.get_cmdline_user_args() 且懒查一次(本类没有 _ready —— 三个子类各有一个,在基类再加会被覆盖掉、静默失效)。
func _netstat_tick(delta: float) -> void:
	if not _netstat_checked:
		_netstat_checked = true
		_netstat = OS.get_cmdline_user_args().has("--netstat")
	if not _netstat:
		return
	# 本函数由 _physics_process 每物理步调一次 ⇒ 两次打印之间的调用次数就是物理步 / 秒;它显著高于渲染帧率 ⇒ 说明有物理追赶(catch-up),那会一次性发出成串输入包 —— 正是服务端队列被顶上去的形态。
	_netstat_steps += 1
	_netstat_acc += delta
	if _netstat_acc < 1.0:
		return
	_netstat_acc = 0.0
	var gap := _input_seq - _last_ack
	var lag_ms := float(gap) * (1000.0 / 60.0) * float(PacketInputSource.TICKS_PER_RECORD)
	var ping := NetBus.ping_ms
	var rb := 0
	if _rollback != null:
		rb = int(_rollback.rollback_count())
	var where := Vector2.ZERO
	if _local != null and is_instance_valid(_local):
		where = (_local as Node2D).global_position
	print("[netstat] seq=%d ack=%d gap=%d(滞后 %.0fms) | ping=%dms | 扣网后积压≈%.0fms | 回滚累计=%d (+%d/s) | pos=(%.0f,%.0f) | 物理步/秒=%d 渲染fps=%d"
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


# ── 本地视觉子弹撞到"该打的人" → 立刻消失(否则画面看起来还是像穿透)── 客户端那颗子弹的 collision_mask = 5(地形 1 + 敌人层 4),而对手在客户端只是一具层 2 的幽灵体 ⇒ 物理上永远撞不到,子弹从对手身上穿过去;而服务器早已按半径裁决、扣血、销毁了它那两颗。
# ★ 判据用与服务器裁决同一个常量(BulletBase.PLAYER_HIT_RADIUS = MatchHost.HIT_RADIUS 引用的那一个)+ 同一套环面最短距离 ⇒ "子弹停在哪"与"服务器判在哪"是同一个公式,不是凑出来的相似值。★ 只收本地视觉副本(apply_damage == false);榴弹(explodes)不走这条 —— 它的引信 / 反弹由 _check_player_contact 管,在这里收掉会把爆炸一起吞掉。
func _cull_bullet_contacts() -> void:
	for n in get_tree().get_nodes_in_group("bullet"):
		var b := n as BulletBase
		if b == null or b.apply_damage or b.explodes:
			continue
		if _bullet_contact_target(b) != null:
			b.queue_free()   # 立刻:queue_free 在本帧绘制之前生效,不会多亮一帧


# 这颗视觉子弹此刻有没有贴上"该打的人";候选 = BulletBase.CONTACT_GROUPS(player / player_replica),排掉射手本人 —— 与 _check_player_contact 同一候选集,再叠一层队别过滤(3v3 队友穿透)。
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
	return null   # 基类无副本;两个子类各自实现


func _on_hit_event(victim_role: int, damage: int, source_pos: Vector2) -> void:
	if _local == null:
		return
	if victim_role == PvpSession.role:
		_local.take_hit(source_pos, damage, false, -1.0)
		return
	var r := _replica_for(victim_role)
	if r != null and r.has_method("play_hit"):
		r.play_hit(source_pos)


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


# ── 子类必须覆写的两口:昵称表 / 角色色相(形状随"对手 1 个 vs N 个"而定,故实现留在子类;在这里声明,否则基类调用未声明的函数 = 编译不过)──
func _apply_peer_names(_names: Dictionary) -> void:
	push_error("PvpMatchClient: 子类必须覆写 _apply_peer_names")


func _apply_peer_hues(_hues: Dictionary) -> void:
	push_error("PvpMatchClient: 子类必须覆写 _apply_peer_hues")


# ── 「每个角色的颜色」那一段的唯一分叉点(基类钩子):_on_match_sync 只调它一次,不再直接调 _apply_peer_hues。默认(1v1 / 大乱斗)消费载荷里的 hues;3v3 覆写消费 teams(队色)并刻意不调 _apply_peer_hues —— 6 个人里认不出队友这模式就没法玩,个人色相在 3v3 是无效输入。★ 签名收整个 payload 而不是只收 hues:3v3 要读同一份应答里的另一个键,只传 hues 会逼出一条"上游写、下游读"的暗通道。
func _apply_peer_hues_or_team(payload: Dictionary) -> void:
	var hues: Dictionary = payload.get("hues", {})
	if not hues.is_empty():
		_apply_peer_hues(hues)


func _on_match_sync(payload: Dictionary) -> void:
	# 本应答是进场建态还是重连补态?(见 _resync_pull_pending;读一次即清)
	var resync := _resync_pull_pending
	_resync_pull_pending = false
	var names: Dictionary = payload.get("names", {})
	if not names.is_empty():
		_apply_peer_names(names)
	# 颜色那一段走基类钩子(默认 = 个人色相;3v3 覆写成队色)。
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
		# ★ 该还原而没还原 —— 留一条告警:_level0 是由子类赋值的共享状态字段(两个子类各自 _ready 里写),漏赋值 / 赋错类型时上面那道闸静默不成立,症状(幻影空洞拖到下一个回合边界)与"根本没写这段"逐字相同。只告警,不改行为。
		var why := ("_level0 为 null(子类 _ready 漏赋值?)" if _level0 == null
				else "_level0 没有 reset_destructibles()(类型不对?)")
		push_warning("match_sync(补态): 世界未还原 —— %s;幻影空洞不会填回" % why)
	# 掉线窗口内被拆的墙(以及"换局还原"之后本局重新拆的那些):重连后补回(进场那次该字段为空)。★ 复用 _on_remote_tile_destroyed 的静默形态,不另写一套清瓦片 / 清碰撞的逻辑。
	var destroyed: Array = payload.get("destroyed", [])
	for c in destroyed:
		if c is Vector2i:
			_on_remote_tile_destroyed(c, true)


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


# 订阅服务器的两条地面武器事件。★ 必须走 NetBus,不是 NetBusExt —— 后者里有同名遗留的 beam_fired,挂错节点的表现是静默 no-op(对手的枪凭空消失 / 永不再现,且不报错)。两个子类各自 _ready 里调一次。
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


# ── 断线重连(局内自动重连:与 worker 的连接闪断 → 自己连回去、重新认领 role、重置本地 C2 —— 不切场景、不重建世界)── ★ 触发点只有"服务器断开"一条(NetBus.local_server_message,由 multiplayer.server_disconnected 驱动);对局场景此前没人订阅它,所以服务器一断客户端毫无反应:快照停更、输入自停,玩家卡在一个静止的世界里只能按 ESC 自救。
# ★★ 两条时间尺度别合并:RECONNECT_RETRY_MS(2s)= 定时器节拍 —— 多久看一眼(等应答 / 两次尝试之间);RECONNECT_ATTEMPT_TIMEOUT_MS(5s)= 一次连接尝试自己的寿命 —— 一次握手最多活多久。合并成"每 2 秒 stop() + 重连一次"会在高 RTT 链路上反复掐掉正在握手的尝试(比不掐更糟);而只看节拍、不掐尝试,就是修掉的那个缺陷。
const RECONNECT_RETRY_MS := 2000
# 一次尝试的寿命。取值依据:一次成功握手约 2~3×RTT,5s 覆盖到 ~1.6s 的 RTT(再差的链路本就没法打);而 ENet 自己的连接超时实测 ~31.8s(连一个没人监听的端口)—— 不主动掐的话,一次尝试就能吃掉宽限期预算(GraceWindow.DEFAULT_SECONDS)的一半上下,且那整段期间一次 tick 都没有。
const RECONNECT_ATTEMPT_TIMEOUT_MS := 5000
var _reconnecting := false
var _reconnect_started_ms := 0   # ★ 真实断开时刻(不是"关菜单"时刻,见 _begin_reconnect)
var _reclaim_sent := false   # ★ 本条连接上是否已发过 reclaim(判据见 _on_reconnect_retry_tick)
var _pending_disconnect := false   # 断线时菜单开着 → 记账,关菜单再来(见 _recheck_disconnect)
var _attempt_started_ms := 0   # 当前这次连接尝试的起飞时刻;0 = 没有尝试在飞
var _retry_timer: SceneTreeTimer = null   # 单一定时器(判据见 _schedule_reconnect_retry)
# ★ 下一条 match_sync 应答属于重连补态(而非进场建态)。两口共用同一条信号(重连不重建场景 ⇒ 子类 _ready 里那个订阅还在),而 _on_match_sync 里的出生点校正对两种口径的答案相反,故必须让应答自己知道是哪一次拉的。取用点:_on_match_sync 首行(读一次、当场清掉);置位点:_on_resumed 发送前那一行,以及 3v3 team_game._on_round_state 的「新一轮 COUNTDOWN」那一拉(换边后 spawns 是新一侧,与 PvpSession.spawn 手里的旧一侧必然不一致)。
var _resync_pull_pending := false

# ── 本地状态横幅── ★ 它只有一个数据源:本文件的断线重连状态机。服务器侧的「谁掉线了」走 round_state 的 grace 字段(见 MatchState.grace_snapshot),两者刻意不共用同一个节点 —— 一条是"我这边断了",一条是"对面断了",同时显示会互相覆盖。
# ★ 它由 _subscribe_reconnect() 里建(三个子类都已经在各自 _ready 里调它)⇒ 不加新调用点,也就不存在"某个模式漏调 ⇒ 那个模式静默没有提示"这一档。
var _banner: StatusBanner = null


# 两个子类各自 _ready 里调一次(与 _subscribe_ground_weapons() 并列)。
func _subscribe_reconnect() -> void:
	NetBus.local_server_message.connect(_on_server_message)
	# ★ worker 在宽限期内接受 reclaim 后会重发一条 match_start(载荷与首次开局同源)。对局里 local_match_start 此前零订阅者 —— 它唯一的消费者是 lobby_page._on_match_start(统一大厅 mp_lobby 的基类),而那个页面在对局场景里不在树上 ⇒ 这条信号到对局里是静默 no-op;所以"重连成功"的收尾必须在这里接(_on_match_start_event)。
	NetBus.local_match_start.connect(_on_match_start_event)
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


func _on_server_message(msg: String) -> void:
	if _match_ended or _reconnecting:
		return
	# 服务器文本播报也走这条信号,但对局期间服务器只发「对局开始」/「大乱斗开始」;大厅那些「房间已满」之类不会到对局场景。
	if msg.contains("断开") or msg.contains("断开连接"):
		_pending_disconnect = true
		_begin_reconnect()


# 菜单关掉时补一次:真掉线正好落在"菜单开着"那段窗口里时,上面那次 _begin_reconnect 会被守卫挡下,账记在 _pending_disconnect 上,关菜单这一刻补上;不补的话玩家会留在一个快照停更的静止世界里 —— 正是本功能要消掉的那个状态。
# ★ 它不是"按 ESC 回主菜单"那一路(原注释这么写,已被实测推翻):它服务的是"菜单开着时真掉线"这一档。
func _recheck_disconnect() -> void:
	if _pending_disconnect:
		_pending_disconnect = false
		_begin_reconnect()


# 局内自动重连:不切场景、不重建世界 —— 场景与节点原样保留,只把连接接回去。★★ "不重建场景"不等于"世界没变":掉线那 GraceWindow.DEFAULT_SECONDS 秒里服务器照跑 —— 对面把墙拆了、地上的枪被捡走 / 丢弃 / 换局重铺 ⇒ 这条路径同样要拉一次 match_sync 把破坏态与地面武器补回来。别把"世界还在原地"读成"没什么要补的"(漏了不报错)。
func _begin_reconnect() -> void:
	# ★ MATCH_OVER / 对手离开那两条延时回菜单的路子会先 NetBus.stop(),而它断开的是我们自己。
	if _match_ended:
		return
	# ★ 宽限期预算的起算点 = 真实断开这一刻,故记在这里、且在那道菜单守卫之前(菜单开着的闪断若等"关菜单"才起算,等于凭空多拿一段预算 —— spec 的宽限期按服务器的掉线检测起算,客户端晚算的那几秒会让最后几次 reclaim 打在"已被移出"上)。★ 只在没人记过时才记:关菜单时 _recheck_disconnect() 再来一次,预算要接着走,不重置。
	if _reconnect_started_ms == 0:
		_reconnect_started_ms = Time.get_ticks_msec()
	# ★ 菜单开着先不动,但不是放弃(放弃会把真掉线也一起漏掉):那一刻的重连要推迟到关菜单再发 —— 玩家下一秒可能就点「回到主菜单」,先把连接接回 worker 再走人,就会留下"人已走、role 仍被占"的幽灵(对手那边卡死、无报错)。
	# ★ 订正过的前提:NetBus.stop() 会把 multiplayer_peer 置空,引擎在 set_multiplayer_peer 里先 clear()、last_connection_status 当场复位成 DISCONNECTED ⇒ CONNECTED→DISCONNECTED 那一跃从未被观测到,server_disconnected 根本不会发;而 PauseMenu.go_menu() 走的是直接 NetBus.stop(),连 toggled 都不经过 ⇒ "按 ESC 会引发重连"这条路径不存在。
	# ★ 守卫仍然保留的真正理由:菜单开着时真掉线是可能的(服务器踢人 / 网络断),而那一刻的重连要推迟到关菜单(账记在 _pending_disconnect 上,由 _recheck_disconnect() 补)。另一侧:_exit_tree 兜"重连已经在飞、玩家又按 ESC 走了"。
	if _menu_open:
		return
	_pending_disconnect = false
	if PvpSession.token == "" or PvpSession.worker_port <= 0:
		_abort_reconnect("重连失败(无会话令牌)")   # 原版 worker / 老大厅 → 优雅降级
		return
	_reconnecting = true
	# ★ 断开一被侦测到就亮横幅,而不是等某次重试失败之后 —— 这正是"重连失败之前的可见反馈"。
	_set_status("与服务器断线,正在重连…")
	NetDiag.log_event("reconnect_begin", {"role": PvpSession.role, "port": PvpSession.worker_port,
			"has_token": PvpSession.token != ""}, true)
	print("[pvp] 连接断开,开始重连(role=%d port=%d)" % [PvpSession.role, PvpSession.worker_port])
	_retry_connect.call_deferred()


# 连一轮(先把上一轮拆干净)。★ 与 lobby_page 转连 worker 那一处同款:start_client 的地址 / 端口取自 PvpSession(大厅填好的,不重新走大厅)。
func _retry_connect() -> void:
	if not _reconnecting:
		return
	NetBus.stop()
	_reclaim_sent = false   # 新连接 = 新的一次 reclaim 额度(旧连接上那次的成败已无意义)
	_attempt_started_ms = 0   # 上一轮(若有)就此作废
	# ★ 上一轮那两条一次性结局回调若还没触发,仍挂在 MultiplayerAPI 上(信号回调挂在对象上,不随 multiplayer_peer 换掉,也不随 NetBus.stop() 清),不清的话新连接握手成功那一次 emit 会把它们一起叫起来 —— _try_reclaim 会被叫两次、_on_reconnect_failed 的旧回调还可能把新一轮的尝试记账清零。故每次重连先摘干净。
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
	# ★★ 成功这条也要挂定时器(原先只有 err != OK 那条挂)。不挂的话,"一次连接尝试正在飞"的整段期间一次 tick 都没有 —— 宽限期判据从不被求值,而 ENet 自己的连接超时实测 ~31.8s ⇒ 最坏情形是卡在冻结世界 ~32 秒才回主菜单。★ 这里的病不是"宽限期太短"(当年它恰好是 30s),而是那一段期间判据一次都没被求值 —— 所以时长改成多少,这条修复的必要性都不变。
	_schedule_reconnect_retry()


func _on_reconnect_failed() -> void:
	_attempt_started_ms = 0   # 这次尝试已有结局(失败)→ 下一拍重开,不必再等尝试超时
	_schedule_reconnect_retry()


func _try_reclaim() -> void:
	if not _reconnecting:
		return   # 期间已收场(超时/已离开) → 不发
	# ★★ 本条连接上只发一次 reclaim(本功能最要害的不变量):worker 接受第一次时就 _grace.leave(role) 了,同一条连接上再发一次,进 _on_reclaim 的判据必不成立 → 它踢连接。这一行是兜底:正常路径由 _retry_connect 每次重连把旧的一次性回调摘干净来保证,但"只发一次"值得在发的地方再写死一次。
	if _reclaim_sent:
		return
	_attempt_started_ms = 0
	_reclaim_sent = true
	NetBusExt.rpc_id(1, "reclaim_role", PvpSession.role, PvpSession.token)
	# ★ 等 worker 回的 match_start(它带 spawn / map_path)。等到了才算成功,见 _on_resumed。
	_schedule_reconnect_retry()


# 重试节拍(单一定时器;每一拍自己判"再连一轮"还是"只等应答")。★ 一个时刻只能有一个定时器在飞:OK 路径那条"尝试超时"会与 reclaim 后那条"等应答"重叠(connected_to_server 一到,_try_reclaim 又挂一个),不拦的话每一拍会跑两遍。已有的没到点就直接返回 —— 链条不会断:_on_reconnect_retry_tick 除收场那两条外每条分支都会再挂一次。
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
	# 横幅上显示还剩多少预算(失败之前就要有可见反馈)。★ 读的是 GraceWindow.DEFAULT_SECONDS —— 与下面那条收场判据同一个常量,不会漂。
	var left := int(GraceWindow.DEFAULT_SECONDS) \
			- int((Time.get_ticks_msec() - _reconnect_started_ms) / 1000)
	_set_status("与服务器断线,正在重连…(剩余 %ds)" % maxi(left, 0))
	# ★★ 宽限期判据是第一条,且与"这次尝试走到哪一步"无关 —— 两条路径(err != OK 与 OK)现在都挂了定时器,所以哪怕握手一直不落地(一次 reclaim 都没发出去),整整一个 GraceWindow.DEFAULT_SECONDS 也一定到点。
	if Time.get_ticks_msec() - _reconnect_started_ms > int(GraceWindow.DEFAULT_SECONDS * 1000.0):
		_abort_reconnect("重连超时,对局已结束")
		return
	# ★★ 同一个 role 只许发一次 reclaim(本功能最易写错、症状最怪的一处):worker 接受第一次时就 _grace.leave(role) 了,第二次进 _on_reclaim 的判据("该 role 必须在宽限期里")必不成立 → 它踢连接。表现是"刚重连上几秒又断",看着像网络抖动,实则是自己把自己踢了,而且因为 token 是对的,查 token 查不出问题。
	# 判据:这条连接还活着、且已发过 reclaim ⇒ 该做的是等它的 match_start(可靠的定向应答,连着就一定到),而不是重连一轮再发一次。真发不出去(连接没了 / 被服务器踢了)can_send_to_server() 即为 false,自然走到下面重连。
	if _reclaim_sent and NetBus.can_send_to_server():
		_schedule_reconnect_retry()
		return
	# ★ 一次握手最多活 RECONNECT_ATTEMPT_TIMEOUT_MS(还没起飞的不受此限:0 = 无尝试在飞)。★ 这里绝不能用 RECONNECT_RETRY_MS —— 每 2 秒 stop() + 重连会在高 RTT 链路上反复掐掉正在握手的尝试,比不掐更糟;那个值只管"多久看一眼"。到点仍未落地 = 这次多半不会落地了(ENet 自己的超时 ~31.8s,是它的 6 倍多)→ 掐掉重开,让宽限期预算里能放下十来次尝试。
	var attempt_age := Time.get_ticks_msec() - _attempt_started_ms
	if _attempt_started_ms > 0 and attempt_age < RECONNECT_ATTEMPT_TIMEOUT_MS:
		_schedule_reconnect_retry()
		return
	_retry_connect()


# worker 接受 reclaim 后重发的那条 match_start 到达 → 重连成功。
func _on_match_start_event(_role: int, _spawn: Vector2i, _map_path: String) -> void:
	# 非重连态收到它 = 首次进场那一份(由 lobby_page 消费;本场景那时还没建出来)或异常来源,两种都不动本地世界 —— 本路径不重建场景,故 role / spawn / map_path 一个都不回写(PvpSession.spawn 在大乱斗里是"动态复活点"语义,回写只会让下一次 _correct_local_spawn 把玩家瞬移走)。
	if not _reconnecting:
		return
	_on_resumed()


# 重置本地 C2 状态(不重置会把断线前的记录当"未确认输入"重放)。
func _on_resumed() -> void:
	_reconnecting = false
	NetDiag.log_event("reconnect_resumed", {"role": PvpSession.role,
			"down_ms": Time.get_ticks_msec() - _reconnect_started_ms}, true)
	_reconnect_started_ms = 0
	_reclaim_sent = false
	_attempt_started_ms = 0
	_set_status("")   # 重连成功 → 收起横幅(阶段 3)
	# ★ 必须重置:worker 在 reclaim 时把 _ack_seq[role] 归 0 重协商锚点,而客户端这边的 _acked 还停在断线前那个数 —— 不重置的话新快照的 ack 一律 <= _acked,on_authoritative 全数丢弃(C2 静默失效,要等 seq 重新爬过那个数才恢复),同时环里断线前的记录会被当成未确认输入重放,与服务器的新锚点错位。
	_input_seq = 0
	_have_prev_seq = false
	_prev_sent_seq = -1
	_input_batch_phase = 1     # 与初始一致:重连后第一包从 tick0+tick1 开始
	_prev_tick_rec = {}        # 旧 seq 空间的流水线记录作废(否则会把断线前的输入当低 tick 发给服务器)
	# ★ 新实例必须重新 bind + 设 map_px,照抄两个子类 _ready 里那三行。漏了都不报错:没 bind → _handle_ack 里 _p == null 直接 _trim 返回,分歧永不修复(静默失去 C2);没设 map_px → 跨接缝那一帧按裸距离比,白跑一次回滚。
	_rollback = PredictionRollback.new()
	_rollback.bind(_local)
	_rollback.map_px = Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	_rollback.ticks_per_record = PacketInputSource.TICKS_PER_RECORD
	# ★ 路径甲(局内自动重连)原来不需要 match_sync —— 场景没重建、本地世界还在;现在需要了:世界在掉线那 GraceWindow.DEFAULT_SECONDS 秒里变过。这一拉把两类丢掉的可靠事件一次补回:destroyed(被拆的墙,不补 → 幻影墙 → 预测分歧)、ground_weapons(掉落 / 被捡走的枪,不补 → 幽灵枪 / 看不见的枪)。
	# ★ 顺序:上面已经把 C2 重置完了(新 rollback / _input_seq=0),再拉。★ 别把这一行删掉:它不在"进场建态"那条老路上,漏了不报错,只是世界悄悄不一致。
	if NetBus.can_send_to_server():
		# ★ 先置位再发:这条应答是补态口径,_on_match_sync 据此跳过出生点校正(它按 spawns 校正 / 告警的前提在这里不成立)。
		_resync_pull_pending = true
		NetBus.rpc_id(1, "match_sync")
	print("[pvp] 重连成功")


# 「对手已离开」是终局信号:把在飞的重连循环停掉(并收起状态横幅)。★★ worker 收场是「先发 opponent_left、紧接着 quit(0)」,两条消息(可靠通知 + ENet 断开)几乎同一拍到达客户端,到达顺序不保证:通知先到 ⇒ _on_opponent_left 置 _match_ended ⇒ 随后那条断开被 _on_server_message 的闸挡住,重连循环根本不会启动;断开先到 ⇒ _begin_reconnect 已把 _reconnecting 置起、_retry_connect 已 deferred 出去,通知才到 ⇒ 只有本函数能把那个循环叫停。
# 少了它,玩家会在看到「对手已离开」的同时继续重试 60 秒(两条路各回一次主菜单,第二条还会把刚建出来的主菜单当 old 退役)。⇒ 判据:不论谁先到,结局都是「2.5s 后回主菜单」,且不叠加一个 60 秒的重连循环。★ 它不重建场景、不发包、不碰协议 —— 纯本地状态收口。
func _cancel_reconnect() -> void:
	_reconnecting = false
	_reconnect_started_ms = 0
	_reclaim_sent = false
	_attempt_started_ms = 0
	_set_status("")   # 「对手已离开」是终局:横幅一并收起,让位给 HUD 的中央播报


func _abort_reconnect(reason: String) -> void:
	_reconnecting = false
	# ★ 先收起横幅再换场:换场是 await 一帧的(safe_change_scene 的防重入首行),留着文字只会在主菜单上闪一帧,读起来像 bug。原因本身仍留在下面那行 print 里。
	_set_status("")
	NetBus.stop()
	Level0.safe_change_scene(get_tree(), "res://scenes/main_menu.tscn")
	print("[pvp] %s" % reason)


# 场景离开(ESC / MATCH_OVER / 对手离开 / 进程退出)→ 停掉在飞的重连。★ 必须有:_reconnecting 期间玩家仍可按 ESC 离场,不停的话重连循环会从主菜单继续跑,连上还 reclaim 成功 → worker 认为这个 role 有人管。★ 只在真在重连时断连:本函数跑在新场景 _ready 之后(safe_change_scene 先 add 新场景再摘旧场景),无条件 NetBus.stop() 会把新场景刚建起来的连接干掉。
func _exit_tree() -> void:
	if _reconnecting:
		_reconnecting = false
		NetBus.stop()
