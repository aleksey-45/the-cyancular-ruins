class_name EnemyJumpBird
extends EnemyBase

enum State { SLEEP, WAKE, CHASE, LUNGE_WINDUP, LUNGE_DASH, BACK_HOP }

var _hop_timer: float = 0.0
var _back_hop_cd: float = 0.0
var _lunge_dir: Vector2 = Vector2.RIGHT
var _lunge_traveled: float = 0.0
var _turn_timer: float = 0.0
var _dash_timer: float = 0.0
var _lunge_hit: bool = false
var _sleep_anim_timer: float = 0.0

func _ready() -> void:
	super._ready()
	_anim = $AnimatedSprite2D
	wake_radius = EnemyParams.JumpBird.wake_radius
	_set_state(State.SLEEP)
	_anim.play("sleeping")
	_align_contact_area()

func _align_contact_area() -> void:
	var area := get_node_or_null("ContactArea") as Area2D
	if area != null:
		for child in area.get_children():
			if child is CollisionShape2D:
				var area_shape := RectangleShape2D.new()
				area_shape.size = Vector2(44, 36)
				child.shape = area_shape
				child.position = Vector2(0, 4.5)
				break

func _ai(delta: float) -> void:
	var dist := toroidal_dist_to_player()
	_back_hop_cd = maxf(_back_hop_cd - delta, 0.0)
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
	if _sleep_anim_timer > 0.0:
		_sleep_anim_timer -= delta
		if _sleep_anim_timer <= 0.0:
			_anim.play("sleeping")
	else:
		_anim.play("sleeping")
	if dist <= EnemyParams.JumpBird.wake_radius:
		_set_state(State.WAKE)
		_anim.play("wake_up")
		_state_timer = _anim_duration("wake_up")


func _tick_wake(delta: float) -> void:
	_state_timer -= delta
	if _state_timer <= 0.0:
		_set_state(State.CHASE)
		_hop_timer = 0.2


func _tick_chase(delta: float, dist: float) -> void:
	_anim.play("jump")
	if dist > EnemyParams.JumpBird.give_up_radius:
		_set_state(State.SLEEP)
		_anim.play("fall_asleep")
		_sleep_anim_timer = _anim_duration("fall_asleep")
	elif dist <= EnemyParams.JumpBird.lunge_range:
		_set_state(State.LUNGE_WINDUP)
		_lunge_dir = toroidal_dir_to_player()
		_state_timer = EnemyParams.JumpBird.lunge_windup
	elif is_on_floor():
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
		use_gravity = false
		_lunge_traveled = 0.0
		_anim.play("turn_dash")
		_turn_timer = _anim_duration("turn_dash")
		_dash_timer = EnemyParams.JumpBird.lunge_max_dist / EnemyParams.JumpBird.lunge_speed + 0.2
		velocity = _lunge_dir * EnemyParams.JumpBird.lunge_speed


func _tick_lunge_dash(delta: float) -> void:
	if not _lunge_hit and (_player_overlapping or toroidal_dist_to_player() <= CONTACT_RADIUS):
		_lunge_hit = true
		var p := _contact_victim()
		if p != null and p.has_method("take_hit"):
			p.take_hit(global_position, impact_damage, true)
		_end_lunge()
		return
	if _turn_timer > 0.0:
		_turn_timer -= delta
		if _turn_timer <= 0.0:
			_anim.play("dashing")
	_dash_timer -= delta
	_lunge_traveled += (velocity * delta).length()
	if _dash_timer <= 0.0 or _lunge_traveled >= EnemyParams.JumpBird.lunge_max_dist or is_on_wall():
		_end_lunge()


func _end_lunge() -> void:
	_set_state(State.BACK_HOP)
	use_gravity = true
	velocity = Vector2(-_lunge_dir.x * EnemyParams.JumpBird.back_hop_away,
			EnemyParams.JumpBird.back_hop_up)
	_back_hop_cd = 0.4


func _tick_back_hop() -> void:
	if is_on_floor() and _back_hop_cd <= 0.0:
		_set_state(State.CHASE)
		_hop_timer = 0.15

func _on_death() -> void:
	_anim.play("dead")

func _water_swim_dir() -> Vector2:
	return toroidal_dir_to_player()


func _is_asleep() -> bool:
	return state == State.SLEEP


func _on_state_entered(s: int) -> void:
	match s:
		State.LUNGE_DASH:
			_lunge_hit = false
			squash.impulse(SquashStretch.Impulse.CHARGE)
		State.BACK_HOP:
			squash.impulse(SquashStretch.Impulse.CHARGE)
