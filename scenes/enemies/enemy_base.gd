class_name EnemyBase
extends ServerBody

# 敌人是自管 RID 物理体：移动统一走 CollisionWorld.move_body()，X/Y 两轴依次推进、
# 命中即停；本节点承载 AI 与接触判定，节点变换就是权威数据位姿。

# 进入死亡状态时发射一次(用于击杀计数等 UI;撞人自毁同算,见 FlyBird._die_self)
signal died
signal motion(kind: StringName, speed: float)
enum State { SLEEP, WAKE, CHASE, LUNGE_WINDUP, LUNGE_DASH, BACK_HOP, TAKE_OFF, FLY, SHOOT, CHARGE, RETURN, WANDER }
enum Activity { REST, SETTLE, WAKE, HOP, LUNGE, TAKE_OFF, FLY, CHARGE, RUN, WAIT,
	PREPARE_TELEPORT, TELEPORT, RECOVER, BACK_HOP, DEAD }

# 物理基础(子类可覆写:扑击时关闭重力)
var use_gravity: bool = true

# 战斗参数以场景配置为准。
@export var hp: int = 3
@export var sprite_frames: SpriteFrames
# 接触玩家伤害
@export var contact_damage: int = 1
@export var contact_size := Vector2(44, 40)
@export var contact_offset := Vector2.ZERO
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

const REWIND_NODE: int = 0
const REWIND_POS: int = 1
const REWIND_VEL: int = 2
const REWIND_HP: int = 3
const REWIND_DEAD: int = 4
const REWIND_ACTIVE: int = 5

var combat_rules: CombatSimulator
var time_field: TimeField:
	get: return combat_rules.time_field if combat_rules != null else null
var is_dead: bool = false
var active := true
var _rewind_hold: bool = false   # 录制期死亡保留的尸体(隐藏待复活;非精英)
var rewind_death_time := -1.0
# 隐藏期间被摘掉的碰撞层。-1 表示碰撞层仍有效。
var _rw_held_layer: int = -1
var hit_reaction_left := 0.0
var corpse_left := 0.0
var _overlapping_players: Array = []  # 当前接触到的玩家节点(1v1 PvP 里可能同时撞到两人,受击取最近者)
var _turn_cooldown: float = 0.0  # 转向冷却:两次翻转朝向至少间隔 turn_min_interval
# 每个敌人在同一物理帧内复用所在视口的玩家列表。
var _players_frame_cache: Array = []
var _players_frame_id: int = -1
var wake_radius: float = 1000.0  # 远处睡眠优化:距玩家超此值且落地静止 → 跳过物理
var _swimming := false
var _waterproof: int = 6                 # 防水值(氧气)
var waterproof_max: int = 6              # 上限:black/jump 6,fly 10
var _waterproof_drain_timer: float = 0.0
var _waterproof_recover_timer: float = 0.0
var _drown_timer: float = 0.0
var state := State.SLEEP
var _state_timer: float = 0.0
var _sleep_left := 0.0
var _wake_timer := 0.0
var activity := Activity.REST
var facing_left := false
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
	if _physics != null:
		CollisionWorld.sync_body_shapes(_rid, hulls, global_transform, _active_stance)

func collision_rect() -> Rect2:
	var hull: Node2D = hulls[_active_stance]
	return hull.global_transform * CollisionWorld.carrier_shape(hull).get_rect()

## 击退位移：命中即停，不滑行（与引擎 move_and_collide 同语义）。
func _move_knock(motion: Vector2) -> void:
	if motion == Vector2.ZERO:
		return
	var out := CollisionWorld.move_body(_rid, global_transform, motion)
	global_position += (out[1] as PhysicsTestMotionResult2D).get_travel()

## 主移动：两轴推进、命中即停；瓦片地形全是轴对齐矩形，
## 不需要引擎的坡度/吸附/平台逻辑。向下被挡且法线朝上即着地。
func _move_slide(travel: Vector2) -> void:
	var out := axis_move(travel)
	_move_hits = out["hits"]
	var blocked: Vector2 = out["blocked"]
	var landed := blocked.y > 0.0 and float(out["ground"]) < -0.5
	if landed and not _grounded:
		motion.emit(&"land", velocity.y)
	_grounded = landed
	if blocked.x != 0.0:
		velocity.x = 0.0
	if blocked.y > 0.0:
		velocity.y = 0.0

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

# 落水时水平游泳方向(基类默认零=漂着;JumpBird/BlackBird 覆写为朝玩家)。
func _water_swim_dir() -> Vector2:
	return Vector2.ZERO

static func in_viewport(viewport: Viewport) -> Array[Node]:
	return viewport.get_tree().get_nodes_in_group("enemies").filter(func(enemy: Node) -> bool:
		return enemy.get_viewport() == viewport)

func _ready() -> void:
	add_to_group("enemies")
	_setup_contact_area()
	# 姿态壳载体：直接子节点里的形状节点（ContactArea 内部的形状不算）。
	for child in get_children():
		if child is CollisionShape2D or child is CollisionPolygon2D:
			hulls.append(child)
	_sync_collision()

func _setup_contact_area() -> void:
	var area := Area2D.new()
	area.name = "ContactArea"
	area.collision_layer = 0
	area.collision_mask = 2  # 检测玩家(layer 2)
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = contact_size
	shape.shape = rect
	shape.position = contact_offset
	area.add_child(shape)
	add_child(area)
	area.body_entered.connect(_on_contact_body_entered)
	area.body_exited.connect(_on_contact_body_exited)

func _on_contact_body_entered(body: Node) -> void:
	if body.is_in_group("player"):
		if not _overlapping_players.has(body):
			_overlapping_players.append(body)

func _on_contact_body_exited(body: Node) -> void:
	if body.is_in_group("player"):
		_overlapping_players.erase(body)

func _physics_process(delta: float) -> void:
	if active:
		simulate_tick(delta)

func simulate_tick(delta: float) -> void:
	# 出生和回放可能直接写位姿，冻结时也要同步到物理空间。
	CollisionWorld.sync_body_pose(_rid, global_transform)
	if time_field != null:
		delta = time_field.enemy_delta(delta, has_meta("elite"))
		if delta == 0.0:
			return
	if _is_far_sleeping():
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
		# 接触伤害:物理 Area 覆盖常规情况;环面接缝处欧氏距离不重叠,用环面距离保底处理
		# contact_damage<=0 时跳过:零伤也会触发玩家 take_hit 消耗 iframe 并击退。
		if contact_damage > 0:
			var p := _contact_victim()
			if p != null:
				combat_rules.resolve_hit(self, p, CombatProfiles.ENEMY_HIT, global_position, contact_damage, -1.0)
	hit_reaction_left = maxf(hit_reaction_left - delta, 0.0)
	if corpse_left > 0.0:
		corpse_left -= delta
		if corpse_left <= 0.0:
			if _rewind_hold:
				# 保留尸体供回溯复活；隐藏时移除碰撞层避免成为隐形空气墙
				active = false
				_rw_held_layer = collision_layer
				collision_layer = 0
				_apply_layers()
			else:
				queue_free()
			return
	if is_dead:
	# 尸体速度继续衰减。
		velocity *= exp(-knock_decay_rate * delta)
	_apply_water(delta)
	# 击退独立碰撞，避免落地冲量污染移动速度；主移动最后更新地面状态。
	_move_knock(knock_velocity * delta)
	knock_velocity *= exp(-knock_decay_rate * delta)
	_move_slide(velocity * delta)
	_wrap()
	# AI 可能直接摆位（寻路到点、滑翔到位）；槽位不变，帧末只补位姿。
	CollisionWorld.sync_body_pose(_rid, global_transform)

func hurt(damage: int, knock_dir: Vector2, knock_strength: float = 0.0, set_velocity: bool = false) -> void:
	var ks := knockback_strength if knock_strength <= 0.0 else knock_strength
	# 枪击叠加速度，爆炸设置独立击退向量。尸体也接受冲量。
	if set_velocity:
		knock_velocity = knock_dir.normalized() * ks
	else:
		velocity += knock_dir.normalized() * ks
	if is_dead:
		return
	hp -= damage
	hit_reaction_left = EnemyParams.shared.hit_reaction_time
	motion.emit(&"hurt", 0.0)
	if hp <= 0:
		_begin_death()


# 远处睡眠判定:距玩家超唤醒半径、落地静止、非受击/死亡/非SLEEP → true。
func _is_far_sleeping() -> bool:
	if is_dead or hit_reaction_left > 0.0 or state != State.SLEEP:
		return false
	if not _grounded:
		return false
	if absf(velocity.x) > 5.0 or absf(velocity.y) > 5.0:
		return false
	return toroidal_dist_to_player() > wake_radius


func _apply_water(delta: float) -> void:
	var bounds := collision_rect()
	var feet := Water.feet(bounds)
	var depth := Water.swim_depth(terrain, feet, _swimming)
	_swimming = depth != -INF
	if _swimming:
		var surface_y := feet.y - depth
		var target_vy := clampf((surface_y - global_position.y) * EnemyParams.shared.bird_buoyancy_k,
			-EnemyParams.shared.bird_max_float, EnemyParams.shared.bird_max_sink)
		velocity.y = MathUtil.approach(velocity.y, target_vy, EnemyParams.shared.bird_water_damp, delta)
		var dir := _water_swim_dir()
		velocity.x = MathUtil.approach(velocity.x, dir.x * EnemyParams.shared.bird_swim_speed,
			EnemyParams.shared.bird_water_damp, delta)
	if is_dead:
		return
	var submerged := Water.head_submerged(terrain, bounds)
	if submerged and _waterproof == 0:
		_drown_timer += delta
		if _drown_timer >= EnemyParams.shared.drown_interval:
			_drown_timer = 0.0
			combat_rules.resolve_hit(null, self, CombatProfiles.DROWN, global_position,
					EnemyParams.shared.drown_damage, 0.0)
		return
	_drown_timer = 0.0
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
func _begin_death() -> void:
	if is_dead:
		return
	is_dead = true
	died.emit()
	corpse_left = EnemyParams.shared.corpse_time
	if time_field != null and not time_field.is_rewinding() and not has_meta("elite"):
		_rewind_hold = true
	_on_death()


# 死亡计时建立后执行子类动作。
func _on_death() -> void:
	pass


func _smash_player(p: Player, impact: float, impact_up: float) -> void:
	var away := GridPathfinder.toroidal_delta_px(global_position, p.global_position, terrain.map_size).normalized()
	if away == Vector2.ZERO:
		away = Vector2(-float(p.facing_direction), 0.0)
	p.velocity = away * impact
	p.velocity.y -= impact_up


# 统一转向:两次翻转朝向至少间隔 turn_min_interval,防止敌人来回抖(看起来像 bug)。
# 朝向未变时不消耗冷却(持续面向玩家不会因此锁定约束)。
func _set_facing(left: bool) -> void:
	if _turn_cooldown > 0.0 or facing_left == left:
		return
	_turn_cooldown = EnemyParams.shared.turn_min_interval
	facing_left = left



func _set_state(s: State) -> void:
	state = s
	_state_timer = 0.0

func _settle_sleep(duration: float) -> void:
	activity = Activity.SETTLE
	_sleep_left = duration

func _sleep_idle(delta: float) -> void:
	_sleep_left = maxf(_sleep_left - delta, 0.0)
	if _sleep_left == 0.0:
		activity = Activity.REST

func _wake_ready(delta: float, distance: float, duration: float) -> bool:
	if _wake_timer > 0.0:
		_wake_timer -= delta
		return _wake_timer <= 0.0
	var can_wake := _sleep_left <= 0.0
	_sleep_idle(delta)
	if can_wake and distance <= wake_radius:
		activity = Activity.WAKE
		_wake_timer = duration
	return false


# 玩家列表仅在同一物理帧内缓存。
func _players_frame() -> Array:
	var frame := Engine.get_physics_frames() if Engine.is_in_physics_frame() else -1
	if frame >= 0 and frame == _players_frame_id:
		return _players_frame_cache
	var viewport := get_viewport()
	var players := get_tree().get_nodes_in_group("player").filter(func(player: Node) -> bool:
		return player.get_viewport() == viewport)
	if frame >= 0:
		_players_frame_id = frame
		_players_frame_cache = players
	return players

func _nearest_in(candidates: Array, radius := INF) -> Player:
	var nearest: Player
	var best_distance := INF
	for candidate in candidates:
		if not is_instance_valid(candidate) or not candidate is Player:
			continue
		var distance := _toroidal_dist_to(candidate.global_position)
		if distance < best_distance:
			best_distance = distance
			nearest = candidate
	return nearest if best_distance <= radius else null

func _nearest_player(radius := INF) -> Player:
	return _nearest_in(_players_frame(), radius)

func _contact_victim() -> Player:
	var overlapping := _nearest_in(_overlapping_players)
	return overlapping if overlapping != null else _nearest_player(CONTACT_RADIUS)

# 冲锋在接触任一玩家时命中全局最近者，接缝处用环面距离判定。
func _charge_victim() -> Player:
	return _nearest_player(CONTACT_RADIUS if _overlapping_players.is_empty() else INF)

func _player_pos() -> Vector2:
	var p := _nearest_player()
	return p.global_position if p != null else global_position


func _player_velocity() -> Vector2:
	var p := _nearest_player()
	return p.velocity if p != null else Vector2.ZERO


func _cell_of(pos: Vector2) -> Vector2i:
	return terrain.cell(pos)


func _cell_is_solid(cell: Vector2i) -> bool:
	return TileDefs.is_blocked(terrain.value(cell))


func _toroidal_dist_to(pos: Vector2) -> float:
	return GridPathfinder.toroidal_delta_px(global_position, pos, terrain.map_size).length()


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
	return GridPathfinder.toroidal_delta_px(global_position, p.global_position, terrain.map_size)

# 物理位置始终落在规范区间；只有渲染按最近环面副本平移，绝不影响碰撞查询。
func _wrap() -> void:
	global_position = GridPathfinder.wrap_to_range(global_position, terrain.map_size)

func capture_rewind_state() -> Array:
	return [self, global_position, velocity, hp, is_dead, active]

func rewind_restore(state_values: Array) -> void:
	var was_dead := is_dead
	global_position = state_values[REWIND_POS]
	velocity = state_values[REWIND_VEL]
	hp = state_values[REWIND_HP]
	is_dead = state_values[REWIND_DEAD]
	if was_dead and not is_dead:
		active = true
		# 恢复隐藏时摘掉的碰撞层
		if _rw_held_layer >= 0:
			collision_layer = _rw_held_layer
			_apply_layers()
			_rw_held_layer = -1
		_rewind_hold = false
		rewind_death_time = -1.0
		corpse_left = 0.0
		hit_reaction_left = 0.0
	elif not was_dead and is_dead:
		active = state_values[REWIND_ACTIVE]
	CollisionWorld.sync_body_pose(_rid, global_transform)
