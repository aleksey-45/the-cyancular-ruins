class_name EnemyBase
extends ServerBody

# 敌人是自管 RID 物理体：移动统一走 CollisionWorld.move_body()，X/Y 两轴依次推进、
# 命中即停；本节点承载 AI、动画与接触判定，节点变换就是权威数据位姿。

# 进入死亡状态时发射一次(用于击杀计数等 UI;撞人自毁同算,见 FlyBird._die_self)
signal died

# 物理基础(子类可覆写:扑击时关闭重力)
var use_gravity: bool = true

# 战斗参数以场景配置为准。
@export var hp: int = 3
# 接触玩家伤害
@export var contact_damage: int = 1
# 受击击退力度
@export var knockback_strength: float = 150.0
# 爆炸专属击退向量:独立于 AI 移动速度,每帧叠加后指数衰减(大冲击+迅速衰减)
var knock_velocity: Vector2 = Vector2.ZERO
# 击退向量指数衰减率(越大停得越快;约 0.23s 衰减到 ~10%)
@export var knock_decay_rate: float = 10.0

# 环面接缝保底处理:物理 Area 用欧氏距离,跨接缝不重叠,这里用环面距离补(略大于 ContactArea 半对角线)
const CONTACT_RADIUS: float = 40.0

const GROUND_FRICTION: float = 0.85  # 落地时水平速度衰减系数
const STOP_EPSILON: float = 5.0      # 水平速度低于此值直接归零,避免贴地滑行

var is_dead: bool = false
var _rewind_hold: bool = false   # 录制期死亡保留的尸体(隐藏待复活;非精英)
# 隐藏期间被摘掉的碰撞层(见 _physics_process 的保留尸体分支);-1 = 层未被摘、无需还原。
var _rw_held_layer: int = -1
var _hit_flash_time: float = 0.0
var _death_timer: float = -1.0   # 死亡白闪剩余;<0 未死亡(受击/死亡白闪统一在基类)
var _overlapping_players: Array = []  # 当前接触到的玩家节点(1v1 PvP 里可能同时撞到两人,受击取最近者)
var _turn_cooldown: float = 0.0  # 转向冷却:两次翻转朝向至少间隔 turn_min_interval
# 玩家组每帧缓存:同一物理帧内 _players_frame() 只建一次数组,砍掉每帧每敌多次 get_nodes_in_group 分配。
var _players_frame_cache: Array = []
var _players_frame_id: int = -1
var wake_radius: float = 1000.0  # 远处睡眠优化:距玩家超此值且落地静止 → 跳过物理
var _waterproof: int = 6                 # 防水值(氧气),完全没入水中每 0.5s 掉 1
var waterproof_max: int = 6              # 上限:black/jump 6,fly 10
var _waterproof_drain_timer: float = 0.0
var _waterproof_recover_timer: float = 0.0
var _drown_tick: float = 0.0     # 扣除生命值倒计时
# 状态机与动画(子类共用)。state 用 int 承载各子类自己的 enum 常量(见 JumpBird/FlyBird 的 enum State)。
var state: int = 0
var _state_timer: float = 0.0
var _anim: AnimatedSprite2D
var _anim_base := Vector2.ZERO
# 逻辑与物理位置保持规范坐标；渲染按最近环面副本平移。
var _visual_offset := Vector2.ZERO
# 补间形变(squash & stretch)。纯表现层,不进任何网络同步、不碰碰撞箱。
var squash: SquashStretch = null
# 记录主移动前的垂直速度，用于落地形变判定
var _pre_move_vy: float = 0.0
# 自管 RID 体生命周期在 ServerBody；这里只补充形状槽与运动策略。
var velocity := Vector2.ZERO
var _grounded := false
# 姿态壳载体（CollisionShape2D/CollisionPolygon2D 直接子节点）；_active_stance 指向当前启用槽。
var hulls: Array = []
var _active_stance := 0
# 主移动本帧的接触：{"rid", "id", "normal", "point"}；冲撞判定等子类逻辑读取。
var _move_hits: Array = []


func _enter_tree() -> void:
	super()   # 空间挂接、层掩码提交与归属挂载
	# 此时 hulls 还没填充（_ready 才收集），只提交当前位姿。
	CollisionWorld.sync_body_pose(_rid, global_transform)

## 形状槽同步：载体给出形状与局部变换，位姿取当前节点变换。
func _sync_collision() -> void:
	if _world_space.is_valid():
		CollisionWorld.sync_body_shapes(_rid, hulls, global_transform, _active_stance)

## 击退位移：命中即停，不滑行（与引擎 move_and_collide 同语义）。
func _move_knock(motion: Vector2) -> void:
	if motion == Vector2.ZERO:
		return
	var out := CollisionWorld.move_body(_rid, global_transform, motion)
	global_position += (out[1] as PhysicsTestMotionResult2D).get_travel()

## 主移动：两轴推进、命中即停；瓦片地形全是轴对齐矩形，
## 不需要引擎的坡度/吸附/平台逻辑。向下被挡且法线朝上即着地。
func _move_slide(motion: Vector2) -> void:
	var out := axis_move(motion)
	_move_hits = out["hits"]
	var blocked: Vector2 = out["blocked"]
	_grounded = false
	if blocked.x != 0.0:
		velocity.x = 0.0
	if blocked.y > 0.0:
		velocity.y = 0.0
		_grounded = float(out["ground"]) < -0.5

## 本帧主移动被侧向挡住（原 CharacterBody2D.is_on_wall 的等价判定）。
## _move_hits 是最近一次 _move_slide 的接触；轴对齐瓦片的法线非横即纵，
## |normal.y| < 0.5 即竖直墙面（着地/天花板法线朝上下，被排除）。
func _hit_wall() -> bool:
	for hit: Dictionary in _move_hits:
		if absf((hit["normal"] as Vector2).y) < 0.5:
			return true
	return false

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
	# 姿态壳载体：直接子节点里的形状节点（ContactArea 内部的形状不算）。
	for child in get_children():
		if child is CollisionShape2D or child is CollisionPolygon2D:
			hulls.append(child)
	call_deferred("add_child", WaterFx.new())
	# 初始化挤压拉伸形变组件
	squash = SquashStretch.new()
	add_child(squash)
	# 校验动画节点有效性
	var anim := get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	_anim = anim
	if anim != null:
		_anim_base = anim.position
	else:
		push_error("EnemyBase: 找不到 AnimatedSprite2D 节点,补间形变将静默失效(节点名 = %s)"
				% name)
	squash.setup(anim, SquashStretch.Profile.ENEMY)
	_sync_collision()

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

# 接触判定只由重叠列表决定，不再单独维护一份布尔量。
func _touching_player() -> bool:
	return not _overlapping_players.is_empty()

func _on_contact_body_entered(body: Node) -> void:
	if body.is_in_group("player"):
		if not _overlapping_players.has(body):
			_overlapping_players.append(body)

func _on_contact_body_exited(body: Node) -> void:
	if body.is_in_group("player"):
		_overlapping_players.erase(body)

func _physics_process(delta: float) -> void:
	delta = TimeField.enemy_delta(delta, self)   # 时间场:回溯冻结/加速/透支(精英例外)
	# 出生摆位/回放摆位等外部直写先同步进物理空间，再进入本帧逻辑；槽位不变，只写位姿。
	CollisionWorld.sync_body_pose(_rid, global_transform)
	# 回溯中普通敌人整帧跳过(位置由回放器摆;接触伤害/白闪/AI 全不结算);精英照常
	if TimeField.current != null and TimeField.current.is_rewinding() and not has_meta("elite"):
		return
	# 睡眠状态重置垂直速度缓存，避免苏醒首帧因旧速度缓存触发意外挤压形变
	var sleeping := _is_far_sleeping()
	squash.tick(delta, _pre_move_vy, _grounded, is_dead)
	if sleeping:
		_pre_move_vy = 0.0
		_ai(delta)
		_wrap()
		CollisionWorld.sync_body_pose(_rid, global_transform)
		return
	_turn_cooldown = maxf(_turn_cooldown - delta, 0.0)
	if use_gravity and not _grounded:
		velocity.y += GameParameters.gravity0 * delta
	# 摩擦先于 AI，避免削弱本帧刚设定的跳跃和冲刺速度。
	if use_gravity and _grounded:
		velocity.x *= GROUND_FRICTION
		if absf(velocity.x) < STOP_EPSILON:
			velocity.x = 0.0
	# 死亡:AI 不行动,但物理(重力/摩擦/击退/碰撞)与生前完全一致。
	if not is_dead:
		_ai(delta)
		_anim_update()
		# 接触伤害:物理 Area 覆盖常规情况;环面接缝处欧氏距离不重叠,用环面距离保底处理
		# contact_damage<=0 时跳过:零伤也会触发玩家 take_hit 消耗 iframe 并击退。
		if contact_damage > 0 and (_touching_player() or toroidal_dist_to_player() <= CONTACT_RADIUS):
			var p := _contact_victim()
			if p != null:
				p.take_hit(global_position, contact_damage)
	# 受击/死亡白闪统一:计时 + 渲染(子类可覆写 _flash_update 换渲染方式,如黑鸟 silhouette)
	if _hit_flash_time > 0.0:
		_hit_flash_time = maxf(_hit_flash_time - delta, 0.0)
	if _death_timer > 0.0:
		_death_timer -= delta
		if _death_timer <= 0.0:
			if _rewind_hold:
				# 保留尸体供回溯复活；隐藏时移除碰撞层避免成为隐形空气墙
				visible = false
				set_physics_process(false)
				_rw_held_layer = collision_layer
				collision_layer = 0
				_apply_layers()
				_death_timer = -1.0
			else:
				queue_free()
			return
	_flash_update()
	if is_dead:
	# 尸体速度继续衰减。
		velocity *= exp(-knock_decay_rate * delta)
	_apply_water(delta)
	# 击退独立碰撞，避免落地冲量污染移动速度；主移动最后更新地面状态。
	_move_knock(knock_velocity * delta)
	knock_velocity *= exp(-knock_decay_rate * delta)
	# 记录移动前的垂直速度供落地形变计算
	_pre_move_vy = velocity.y
	# 时间场:水平运动走速度域(引擎帧长与 delta 缩放的差异由倍率吸收);
	# 计时器/动画/重力仍走上面的 delta 缩放。精英与玩家同步,普通敌放慢。
	velocity.x *= TimeField.enemy_speed_mult(self)
	_move_slide(velocity * delta)
	_wrap()
	# AI 可能直接摆位（寻路到点、滑翔到位）；槽位不变，帧末只补位姿。
	CollisionWorld.sync_body_pose(_rid, global_transform)

func hurt(damage: int, knock_dir: Vector2, knock_strength: float = 0.0, set_velocity: bool = false) -> void:
	if is_dead:
		# 尸体:不再扣除生命值/触发死亡,但冲击波仍能推动(不吞冲击波)
		_apply_knock_only(knock_dir, knock_strength, set_velocity)
		return
	_apply_hit(damage, knock_dir, knock_strength, set_velocity)
	if hp <= 0:
		_begin_death()

# 枪击叠加速度；爆炸设置独立击退向量。
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

# 尸体专用:只施加击退(爆炸=设独立向量、枪击=叠加速度),不扣除生命值、不触发死亡/白闪。
func _apply_knock_only(knock_dir: Vector2, knock_strength: float, set_velocity: bool) -> void:
	var ks := knockback_strength if knock_strength <= 0.0 else knock_strength
	if set_velocity:
		knock_velocity = knock_dir.normalized() * ks
	else:
		velocity += knock_dir.normalized() * ks


# 判断当前敌人是否处于休眠状态（由各子类根据自身枚举具体实现）
func _is_asleep() -> bool:
	return state == 0


# 远处睡眠判定:距玩家超唤醒半径、落地静止、非受击/死亡/非SLEEP → true。
func _is_far_sleeping() -> bool:
	if is_dead or _hit_flash_time > 0.0 or _death_timer > 0.0:
		return false
	if not _is_asleep():
		return false
	if not _grounded:
		return false
	if absf(velocity.x) > 5.0 or absf(velocity.y) > 5.0:
		return false
	return toroidal_dist_to_player() > wake_radius


# 落水浮力:弹簧把身体中心拉回水面线(半没入);水平朝 _water_swim_dir 游;完全没入水中累计溺水。
func _apply_water(delta: float) -> void:
	var feet := Vector2(global_position.x, global_position.y + Water.feet_offset(self))
	var in_water := Water.is_in_water(feet)
	var submerged := false
	if in_water:
		var surface_y := Water.surface_y_at(global_position)
		submerged = Water.submerged(global_position, surface_y)
		var target_vy := clampf((surface_y - global_position.y) * EnemyParams.shared.bird_buoyancy_k,
			-EnemyParams.shared.bird_max_float, EnemyParams.shared.bird_max_sink)
		velocity.y = MathUtil.approach(velocity.y, target_vy, EnemyParams.shared.bird_water_damp, delta)
		var dir := _water_swim_dir()
		velocity.x = MathUtil.approach(velocity.x, dir.x * EnemyParams.shared.bird_swim_speed,
			EnemyParams.shared.bird_water_damp, delta)
	# 防水值(氧气):没覆盖,暴露空气回;空后每秒扣除生命值
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
# 统一死亡状态、信号和白闪计时；附加动作由 _on_death 处理。
func _begin_death() -> void:
	if is_dead:
		return
	is_dead = true
	died.emit()
	_death_timer = EnemyParams.shared.death_flash_time
	# 录制期保留尸体:不 queue_free,白闪结束后隐藏待复活(精英除外——杀了就是杀了)
	if WorldRewind.hold_corpses and not has_meta("elite"):
		_rewind_hold = true
		set_meta("rw_death_ms", Time.get_ticks_msec())
	_on_death()


# 死亡计时建立后执行子类动作。
func _on_death() -> void:
	pass


func _smash_player(p: Player, impact: float, impact_up: float) -> void:
	var away := (p.global_position - global_position).normalized()
	if away == Vector2.ZERO:
		away = Vector2(-float(p.get_facing()), 0.0)
	p.velocity = away * impact
	p.velocity.y -= impact_up


# 白闪渲染:受击/死亡任一激活即纯白,否则恢复。默认走 modulate;黑鸟因 silhouette
# shader 覆写 COLOR 而 modulate 失效,覆写本方法改走 shader 参数。
func _flash_update() -> void:
	modulate = Color(3.0, 3.0, 3.0, 1.0) if _hit_flash_time > 0.0 or _death_timer > 0.0 else Color.WHITE


# 统一转向:两次翻转朝向至少间隔 turn_min_interval,防止敌人来回抖(看起来像 bug)。
# 朝向未变时不消耗冷却(持续面向玩家不会因此锁定约束)。
func _set_facing(facing_left: bool) -> void:
	if _turn_cooldown > 0.0 or _anim.flip_h == facing_left:
		return
	_turn_cooldown = EnemyParams.shared.turn_min_interval
	_anim.flip_h = facing_left



func _set_state(s: int) -> void:
	state = s
	_state_timer = 0.0
	_on_state_entered(s)


# 状态进入虚方法，供子类覆写以处理特定状态进入时的表现与音效
func _on_state_entered(_s: int) -> void:
	pass


func _anim_duration(name: String) -> float:
	if _anim == null:
		return 0.0
	var spf := _anim.sprite_frames
	return float(spf.get_frame_count(name)) / spf.get_animation_speed(name)


# 玩家列表仅在同一物理帧内缓存。
func _players_frame() -> Array:
	if Engine.is_in_physics_frame():
		var fid := Engine.get_physics_frames()
		if fid != _players_frame_id:
			_players_frame_cache = get_tree().get_nodes_in_group("player")
			_players_frame_id = fid
		return _players_frame_cache
	return get_tree().get_nodes_in_group("player")


# 多玩家目标:取组里距自己最近的玩家(单机唯一玩家 → 行为不变)。无玩家返回 null。
func _nearest_player() -> Player:
	var best: Player = null
	var best_d := INF
	for p in _players_frame():
		var n := p as Player
		if n == null:
			continue
		var d := _toroidal_dist_to(n.global_position)
		if d < best_d:
			best_d = d
			best = n
	return best

# 接触受击目标:重叠的玩家里取最近者;无重叠时若环面距离保底处理内(接缝 Area 不重叠)→ 全局最近玩家。
func _contact_victim() -> Player:
	var best: Player = null
	var best_d := INF
	for b in _overlapping_players:
		var n := b as Player
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
	var p := _nearest_player()
	return p.global_position if p != null else global_position


func _player_velocity() -> Vector2:
	var p := _nearest_player()
	return p.velocity if p != null else Vector2.ZERO


func _cell_of(pos: Vector2) -> Vector2i:
	return TileDefs.terrain.cell(pos)


func _cell_is_solid(cell: Vector2i) -> bool:
	return TileDefs.is_blocked(TileDefs.terrain.value(cell))


func _toroidal_dist_to(pos: Vector2) -> float:
	return GridPathfinder.toroidal_delta_px(global_position, pos,
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
	return GridPathfinder.toroidal_delta_px(global_position, p.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)

# 物理位置始终落在规范区间；只有渲染按最近环面副本平移，绝不影响碰撞查询。
func _wrap() -> void:
	var canonical := GridPathfinder.wrap_to_range(global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	var p := _nearest_player() as Node2D
	var shown := canonical
	if p != null:
		shown = GridPathfinder.anchor_to_nearest(canonical, p.global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	if global_position != canonical:
		global_position = canonical
	_visual_offset = shown - canonical
	if _anim != null:
		_anim.position = _anim_base + _visual_offset

# 回溯状态恢复（WorldRewind 调用）：将敌人重置为快照帧的状态（包含存活与复活处理）
func rewind_restore(d: Dictionary) -> void:
	var was_dead := is_dead
	global_position = d["p"]
	velocity = d["v"]
	hp = int(d["hp"])
	is_dead = bool(d["dead"])
	if was_dead and not is_dead:
		# 复活:重新入世(可见 + 物理 + 取消保留;白闪与计时清零)
		visible = true
		set_physics_process(true)
		# 恢复隐藏时摘掉的碰撞层
		if _rw_held_layer >= 0:
			collision_layer = _rw_held_layer
			_apply_layers()
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
	# 回放只摆位姿，不切姿态槽。
	CollisionWorld.sync_body_pose(_rid, global_transform)
