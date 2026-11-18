class_name EnemyJumpBird
extends EnemyBase

const DASH_TIMEOUT := EnemyParams.JumpBird.lunge_max_dist / EnemyParams.JumpBird.lunge_speed + 0.2

var _hop_timer: float = 0.0
var _back_hop_cd: float = 0.0
var _lunge_dir: Vector2 = Vector2.RIGHT
var _lunge_traveled: float = 0.0
var _dash_timer: float = 0.0    # 冲刺总超时保险(防止永久卡在冲刺)

func _ready() -> void:
	super._ready()
	# 战斗参数来自场景。
	wake_radius = EnemyParams.JumpBird.wake_radius

func _ai(delta: float) -> void:
	var dist := toroidal_dist_to_player()
	_back_hop_cd = maxf(_back_hop_cd - delta, 0.0)
	# 面朝玩家:所有精灵帧朝右,玩家在左时翻转(经 _set_facing 锁转向频率)
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


# 按状态分派。

func _tick_sleep(delta: float, dist: float) -> void:
	_sleep_idle(delta)
	if dist <= EnemyParams.JumpBird.wake_radius:
		_set_state(State.WAKE)
		activity = Activity.WAKE
		_state_timer = EnemyParams.JumpBird.wake_time


func _tick_wake(delta: float) -> void:
	_state_timer -= delta
	if _state_timer <= 0.0:
		_set_state(State.CHASE)
		_hop_timer = 0.2


func _tick_chase(delta: float, dist: float) -> void:
	activity = Activity.HOP
	if dist > EnemyParams.JumpBird.give_up_radius:
		_set_state(State.SLEEP)
		_settle_sleep(EnemyParams.JumpBird.settle_time)
	elif dist <= EnemyParams.JumpBird.lunge_range:
		_set_state(State.LUNGE_WINDUP)
		_lunge_dir = toroidal_dir_to_player()
		_state_timer = EnemyParams.JumpBird.lunge_windup
	elif _grounded:
		# 鸟非冲刺状态下只能跳跃移动,不能滑行
		_hop_timer -= delta
		if _hop_timer <= 0.0:
			_hop_timer = EnemyParams.JumpBird.hop_interval
			var dir := toroidal_dir_to_player()
			velocity = Vector2(dir.x * EnemyParams.JumpBird.hop_horizontal_speed,
					EnemyParams.JumpBird.hop_jump_velocity)


func _tick_lunge_windup(delta: float) -> void:
	_state_timer -= delta
	if _state_timer <= 0.0:
		_set_state(State.LUNGE_DASH)
		motion.emit(&"charge", 0.0)
		use_gravity = false
		_lunge_traveled = 0.0
		activity = Activity.LUNGE
		_dash_timer = DASH_TIMEOUT
		velocity = _lunge_dir * EnemyParams.JumpBird.lunge_speed


func _tick_lunge_dash(delta: float) -> void:
	_dash_timer -= delta
	_lunge_traveled += (velocity * delta).length()
	# 冲刺总时长保险:速度被外力(爆炸击退等)改动或主移动异常时,防止永久卡在冲刺状态。
	if _dash_timer <= 0.0 or _lunge_traveled >= EnemyParams.JumpBird.lunge_max_dist or _hit_wall():
		_set_state(State.BACK_HOP)
		motion.emit(&"charge", 0.0)
		use_gravity = true
		velocity = Vector2(-_lunge_dir.x * EnemyParams.JumpBird.back_hop_away,
				EnemyParams.JumpBird.back_hop_up)
		_back_hop_cd = 0.4


func _tick_back_hop() -> void:
	if _grounded and _back_hop_cd <= 0.0:
		_set_state(State.CHASE)
		_hop_timer = 0.15

func _on_death() -> void:
	activity = Activity.DEAD

# 落水:朝玩家水平游(不朝岸边,保持追击感)。
func _water_swim_dir() -> Vector2:
	return toroidal_dir_to_player()


