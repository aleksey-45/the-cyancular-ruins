class_name EnemyBase
extends ActorBody

const ECFG: EnemyConfig = preload("res://core/config/enemy_config.tres")

const WCFG: WorldConfig = preload("res://core/config/world_config.tres")

# 各类敌人共用这套移动和伤害规则，行动方式由各自的脚本实现。

enum State { SLEEP, WAKE, CHASE, LUNGE_WINDUP, LUNGE_DASH, BACK_HOP, TAKE_OFF, FLY, SHOOT, CHARGE, RETURN, WANDER }
enum Activity { REST, SETTLE, WAKE, HOP, LUNGE, TAKE_OFF, FLY, CHARGE, RUN, WAIT,
	PREPARE_TELEPORT, TELEPORT, RECOVER, BACK_HOP, DEAD }

var use_gravity: bool = true

var kind: EnemyType
var player: Player
var slot: int
var hp: int
var knock_velocity := Vector2.ZERO
var knock_decay_rate := 10.0

const GROUND_FRICTION: float = 0.85  # 每次处理地面摩擦时，保留的水平速度比例。
const STOP_EPSILON: float = 5.0      # 地面摩擦使水平速度的绝对值降到此值以下时，视为已经停下。

var _rewind_fields: Array[StringName] = [&"position", &"velocity", &"hp", &"is_dead", &"active", &"corpse_left", &"hit_reaction_left",
		&"activity", &"use_gravity", &"knock_velocity", &"_grounded", &"stance", &"state", &"_state_timer",
		&"_wake_timer", &"_sleep_left", &"facing_left", &"_turn_cooldown", &"_swimming", &"_waterproof",
		&"_waterproof_drain_timer", &"_waterproof_recover_timer", &"_drown_timer"]
var is_dead := false
var active := true
var hit_reaction_left := 0.0
var corpse_left := 0.0
var _turn_cooldown: float = 0.0
var wake_radius: float = 1000.0
var _swimming := false
var _waterproof: int = 6
var waterproof_max: int = 6
var _waterproof_drain_timer: float = 0.0
var _waterproof_recover_timer: float = 0.0
var _drown_timer: float = 0.0
var state := State.SLEEP
var _state_timer: float = 0.0
var _sleep_left := 0.0
var _wake_timer := 0.0
var activity := Activity.REST
var facing_left := false
var _grounded := false
var stance := 0:
	set(value):
		if stance != value:
			stance = value
			PhysicsServer2D.body_set_shape(rid, 0, kind.hulls[stance])
			PhysicsServer2D.body_set_state(rid, PhysicsServer2D.BODY_STATE_TRANSFORM, transform)
var hull: ConvexPolygonShape2D:
	get: return kind.hulls[stance]
var _move_result := PhysicsTestMotionResult2D.new()

func _init(match_sim: CombatSimulator, target: Player, at: Vector2, definition: EnemyType) -> void:
	kind = definition
	super(match_sim, at, definition.body_scale, hull, CombatProfiles.Layer.ENEMY,
			CombatProfiles.Layer.TERRAIN | CombatProfiles.Layer.ENEMY)
	slot = match_sim.enemies.size()
	player = target
	hp = kind.hp
	_setup()

func _setup() -> void:
	pass

func collision_rect() -> Rect2:
	return transform * hull.get_rect()

func touches_player() -> bool:
	return not terrain.physics.shape_overlaps(CollisionWorld.rectangle(kind.contact_size),
			transform.translated_local(kind.contact_offset),
			CombatProfiles.Layer.TEAM_A | CombatProfiles.Layer.TEAM_B).is_empty()

## 爆炸击退单独做一次碰撞检测，不改变落地状态。
func _move_knock(motion: Vector2) -> void:
	if motion == Vector2.ZERO:
		return
	CollisionWorld.probe_body(rid, transform, motion, _move_result)
	position += _move_result.get_travel()

## 按水平、垂直的顺序处理移动。落地时在清零垂直速度之前发送 motion 信号，让音效和动画能使用落地速度。
func _move_slide(travel: Vector2) -> void:
	motion_contacts.clear()
	var blocked := Vector2.ZERO
	var pose := transform
	for axis in 2:
		if travel[axis] == 0.0:
			continue
		var step := Vector2.ZERO
		step[axis] = travel[axis]
		var hit := CollisionWorld.probe_body(rid, pose, step, _move_result)
		pose.origin += _move_result.get_travel()
		if hit and CollisionWorld.axis_blocked(_move_result, axis, travel[axis]):
			_record_contact(_move_result)
			blocked[axis] = signf(travel[axis])
	transform = pose
	var landed: bool = blocked.y > 0.0 and motion_contacts[-1][Contact.NORMAL].y < -0.5
	_grounded = landed
	if blocked.x != 0.0:
		velocity.x = 0.0
	if blocked.y > 0.0:
		velocity.y = 0.0

## 以接触法线的 Y 分量判断是否撞墙。绝对值小于 0.5 的接触面主要阻挡水平移动。
func _hit_wall() -> bool:
	for hit: Array in motion_contacts:
		if absf((hit[Contact.NORMAL] as Vector2).y) < 0.5:
			return true
	return false

func _ai(_delta: float) -> void:
	pass

# 各类敌人可指定入水后的游动方向。默认没有主动的水平游动。
func _water_swim_dir() -> Vector2:
	return Vector2.ZERO

func simulate_tick(delta: float) -> void:
	if time_field != null:
		delta = time_field.enemy_delta(delta, kind.elite)
	if delta == 0.0:
		return
	if _is_far_sleeping():
		_ai(delta)
		_wrap()
		return
	_turn_cooldown = maxf(_turn_cooldown - delta, 0.0)
	if use_gravity and not _grounded:
		velocity.y += WCFG.gravity0 * delta
	if use_gravity and _grounded:
		velocity.x *= GROUND_FRICTION
		if absf(velocity.x) < STOP_EPSILON:
			velocity.x = 0.0
	# 死亡只停止敌人行动和接触伤害。尸体仍参与下面的物理更新。
	if not is_dead:
		_ai(delta)
		if kind.contact_damage > 0 and touches_player():
			combat.resolve_hit(self, player, CombatProfiles.ENEMY_HIT, position, kind.contact_damage, -1.0)
	hit_reaction_left = maxf(hit_reaction_left - delta, 0.0)
	if corpse_left > 0.0:
		corpse_left -= delta
		if corpse_left <= 0.0:
			active = false
			collision_layer = 0
			return
	if is_dead:
		velocity *= exp(-knock_decay_rate * delta)
	_apply_water(delta)
	# 爆炸击退先改变位置，随后处理正常移动。正常移动的接触点用于判断落地。
	_move_knock(knock_velocity * delta)
	knock_velocity *= exp(-knock_decay_rate * delta)
	_move_slide(velocity * delta)
	_wrap()

func hurt(damage: int, knock_dir: Vector2, knock_strength: float = 0.0, set_velocity: bool = false) -> void:
	var ks := 200.0 if knock_strength <= 0.0 else knock_strength
	# 爆炸替换独立的击退速度，普通攻击把击退加到移动速度上。两种攻击都可以推开尸体。
	if set_velocity:
		knock_velocity = knock_dir.normalized() * ks
	else:
		velocity += knock_dir.normalized() * ks
	if is_dead:
		return
	hp -= damage
	hit_reaction_left = ECFG.shared_hit_reaction_time
	if hp <= 0:
		_begin_death()


# 离玩家足够远、接近静止且已落地的休眠敌人，每帧只检查是否应当醒来。
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
		var target_vy := clampf((surface_y - position.y) * ECFG.shared_bird_buoyancy_k,
			-ECFG.shared_bird_max_float, ECFG.shared_bird_max_sink)
		velocity.y = MathUtil.approach(velocity.y, target_vy, ECFG.shared_bird_water_damp, delta)
		var dir := _water_swim_dir()
		velocity.x = MathUtil.approach(velocity.x, dir.x * ECFG.shared_bird_swim_speed,
			ECFG.shared_bird_water_damp, delta)
	if is_dead:
		return
	var submerged := Water.head_submerged(terrain, bounds)
	if submerged and _waterproof == 0:
		_drown_timer += delta
		if _drown_timer >= ECFG.shared_drown_interval:
			_drown_timer = 0.0
			combat.resolve_hit(null, self, CombatProfiles.DROWN, position,
					ECFG.shared_drown_damage, 0.0)
		return
	_drown_timer = 0.0
	if submerged:
		_waterproof_recover_timer = 0.0
		_waterproof_drain_timer += delta
		if _waterproof_drain_timer >= WCFG.water_drain_interval:
			_waterproof_drain_timer = 0.0
			_waterproof = maxi(_waterproof - 1, 0)
	else:
		_waterproof_drain_timer = 0.0
		_waterproof_recover_timer += delta
		if _waterproof_recover_timer >= WCFG.water_recover_interval:
			_waterproof_recover_timer = 0.0
			_waterproof = mini(_waterproof + 1, waterproof_max)
func _begin_death() -> void:
	if is_dead:
		return
	is_dead = true
	combat.enemy_kills += 1
	corpse_left = ECFG.shared_corpse_time
	_on_death()


func _on_death() -> void:
	pass


func _smash_player(impact: float, impact_up: float) -> void:
	var away := ToroidalGrid.toroidal_delta_px(position, player.position, terrain.map_size).normalized()
	if away == Vector2.ZERO:
		away = Vector2(-float(player.facing_direction), 0.0)
	player.velocity = away * impact
	player.velocity.y -= impact_up


# 转向后有短暂冷却，避免玩家在敌人身边移动时使敌人连续转向。
func _set_facing(left: bool) -> void:
	if _turn_cooldown > 0.0 or facing_left == left:
		return
	_turn_cooldown = ECFG.shared_turn_min_interval
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


func _toroidal_dist_to(pos: Vector2) -> float:
	return ToroidalGrid.toroidal_delta_px(position, pos, terrain.map_size).length()


func toroidal_dist_to_player() -> float:
	return toroidal_delta_to_player().length()

func toroidal_dir_to_player() -> Vector2:
	var delta := toroidal_delta_to_player()
	if delta.is_zero_approx():
		return Vector2.RIGHT
	return delta.normalized()

func toroidal_delta_to_player() -> Vector2:
	return ToroidalGrid.toroidal_delta_px(position, player.position, terrain.map_size)

# 地图两侧相连。越界后，敌人回到地图范围内的对应坐标。
func _wrap() -> void:
	position = ToroidalGrid.wrap_to_range(position, terrain.map_size)

func lunge_age() -> float:
	return 0.0

func capture_state() -> Array:
	var row := []
	for field: StringName in _rewind_fields:
		var value: Variant = get(field)
		row.append(value.duplicate() if value is Array else value)
	return row

func restore_state(row: Array) -> void:
	for i in _rewind_fields.size():
		var value: Variant = row[i]
		set(_rewind_fields[i], value.duplicate() if value is Array else value)
	motion_contacts.clear()
	collision_layer = CombatProfiles.Layer.ENEMY if active else 0
