class_name EnemyBase
extends CharacterBody2D

# 进入死亡状态时发射一次(用于击杀计数等 UI;撞人自毁同算,见 FlyBird._die_self)
signal died

# 物理基础(子类可覆写:扑击时关闭重力)
var use_gravity: bool = true

# 战斗数值(可在检查器调,场景值优先)
# 血量
@export var hp: int = 3
# 接触玩家伤害
@export var contact_damage: int = 1
# 受击击退力度
@export var knockback_strength: float = 150.0
# 爆炸专属击退向量:独立于 AI 移动速度,每帧叠加后指数衰减(大冲击+迅速衰减)
var knock_velocity: Vector2 = Vector2.ZERO
# 击退向量指数衰减率(越大停得越快;约 0.23s 衰减到 ~10%)
@export var knock_decay_rate: float = 10.0

# 环面接缝兜底:物理 Area 用欧氏距离,跨接缝不重叠,这里用环面距离补(略大于 ContactArea 半对角线)
const CONTACT_RADIUS: float = 40.0

const GROUND_FRICTION: float = 0.85  # 落地时水平速度衰减系数
const STOP_EPSILON: float = 5.0      # 水平速度低于此值直接归零,避免贴地滑行

var is_dead: bool = false
var _rewind_hold: bool = false   # 录制期死亡保留的尸体(隐藏待复活;非精英)
# 隐藏期间被摘掉的碰撞层(见 _physics_process 的保留尸体分支);-1 = 层未被摘、无需还原。
var _rw_held_layer: int = -1
var _hit_flash_time: float = 0.0
var _death_timer: float = -1.0   # 死亡白闪剩余;<0 未死亡(受击/死亡白闪统一在基类)
var _player_overlapping: bool = false
var _overlapping_players: Array = []  # 当前接触到的玩家节点(1v1 PvP 里可能同时撞到两人,受击取最近者)
var _turn_cooldown: float = 0.0  # 转向冷却:两次翻转朝向至少间隔 turn_min_interval
# 玩家组每帧缓存:同一物理帧内 _players_frame() 只建一次数组,砍掉每帧每敌多次 get_nodes_in_group 分配。
var _players_frame_cache: Array = []
var _players_frame_id: int = -1
var wake_radius: float = 1000.0  # 远处睡眠优化:距玩家超此值且落地静止 → 跳过物理
var network_canonical: bool = false  # PvP 服务器权威:敌人位置存 canonical [0,MAP)(_wrap 取模);单机/客户端 false=锚玩家副本渲染
var _in_water: bool = false
var _waterproof: int = 6                 # 防水值(氧气),没顶每 0.5s 掉 1
var waterproof_max: int = 6              # 上限:black/jump 6,fly 10
var _waterproof_drain_timer: float = 0.0
var _waterproof_recover_timer: float = 0.0
var _drown_tick: float = 0.0     # 扣血倒计时
# 状态机与动画(子类共用)。state 用 int 承载各子类自己的 enum 常量(见 JumpBird/FlyBird 的 enum State)。
var state: int = 0
var _state_timer: float = 0.0
var _anim: AnimatedSprite2D
# 补间形变(squash & stretch)。纯表现层,不进任何网络同步、不碰碰撞箱。
var squash: SquashStretch = null
# move_and_slide() **之前**的 velocity.y,与帧首 is_on_floor() 配对(见 spec §2.4)。
var _pre_move_vy: float = 0.0

# ── 行为钩子(子类覆写)──
func _ai(_delta: float) -> void:
	pass

func _anim_update() -> void:
	pass

# 落水时水平游泳方向(基类默认零=漂着;JumpBird/BlackBird 覆写为朝玩家)。
func _water_swim_dir() -> Vector2:
	return Vector2.ZERO

func _ready() -> void:
	add_to_group("enemies")
	_setup_contact_area()
	call_deferred("add_child", WaterFx.new())
	# 补间形变。★ 用 $AnimatedSprite2D 而不是 _anim:子类 `_ready` 是**先** super._ready()
	#   后才 `_anim = $AnimatedSprite2D`(见 enemy_jump_bird.gd:15/18),此处 _anim 还是 null。
	#   三个敌人的 .tscn 里该节点都叫 AnimatedSprite2D。
	squash = SquashStretch.new()
	add_child(squash)
	# ★ 查不到 animator 就**当场报错**,不让它静默降级:组件侧容忍 null animator(`_apply()` 直接
	#   return),于是这条查表失败的表现是"这只鸟永远不变形",一个字都不打 —— 那种沉默正是
	#   本特性最贵的失败形态。三个 .tscn 现在都叫 AnimatedSprite2D,改名/漏改名必须响。
	var anim := get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	if anim == null:
		push_error("EnemyBase: 找不到 AnimatedSprite2D 节点,补间形变将静默失效(节点名 = %s)"
				% name)
	squash.setup(anim, SquashStretch.Profile.ENEMY)

func _setup_contact_area() -> void:
	var area := Area2D.new()
	area.name = "ContactArea"
	area.collision_layer = 0
	area.collision_mask = 2  # 检测玩家(layer 2)
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(44, 40)
	shape.shape = rect
	area.add_child(shape)
	add_child(area)
	area.body_entered.connect(_on_contact_body_entered)
	area.body_exited.connect(_on_contact_body_exited)

func _on_contact_body_entered(body: Node) -> void:
	if body.is_in_group("player"):
		_player_overlapping = true
		if not _overlapping_players.has(body):
			_overlapping_players.append(body)

func _on_contact_body_exited(body: Node) -> void:
	if body.is_in_group("player"):
		_overlapping_players.erase(body)
		_player_overlapping = not _overlapping_players.is_empty()

func _physics_process(delta: float) -> void:
	delta = TimeField.enemy_delta(delta, self)   # 时间场:回溯冻结/加速/贷款(精英例外)
	# 回溯中普通敌人整帧跳过(位置由回放器摆;接触伤害/白闪/AI 全不结算);精英照常
	if TimeField.current != null and TimeField.current.is_rewinding() and not has_meta("elite"):
		return
	# squash 放在最首行(_is_far_sleeping 早退之前):睡眠时也走 tick → 回中性,
	# 正是想要的行为;否则睡眠中的鸟会卡在最后一个形变值上。
	# ★ 睡眠那一支**归零 `_pre_move_vy` 本身**(就在下面的 early return 里),不是"临时喂个 0":
	#   ① 睡眠**期间**:那一支不跑 move_and_slide ⇒ 缓存永不刷新,是"上一次非睡眠帧"的陈旧值
	#      (可达路径:垂直击退把鸟打飞、落地那一帧的落速被写进去;水平击退会被地面摩擦自愈,
	#      垂直不会)⇒ 落地项每帧重触发,而指数恢复每帧只回 `1 - exp(-9/60) ≈ 14%`
	#      ⇒ 定点 ≈ -6.19k(任何 k ≳ 0.16 都被钳到 -1)⇒ 睡着的远鸟**永久**保持 (1.10, 0.90)。
	#   ② ★ **醒来首帧**(2026-09-20 审查补)才是那个真正的洞:`_is_far_sleeping()` 那时已是 false
	#      ⇒ 走的是下面**醒着**的那条路,拿到 "`is_on_floor()==true` + 把它**送进睡眠的那次落速**"
	#      (落地帧把落速写进缓存,而它此后一直陈旧)⇒ 同一个满幅落地项在**醒来那一刻**重触发,
	#      `_impulse` 压向 -1.0。后果:鸟按**几秒前**那次落地满幅挤压;更糟的是 TAKE_OFF 的
	#      `+0.80` 加进已饱和的负值 ⇒ **起飞拉伸被抵消甚至反向成压扁**(本特性的招牌动作没了)。
	#      ⇒ 只把"喂给 tick 的值"改 0 是**半个修法**(漏掉醒来首帧),必须**清零缓存本身**。
	#   睡眠态 vel_y 本就该是 0(地面不施重力),这个 0 是事实不是特判。
	# ★ 玩家侧倒地早退是同一契约的另一处落点,形态**相同**(那边也是 `_pre_move_vy = 0.0`,
	#   见 player.gd / spec §2.4):两处的契约都不是"缓存里存的是什么",而是 **tick() 消费什么**
	#   —— 它只认"地面真正吸收掉的那个下坠速度",缓存陈旧就必须清。故两个宿主读法一致。
	var sleeping := _is_far_sleeping()
	squash.tick(delta, _pre_move_vy, is_on_floor(), is_dead)
	if sleeping:
		# 醒来首帧那一半的解法(见上):清的是**缓存**,不是这一次调用的实参。
		_pre_move_vy = 0.0
		_ai(delta)
		_wrap()
		return
	_turn_cooldown = maxf(_turn_cooldown - delta, 0.0)
	if use_gravity and not is_on_floor():
		velocity.y += GameParameters.gravity0 * delta
	# 地面摩擦:落地且非冲刺(use_gravity=true)时,水平速度平滑衰减,
	# 避免跳跃/冲刺/击飞的残留速度让敌人在地面滑行。
	# 放在 _ai 之前,这样 _ai 里新设的跳跃/冲刺初速不受当帧摩擦影响。
	if use_gravity and is_on_floor():
		velocity.x *= GROUND_FRICTION
		if absf(velocity.x) < STOP_EPSILON:
			velocity.x = 0.0
	# 死亡:AI 不行动,但物理(重力/摩擦/击退/碰撞)与生前完全一致。
	if not is_dead:
		_ai(delta)
		_anim_update()
		# 接触伤害:物理 Area 覆盖常规情况;环面接缝处欧氏距离不重叠,用环面距离兜底
		# contact_damage<=0 时跳过:零伤也会触发玩家 take_hit 消耗 iframe 并击退。
		if contact_damage > 0 and (_player_overlapping or toroidal_dist_to_player() <= CONTACT_RADIUS):
			var p := _contact_victim()
			if p != null and p.has_method("take_hit"):
				p.take_hit(global_position, contact_damage)
	# 受击/死亡白闪统一:计时 + 渲染(子类可覆写 _flash_update 换渲染方式,如黑鸟 silhouette)
	if _hit_flash_time > 0.0:
		_hit_flash_time = maxf(_hit_flash_time - delta, 0.0)
	if _death_timer > 0.0:
		_death_timer -= delta
		if _death_timer <= 0.0:
			if _rewind_hold:
				# 保留尸体:隐藏 + 停物理,等回放复活;过期由 WorldRewind.expire_corpses 清理
				# ★ 隐藏的同时**必须摘掉碰撞层**(2026-10-03 修):玩家 mask=5 里含敌人层(值 4),
				#   故一具看不见却仍在层 4 的实体就是玩家眼里的**虚空碰撞箱** —— 撞在空气上。
				#   改**碰撞层**而不是禁用碰撞多边形:飞鸟的 _apply_flight_collision 自己管
				#   站/飞两个多边形的 disabled,基类插手会和它互相打架;层是纯"谁能撞我"的量,
				#   与多边形启停正交。还原走 _rw_held_layer(见 rewind_restore 的复活分支)。
				# ★ 时机:白闪那 0.5s **不摘**(那时尸体还看得见,挡人是合理的);
				#   摘只发生在这条"隐藏待复活"的分支里。
				visible = false
				set_physics_process(false)
				_rw_held_layer = collision_layer
				collision_layer = 0
				_death_timer = -1.0
			else:
				queue_free()
			return
	_flash_update()
	if is_dead:
		# 尸体:基础速度也按击退速率指数衰减,滑行逐渐停住(不匀速滑到底);
		# 下落也随之变慢到"终端速度",更接近失去意识的尸体。
		velocity *= exp(-knock_decay_rate * delta)
	_apply_water(delta)
	# 爆炸击退位移:单独 move_and_collide(带碰撞),不污染 velocity
	# (地面把向下击退吃掉后再减回去会把身体弹起);主移动 move_and_slide 最后跑,地面状态以它为准。
	move_and_collide(knock_velocity * delta)
	knock_velocity *= exp(-knock_decay_rate * delta)
	# ★ 必须在 move_and_slide() **之前**:落地那一帧它在调用后就被清零了。
	# ★ 敌人侧**不做任何过滤**,就是裸值 —— 这是实测后的裁定(spec §2.4):
	#   ⚠ **这些读数的出处**:下面那几个数(`239/1350` 帧、`13 次真实落水挤压`、`1.0861`)
	#   是 2026-09-20 由一个**临时探针**量出来的,该探针**已删除、此后从未重测** ——
	#   本注释是它们**唯一**的留存处,别把它们当"随时可以复跑出来的当前事实"引用。
	#   裁定本身不依赖重测(方向不随几何变化:过滤净有害),故按原样保留。
	#   `_in_water ∧ is_on_floor()` 在敌人身上**确实会重叠**(239/1350 帧;玩家侧是 0,
	#   因为敌人的身体停在池底上方 0.02~0.18px,探针落进水格而玩家落在支撑格),
	#   但过滤想防的幽灵**结构上不可达**(浮力钳在 -260/+160,下沉侧 160 < 阈值 220),
	#   而过滤会**吃掉 13 次真实落水挤压**(有过滤 max scale.x=1.0000,去掉后 1.0861;
	#   挤压方向是 x>1 ⇒ 看的是**最大** scale.x)。
	#   ⇒ 净有害。敌人不爬梯,没有玩家侧那条真违规可类比。
	_pre_move_vy = velocity.y
	# 时间场:水平运动走速度域(move_and_slide 用引擎 delta,缩放 delta 不改变位移);
	# 计时器/动画/重力仍走上面的 delta 缩放。精英与玩家同步,普通敌放慢。
	velocity.x *= TimeField.enemy_speed_mult(self)
	move_and_slide()
	_wrap()

func hurt(damage: int, knock_dir: Vector2, knock_strength: float = 0.0, set_velocity: bool = false) -> void:
	if is_dead:
		# 尸体:不再扣血/触发死亡,但冲击波仍能推动(不吞冲击波)
		_apply_knock_only(knock_dir, knock_strength, set_velocity)
		return
	_apply_hit(damage, knock_dir, knock_strength, set_velocity)
	if hp <= 0:
		_begin_death()

# 受击通用逻辑:扣血、击退、白闪。子类覆写 hurt() 时也应调用本方法,避免逻辑分叉。
# knock_strength <= 0 时回落敌人自身 knockback_strength(旧两参调用行为不变)。
# set_velocity=true(爆炸):设独立击退向量 knock_velocity(封顶),不覆盖移动速度;false(枪击):叠加到原速度。
func _apply_hit(damage: int, knock_dir: Vector2, knock_strength: float = 0.0, set_velocity: bool = false) -> void:
	hp -= damage
	var ks := knockback_strength if knock_strength <= 0.0 else knock_strength
	if set_velocity:
		# 爆炸:设独立击退向量(不封顶),不覆盖移动速度
		knock_velocity = knock_dir.normalized() * ks
	else:
		velocity += knock_dir.normalized() * ks
	# 死亡:击退不折入,尸体与生前一致——knock_velocity 继续独立衰减,由 _physics_process 统一结算。
	modulate = Color(3.0, 3.0, 3.0, 1.0)  # 受击白闪
	_hit_flash_time = EnemyParams.shared.hit_flash
	squash.impulse(SquashStretch.Impulse.HURT)

# 尸体专用:只施加击退(爆炸=设独立向量、枪击=叠加速度),不扣血、不触发死亡/白闪。
func _apply_knock_only(knock_dir: Vector2, knock_strength: float, set_velocity: bool) -> void:
	var ks := knockback_strength if knock_strength <= 0.0 else knock_strength
	if set_velocity:
		knock_velocity = knock_dir.normalized() * ks
	else:
		velocity += knock_dir.normalized() * ks


# 当前是否处于 SLEEP 态。
#
# ★ **子类必须覆写**(2026-09-15 阶段 5.8 显式化的契约):本方法原先在 `_is_far_sleeping()`
#   里被硬编码成 `state != 0`,这**隐含**了「所有子类的 `State.SLEEP` 都是枚举第一个」。
#   那是一条没人写下来、也没人守的约定 —— 新敌人只要把 SLEEP 排在第二位,它的"远处睡眠优化"
#   就会**静默失效**(该睡的敌人一直在跑 AI,没有任何报错)。
#   现在每个子类自己写 `state == State.SLEEP`,加新敌人时照抄一行即可;默认实现保留
#   `state == 0` 只是兜底,别依赖它。
func _is_asleep() -> bool:
	return state == 0


# 远处睡眠判定:距玩家超唤醒半径、落地静止、非受击/死亡/非SLEEP → true。
func _is_far_sleeping() -> bool:
	if is_dead or _hit_flash_time > 0.0 or _death_timer > 0.0:
		return false
	if not _is_asleep():
		return false
	if not is_on_floor():
		return false
	if absf(velocity.x) > 5.0 or absf(velocity.y) > 5.0:
		return false
	return toroidal_dist_to_player() > wake_radius


# 落水浮力:弹簧把身体中心拉回水面线(半没入);水平朝 _water_swim_dir 游;没顶累计溺水。
func _apply_water(delta: float) -> void:
	var feet := Vector2(global_position.x, global_position.y + Water.feet_offset(self))
	_in_water = Water.is_in_water(feet)
	var submerged := false
	if _in_water:
		var surface_y := Water.surface_y_at(global_position)
		submerged = Water.submerged(global_position, surface_y)
		var target_vy := clampf((surface_y - global_position.y) * EnemyParams.shared.bird_buoyancy_k,
			-EnemyParams.shared.bird_max_float, EnemyParams.shared.bird_max_sink)
		velocity.y = MathUtil.approach(velocity.y, target_vy, EnemyParams.shared.bird_water_damp, delta)
		var dir := _water_swim_dir()
		velocity.x = MathUtil.approach(velocity.x, dir.x * EnemyParams.shared.bird_swim_speed,
			EnemyParams.shared.bird_water_damp, delta)
	# 防水值(氧气):没顶掉,暴露空气回;空后每秒扣血
	if submerged:
		_waterproof_recover_timer = 0.0
		_waterproof_drain_timer += delta
		if _waterproof_drain_timer >= GameParameters.water_drain_interval:
			_waterproof_drain_timer = 0.0
			_waterproof = maxi(_waterproof - 1, 0)
	else:
		_waterproof_drain_timer = 0.0
		_waterproof_recover_timer += delta
		if _waterproof_recover_timer >= GameParameters.water_recover_interval:
			_waterproof_recover_timer = 0.0
			_waterproof = mini(_waterproof + 1, waterproof_max)
	if _waterproof <= 0:
		_drown_tick -= delta
		if _drown_tick <= 0.0:
			_drown_tick = EnemyParams.shared.drown_interval
			hurt(EnemyParams.shared.drown_damage, Vector2.ZERO)
# 死亡白闪统一入口:置死亡状态、发信号、起白闪计时(渲染由 _flash_update 统一处理,
# 到期在基类 _physics_process 销毁)。子类可在调用后追加专属处理(JumpBird 播 dead、
# FlyBird 清冲撞速度)。
func _begin_death() -> void:
	if is_dead:
		return
	is_dead = true
	died.emit()
	# (单机击杀播报已于 2026-09-17 删除 —— 这里原先调 CombatFeedback.notify_enemy_killed,
	#  那是它唯一的触发点。PvP 的播报走 NetBus.kill_event,不经过本函数。)
	_death_timer = EnemyParams.shared.death_flash_time
	# 录制期保留尸体:不 queue_free,白闪结束后隐藏待复活(精英除外——杀了就是杀了)
	if WorldRewind.hold_corpses and not has_meta("elite"):
		_rewind_hold = true
		set_meta("rw_death_ms", Time.get_ticks_msec())
	_on_death()


# 死亡瞬间的附加动作虚钩(基类空实现)。子类在此追加专属处理:JumpBird 播 dead 动画、
# FlyBird 清冲撞速度并开重力 —— 这样各子类不必再整份覆写 hurt(),四份 hurt 的分叉点
# 只在「死亡那一刻做什么」,正该由虚钩承载。
# 调用点在 _death_timer 赋值之后:白闪计时已成立,子类里改 velocity/use_gravity 不影响它。
func _on_death() -> void:
	pass


# 冲锋冲击力:沿远离本体的方向猛推玩家(覆盖 take_hit 的普通击退,冲锋更狠)。
# 原本 FlyBird / BlackBird 各抄一份(除常量外逐字相同),收为基类单一来源。
# away 为 0(与玩家完全重合)时回退:朝玩家背向推,拿不到 get_facing 就用 LEFT。
# ★名字刻意不叫 _apply_charge_impact:两个子类各自持有同名但**两参**的包装方法,而
#   GDScript 不允许子类以不同签名覆写父类方法(会 Parse Error,且整个子类脚本加载失败
#   → `-s` 冒烟里 _initialize 抛错、永不 quit = 挂死)。故基类另起名,子类包装转调这里。
func _smash_player(p: Node, impact: float, impact_up: float) -> void:
	var p2 := p as Node2D
	if p2 == null:
		return
	var away := (p2.global_position - global_position).normalized()
	if away == Vector2.ZERO:
		away = Vector2.LEFT
		if p2.has_method("get_facing"):
			away.x = -float(p2.get_facing())
	p2.velocity = away * impact
	p2.velocity.y -= impact_up


# 白闪渲染:受击/死亡任一激活即纯白,否则恢复。默认走 modulate;黑鸟因 silhouette
# shader 覆写 COLOR 而 modulate 失效,覆写本方法改走 shader 参数。
func _flash_update() -> void:
	modulate = Color(3.0, 3.0, 3.0, 1.0) if _hit_flash_time > 0.0 or _death_timer > 0.0 else Color.WHITE


# 统一转向:两次翻转朝向至少间隔 turn_min_interval,防止敌人来回抖(看起来像 bug)。
# 朝向未变时不消耗冷却(持续面向玩家不会因此锁死)。
func _set_facing(facing_left: bool) -> void:
	if _turn_cooldown > 0.0 or _anim.flip_h == facing_left:
		return
	_turn_cooldown = EnemyParams.shared.turn_min_interval
	_anim.flip_h = facing_left


# ── 共享工具(子类通用)──

func _set_state(s: int) -> void:
	state = s
	_state_timer = 0.0
	_on_state_entered(s)


# 状态进入虚钩:基类默认空实现。三个子类各有自己的 `enum State`(JumpBird 根本没有
# TAKE_OFF),故基类**不能**硬编码状态名 —— 只能往下派发,由子类映射。
func _on_state_entered(_s: int) -> void:
	pass


func _anim_duration(name: String) -> float:
	if _anim == null:
		return 0.0
	var spf := _anim.sprite_frames
	return float(spf.get_frame_count(name)) / spf.get_animation_speed(name)


# 玩家组引用(单机 1 人 / PvP 服务器 2 人通用)。物理帧内按帧缓存一次、帧内复用;
# 非物理上下文(如测试直调内部方法)每次现查,避免用过期的缓存位置。
func _players_frame() -> Array:
	if Engine.is_in_physics_frame():
		var fid := Engine.get_physics_frames()
		if fid != _players_frame_id:
			_players_frame_cache = get_tree().get_nodes_in_group("player")
			_players_frame_id = fid
		return _players_frame_cache
	return get_tree().get_nodes_in_group("player")


# 多玩家目标:取组里距自己最近的玩家(单机唯一玩家 → 行为不变)。无玩家返回 null。
func _nearest_player() -> Node2D:
	var best: Node2D = null
	var best_d := INF
	for p in _players_frame():
		var n := p as Node2D
		if n == null:
			continue
		var d := _toroidal_dist_to(n.global_position)
		if d < best_d:
			best_d = d
			best = n
	return best

# 接触受击目标:重叠的玩家里取最近者;无重叠时若环面距离兜底内(接缝 Area 不重叠)→ 全局最近玩家。
func _contact_victim() -> Node2D:
	var best: Node2D = null
	var best_d := INF
	for b in _overlapping_players:
		var n := b as Node2D
		if n == null or not is_instance_valid(n):
			continue
		var d := _toroidal_dist_to(n.global_position)
		if d < best_d:
			best_d = d
			best = n
	if best != null:
		return best
	return _nearest_player() if toroidal_dist_to_player() <= CONTACT_RADIUS else null

func _player_pos() -> Vector2:
	var p := _nearest_player() as Node2D
	return p.global_position if p != null else global_position


func _player_velocity() -> Vector2:
	var p := _nearest_player()
	if p != null and "velocity" in p:
		return p.velocity
	return Vector2.ZERO


func _cell_of(pos: Vector2) -> Vector2i:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return Vector2i.ZERO
	return MazeGenerator.cell_of(pos, GameParameters.TILE_SIZE, grid[0].size(), grid.size())


func _cell_is_solid(cell: Vector2i) -> bool:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return false
	return TileDefs.is_blocked(grid[cell.y][cell.x])


func _toroidal_dist_to(pos: Vector2) -> float:
	return MazeGenerator.toroidal_delta_px(global_position, pos,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()


func toroidal_dist_to_player() -> float:
	return toroidal_delta_to_player().length()

func toroidal_dir_to_player() -> Vector2:
	var delta := toroidal_delta_to_player()
	if delta == Vector2.INF or delta.is_zero_approx():
		return Vector2.RIGHT  # 无玩家或与玩家重叠时回退水平方向,避免 0/NaN 方向
	return delta.normalized()

func toroidal_delta_to_player() -> Vector2:
	var p := _nearest_player()
	if p == null:
		return Vector2.INF
	return MazeGenerator.toroidal_delta_px(global_position, (p as Node2D).global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)

func _wrap() -> void:
	# PvP 服务器权威:位置存 canonical [0,MAP),不做玩家副本锚定(副本归各端渲染)。
	if network_canonical:
		global_position = MazeGenerator.wrap_to_range(global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		return
	# 环面渲染回绕:把自己锚定到离玩家最近的副本(跟着主角一起取模)。
	# 墙体按 3x3 铺贴,相机在接缝处能看到另一侧的墙副本;若敌人仍取模到
	# [0,MAP),接缝附近就渲染到远副本而「消失」。每次按玩家当前位置重算,
	# 玩家跨接缝时敌人相对位置连续,不会像之前相机方案那样累计漂移。
	var p := _nearest_player() as Node2D
	if p == null:
		# 无玩家(场景切换/加载中)时退回绝对取模,防止敌人无限漂移
		global_position = MazeGenerator.wrap_to_range(global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		return
	global_position = MazeGenerator.anchor_to_nearest(global_position, p.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)

## 回溯还原(WorldRewind 调用):把本敌置回快照帧的状态(含**复活**)。
func rewind_restore(d: Dictionary) -> void:
	var was_dead := is_dead
	global_position = d["p"]
	if d["v"] != null:
		velocity = d["v"]
	hp = int(d["hp"])
	is_dead = bool(d["dead"])
	if was_dead and not is_dead:
		# 复活:重新入世(可见 + 物理 + 取消保留;白闪与计时清零)
		visible = true
		set_physics_process(true)
		# ★ 还原隐藏时摘掉的碰撞层(见 _physics_process 的保留尸体分支)。必须在**复活这一支**
		#   还原:漏了的话复活的怪看不见地穿人 —— 与"虚空碰撞箱"是同一个量、反方向。
		if _rw_held_layer >= 0:
			collision_layer = _rw_held_layer
			_rw_held_layer = -1
		_rewind_hold = false
		if has_meta("rw_death_ms"):
			remove_meta("rw_death_ms")
		_death_timer = -1.0
		_hit_flash_time = 0.0
		_flash_update()
	elif not was_dead and is_dead:
		# 倒回"将死未死"帧:按快照的可见性处理(通常在白闪中点)
		visible = bool(d["vis"])
