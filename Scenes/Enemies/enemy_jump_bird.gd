class_name EnemyJumpBird
extends EnemyBase

enum State { SLEEP, WAKE, CHASE, LUNGE_WINDUP, LUNGE_DASH, BACK_HOP }

var state: State = State.SLEEP
var _anim: AnimatedSprite2D
var _state_timer: float = 0.0
var _hop_timer: float = 0.0
var _back_hop_cd: float = 0.0
var _lunge_dir: Vector2 = Vector2.RIGHT
var _lunge_traveled: float = 0.0
var _turn_timer: float = 0.0    # 冲刺启动动画剩余时间(播完切 dashing 常态)
var _dash_timer: float = 0.0    # 冲刺总超时保险(防止永久卡在冲刺)
var _death_timer: float = -1.0  # 死亡动画剩余时间;<0 表示未死亡
var _sleep_anim_timer: float = 0.0  # 入睡动画剩余时间(播完定格 sleeping)

func _ready() -> void:
	super._ready()
	knockback_strength = EnemyParams.JumpBird.knockback
	hp = EnemyParams.JumpBird.hp
	contact_damage = EnemyParams.shared.contact_damage
	_anim = $AnimatedSprite2D
	_set_state(State.SLEEP)
	_anim.play("sleeping")  # 睡觉是常态;入睡动画在靠近时触发
	_align_contact_area()

# 接触伤害范围与精灵身体对齐:鸟内容占格子 46x39,中心在格子中心下方 4.5px。
# ContactArea 由 EnemyBase 代码创建(不在场景里),这里把形状节点下移对齐。
# 身体碰撞箱由场景的 CollisionPolygon2D 配置,代码不碰。
func _align_contact_area() -> void:
	var area := get_node_or_null("ContactArea") as Area2D
	if area != null:
		for child in area.get_children():
			if child is CollisionShape2D:
				var area_shape := RectangleShape2D.new()
				area_shape.size = Vector2(44, 36)  # 世界 110x90,略大于身体轮廓保证接触判定
				child.shape = area_shape
				child.position = Vector2(0, 4.5)
				break

func _anim_duration(name: String) -> float:
	var spf := _anim.sprite_frames
	return float(spf.get_frame_count(name)) / spf.get_animation_speed(name)

func _set_state(s: State) -> void:
	state = s
	_state_timer = 0.0

func _ai(delta: float) -> void:
	var dist := toroidal_dist_to_player()
	_back_hop_cd = maxf(_back_hop_cd - delta, 0.0)
	# 面朝玩家:所有精灵帧朝右,玩家在左时翻转
	var dir_to_player := toroidal_dir_to_player()
	if state != State.SLEEP and absf(dir_to_player.x) > 0.05:
		_anim.flip_h = dir_to_player.x < 0.0

	match state:
		State.SLEEP:
			# 入睡动画(一次性)优先:播完定格 sleeping
			if _sleep_anim_timer > 0.0:
				_sleep_anim_timer -= delta
				if _sleep_anim_timer <= 0.0:
					_anim.play("sleeping")
			else:
				_anim.play("sleeping")
			if dist <= EnemyParams.JumpBird.wake_radius:
				_set_state(State.WAKE)
				_anim.play("wake_up")  # 醒来(一次性)
				_state_timer = _anim_duration("wake_up")
		State.WAKE:
			_state_timer -= delta
			if _state_timer <= 0.0:
				_set_state(State.CHASE)
				_hop_timer = 0.2
		State.CHASE:
			_anim.play("jump")
			if dist > EnemyParams.JumpBird.give_up_radius:
				_set_state(State.SLEEP)
				_anim.play("fall_asleep")  # 放弃追逐→入睡(一次性)
				_sleep_anim_timer = _anim_duration("fall_asleep")
			elif dist <= EnemyParams.JumpBird.lunge_range:
				_set_state(State.LUNGE_WINDUP)
				_lunge_dir = toroidal_dir_to_player()
				_state_timer = EnemyParams.JumpBird.lunge_windup
			elif is_on_floor():
				# 鸟非冲刺状态下只能跳跃移动,不能滑行
				_hop_timer -= delta
				if _hop_timer <= 0.0:
					_hop_timer = EnemyParams.JumpBird.hop_interval
					var dir := toroidal_dir_to_player()
					velocity = Vector2(dir.x * EnemyParams.JumpBird.hop_horizontal_speed,
							EnemyParams.JumpBird.hop_jump_velocity)
		State.LUNGE_WINDUP:
			_state_timer -= delta
			if _state_timer <= 0.0:
				_set_state(State.LUNGE_DASH)
				use_gravity = false
				_lunge_traveled = 0.0
				# 冲刺启动动作(一次性),播完切 dashing 常态
				_anim.play("turn_dash")
				_turn_timer = _anim_duration("turn_dash")
				_dash_timer = EnemyParams.JumpBird.lunge_max_dist / EnemyParams.JumpBird.lunge_speed + 0.2
				velocity = _lunge_dir * EnemyParams.JumpBird.lunge_speed
		State.LUNGE_DASH:
			# 启动动画倒计时;播完切 dashing 常态
			if _turn_timer > 0.0:
				_turn_timer -= delta
				if _turn_timer <= 0.0:
					_anim.play("dashing")
			_dash_timer -= delta
			_lunge_traveled += (velocity * delta).length()
			# 冲刺超时保险:即使方向异常(0/NaN)也不至于永久卡在冲刺
			if _dash_timer <= 0.0 or _lunge_traveled >= EnemyParams.JumpBird.lunge_max_dist or is_on_wall():
				_set_state(State.BACK_HOP)
				use_gravity = true
				velocity = Vector2(-_lunge_dir.x * EnemyParams.JumpBird.back_hop_away,
						EnemyParams.JumpBird.back_hop_up)
				_back_hop_cd = 0.4
		State.BACK_HOP:
			if is_on_floor() and _back_hop_cd <= 0.0:
				_set_state(State.CHASE)
				_hop_timer = 0.15

func hurt(damage: int, knock_dir: Vector2, knock_strength: float = 0.0) -> void:
	if is_dead:
		return
	_apply_hit(damage, knock_dir, knock_strength)
	if hp <= 0:
		is_dead = true
		_anim.play("dead")  # 死亡动画(一次性),播完消失
		_death_timer = _anim_duration("dead")
		collision_layer = 0  # 死亡后不再阻挡/被子弹命中
		collision_mask = 0
		use_gravity = false
		velocity = Vector2.ZERO

func _physics_process(delta: float) -> void:
	if is_dead:
		if _death_timer > 0.0:
			_death_timer -= delta
			if _death_timer <= 0.0:
				queue_free()
		return
	super._physics_process(delta)
