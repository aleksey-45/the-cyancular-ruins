class_name EnemyJumpBird
extends EnemyBase

static var DASH_TIMEOUT := ECFG.jump_bird_lunge_max_dist / ECFG.jump_bird_lunge_speed + 0.2

var _hop_timer: float = 0.0
var _back_hop_cd: float = 0.0
var _lunge_dir: Vector2 = Vector2.RIGHT
var _lunge_traveled: float = 0.0
var _dash_timer: float = 0.0

func _setup() -> void:
	_rewind_fields.append_array([&"_hop_timer", &"_back_hop_cd", &"_lunge_dir", &"_lunge_traveled", &"_dash_timer"])
	wake_radius = ECFG.jump_bird_wake_radius

func _ai(delta: float) -> void:
	var dist := toroidal_dist_to_player()
	_back_hop_cd = maxf(_back_hop_cd - delta, 0.0)
	# 跳鸟苏醒后尝试面向玩家，实际转向还受冷却时间限制。
	var dir_to_player := toroidal_dir_to_player()
	if state != State.SLEEP and absf(dir_to_player.x) > 0.05:
		_set_facing(dir_to_player.x < 0.0)

	match state:
		State.SLEEP:
			_tick_sleep(delta, dist)
		State.WAKE:
			_tick_wake(delta)
		State.CHASE:
			_tick_chase(delta, dist)
		State.LUNGE_WINDUP:
			_tick_lunge_windup(delta)
		State.LUNGE_DASH:
			_tick_lunge_dash(delta)
		State.BACK_HOP:
			_tick_back_hop()



func _tick_sleep(delta: float, dist: float) -> void:
	_sleep_idle(delta)
	if dist <= ECFG.jump_bird_wake_radius:
		_set_state(State.WAKE)
		activity = Activity.WAKE
		_state_timer = ECFG.jump_bird_wake_time


func _tick_wake(delta: float) -> void:
	_state_timer -= delta
	if _state_timer <= 0.0:
		_set_state(State.CHASE)
		_hop_timer = 0.2


func _tick_chase(delta: float, dist: float) -> void:
	activity = Activity.HOP
	if dist > ECFG.jump_bird_give_up_radius:
		_set_state(State.SLEEP)
		_settle_sleep(ECFG.jump_bird_settle_time)
	elif dist <= ECFG.jump_bird_lunge_range:
		_set_state(State.LUNGE_WINDUP)
		_lunge_dir = toroidal_dir_to_player()
		_state_timer = ECFG.jump_bird_lunge_windup
	elif _grounded:
		# 起跳倒计时只在地面上减少，避免在空中发起下一次跳跃。
		_hop_timer -= delta
		if _hop_timer <= 0.0:
			_hop_timer = ECFG.jump_bird_hop_interval
			var dir := toroidal_dir_to_player()
			velocity = Vector2(dir.x * ECFG.jump_bird_hop_horizontal_speed,
					ECFG.jump_bird_hop_jump_velocity)


func _tick_lunge_windup(delta: float) -> void:
	_state_timer -= delta
	if _state_timer <= 0.0:
		_set_state(State.LUNGE_DASH)

		use_gravity = false
		_lunge_traveled = 0.0
		activity = Activity.LUNGE
		_dash_timer = DASH_TIMEOUT
		velocity = _lunge_dir * ECFG.jump_bird_lunge_speed


func _tick_lunge_dash(delta: float) -> void:
	_dash_timer -= delta
	_lunge_traveled += (velocity * delta).length()
	# 一次扑击同时受时间和行进距离限制。碰到侧墙也会提前结束，改为向后跳开。
	if _dash_timer <= 0.0 or _lunge_traveled >= ECFG.jump_bird_lunge_max_dist or _hit_wall():
		_set_state(State.BACK_HOP)

		use_gravity = true
		velocity = Vector2(-_lunge_dir.x * ECFG.jump_bird_back_hop_away,
				ECFG.jump_bird_back_hop_up)
		_back_hop_cd = 0.4


func _tick_back_hop() -> void:
	if _grounded and _back_hop_cd <= 0.0:
		_set_state(State.CHASE)
		_hop_timer = 0.15

func _on_death() -> void:
	activity = Activity.DEAD

func _water_swim_dir() -> Vector2:
	return toroidal_dir_to_player()


