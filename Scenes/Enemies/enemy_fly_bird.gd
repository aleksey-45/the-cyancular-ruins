class_name EnemyFlyBird
extends EnemyFlyBase

enum State { SLEEP, TAKE_OFF, FLY, SHOOT, CHARGE, RETURN }
enum Intent { SHOOT, CHARGE }

const ENEMY_BULLET_SCENE: PackedScene = preload("res://Scenes/Enemies/enemy_bullet.tscn")
# 死亡滑行水平阻力:每帧乘此系数。尸体保留击退初速但快速衰减停住,
# 不会以 max_death_fly_speed(900)匀速滑满 0.5s(≈450px)。60fps 下 0.5s 剩 ~2%。
const DEATH_HORIZONTAL_DRAG: float = 0.88

var intent: Intent = Intent.SHOOT

var _spawn_pos: Vector2 = Vector2.ZERO
var _home_cell: Vector2i = Vector2i.ZERO
var _max_hp: int = 20
var _wake_timer: float = -1.0        # wake_up 动画剩余;>=0 表示在播
var _sleep_anim_timer: float = -1.0  # fall_asleep 动画剩余
var _shoot_timer: float = 0.0
var _hover_anchor: Vector2 = Vector2.ZERO
var _hover_side: float = 1.0
var _strafe_target: Vector2 = Vector2.INF  # 开火后短距随机移动目标;INF=未在移动
var _strafe_timer: float = 0.0             # 短距移动剩余时长
var _landing: bool = false           # RETURN 落地阶段
var _spawn_captured: bool = false   # 出生点是否已抓取(等 spawner 设好位置再取,否则是 (0,0))
var _death_timer: float = -1.0      # 死亡白闪剩余;<0 表示未死亡


func _ready() -> void:
	super._ready()
	_anim = $AnimatedSprite2D
	# 出生点不在此抓取:spawner 是 add_child 之后才设位置,_ready 里抓到的是 (0,0),
	# 会害 _player_home_dist()/返程全错(鸟一醒就返程、不追玩家)。改在首帧物理补抓。
	_max_hp = hp
	_repath_phase = randf() * EnemyParams.FlyBird.repath_interval
	_set_state(State.SLEEP)
	_anim.play("sleeping")
	_apply_flight_collision(false)


func _physics_process(delta: float) -> void:
	# 首帧补抓出生点:spawner 在 _ready 之后才设 global_position。
	if not _spawn_captured:
		_spawn_pos = global_position
		_home_cell = _cell_of(global_position)
		_spawn_captured = true
	if is_dead:  # 死亡:保留击退速度飞出 + 白闪,闪完销毁
		_death_update(delta)
		return
	super._physics_process(delta)
	# 冲撞撞到东西(super 已执行 move_and_slide)
	if state == State.CHARGE and get_slide_collision_count() > 0:
		_on_charge_impact()


func _ai(delta: float) -> void:
	var dist := toroidal_dist_to_player()
	if state != State.SLEEP:
		_update_facing()
	match state:
		State.SLEEP:
			if _wake_timer > 0.0:
				_wake_timer -= delta
				if _wake_timer <= 0.0:
					_set_state(State.TAKE_OFF)
					_anim.play("take_off")
					_apply_flight_collision(true)
					_takeoff_velocity()
			elif _sleep_anim_timer > 0.0:
				_sleep_anim_timer -= delta
				if _sleep_anim_timer <= 0.0:
					_anim.play("sleeping")
			else:
				_anim.play("sleeping")
				if dist <= EnemyParams.FlyBird.wake_radius:
					_anim.play("wake_up")
					_wake_timer = _anim_duration("wake_up")
		State.TAKE_OFF:
			_state_timer += delta
			if _state_timer >= EnemyParams.FlyBird.take_off_time:
				_set_state(State.FLY)
				use_gravity = false
				_anim.play("flying")
				_schedule_repath()
		State.FLY:
			_anim.play("flying")
			if _player_home_dist() > EnemyParams.FlyBird.home_range:
				_start_return()
				return
			if dist > EnemyParams.FlyBird.max_chase_distance:
				_start_return()
				return
			_update_charge_intent_if_needed()
			if intent == Intent.CHARGE:
				if _try_charge():
					return
			elif dist <= EnemyParams.FlyBird.shoot_range and _shot_clear() and _near_shoot_pos():
				_start_shoot()
				return
			_repath_timer -= delta
			if _repath_timer <= 0.0:
				_repath_timer = EnemyParams.FlyBird.repath_interval + _repath_phase
				# 目标是斜上射击位(玩家上方),让下方的鸟绕道爬升到能打的位置。
				_repath_to(_shoot_cell())
			# 空路径(BFS 无路/预算超限)时直线飞向射击位,不再原地返程发呆。
			# 三元惰性求值:只在路径为空时才现算 _shoot_pos()(内含 Bresenham LOS),
			# 路径还在时传 INF——否则每帧给每只追玩家的鸟白付 1~2 次全图视线扫描。
			_follow_path(delta, _shoot_pos() if _path.is_empty() else Vector2.INF)
		State.SHOOT:
			_anim.play("flying")
			if _player_home_dist() > EnemyParams.FlyBird.home_range:
				_start_return()
				return
			_update_charge_intent_if_needed()
			if intent == Intent.CHARGE:
				if _try_charge():
					return
				# LOS 被堵:不再原地抛弹,退回 FLY 拉距离找 LOS(对齐 spec §1.4)
				_set_state(State.FLY)
				_schedule_repath()
				return
			elif dist > EnemyParams.FlyBird.shoot_range + EnemyParams.FlyBird.shoot_reacquire_margin:
				_set_state(State.FLY)
				_schedule_repath()
				return
			_update_hover_anchor()
			_shoot_timer -= delta
			if _strafe_target != Vector2.INF:
				# 开火后的短距随机移动:滑向随机目标,到点或超时结束。
				_strafe_timer -= delta
				_glide_to(_strafe_target, delta)
				if _strafe_timer <= 0.0 or (_strafe_target - global_position).length() <= EnemyParams.FlyBird.fly_speed * delta:
					_strafe_target = Vector2.INF
			else:
				_hover_to_anchor(delta)
			if _shoot_timer <= 0.0:
				# 弹道被墙挡:不空射,退 FLY 继续接近玩家找射击位。
				if not _shot_clear():
					_set_state(State.FLY)
					_schedule_repath()
					return
				# 平抛只能下落:鸟在玩家下方时弹道够不到玩家,不空射,继续爬向斜上锚点。
				if global_position.y <= _player_pos().y:
					_fire_parabolic()
				_shoot_timer = EnemyParams.FlyBird.shoot_cooldown
				_start_strafe()
		State.CHARGE:
			_state_timer += delta
			# 接触区/贴脸距离命中玩家直接结算(弥补 slide 碰撞偶尔穿过的情形)。
			if _player_overlapping or toroidal_dist_to_player() <= CONTACT_RADIUS:
				_on_charge_hit_player()
			elif _state_timer >= EnemyParams.FlyBird.charge_timeout:
				_die_self()
		State.RETURN:
			_anim.play("flying")
			if _landing:
				# 落地阶段:开重力直接下坠,计时到点即入睡,不再等地板接触。
				# (FLOATING 模式下 is_on_floor 恒 false,靠碰撞法线判地面在个别
				#  出生位/接缝处永远等不到,鸟会卡在 RETURN 不睡)
				_state_timer += delta
				if _state_timer >= EnemyParams.FlyBird.landing_time:
					_anim.play("fall_asleep")
					_sleep_anim_timer = _anim_duration("fall_asleep")
					_set_state(State.SLEEP)
					_apply_flight_collision(false)
					_landing = false
			elif _home_reached():
				_start_landing()
			else:
				_repath_timer -= delta
				if _repath_timer <= 0.0:
					_repath_timer = EnemyParams.FlyBird.repath_interval + _repath_phase
					# 玩家太远时不启动任何搜索;空路径时直线飞回家(不再漂移)。
					if dist <= EnemyParams.FlyBird.max_chase_distance:
						_repath_to(_home_cell)
				_follow_path(delta, _spawn_pos)


func hurt(damage: int, knock_dir: Vector2, knock_strength: float = 0.0, set_velocity: bool = false) -> void:
	if is_dead:
		return
	_apply_hit(damage, knock_dir, knock_strength, set_velocity)
	if hp <= 0:
		_die_self()


# 死亡:白闪后销毁(冲撞自毁与受击死亡同走本方法)。
func _die_self() -> void:
	if is_dead:
		return
	is_dead = true
	_death_timer = EnemyParams.FlyBird.death_flash_time
	# 冲撞中死(含被打死/超时):清冲撞速度,尸体不再续冲。撞墙/撞玩家的死亡已由
	# move_and_slide 抵消速度,归零无副作用;普通受击仍保留击退滑出感。
	if state == State.CHARGE:
		velocity = Vector2.ZERO
	# 其余死亡保留击退速度 + 开重力,带白闪飞出后消失(不像 JumpBird 清速度定格)。
	use_gravity = true


# 死亡物理:保留击退/冲撞速度 + 重力坠落,白闪后销毁。
func _death_update(delta: float) -> void:
	_death_timer -= delta
	if _death_timer <= 0.0:
		queue_free()
		return
	velocity.y += GameParameters.gravity0 * delta
	# 水平阻力:尸体滑出初速后逐渐停住,不匀速飞出老远(见 DEATH_HORIZONTAL_DRAG)
	velocity.x *= DEATH_HORIZONTAL_DRAG
	move_and_slide()
	_wrap()
	# 白闪闪烁(受击白闪 3x 与半透明交替)
	modulate = Color(3.0, 3.0, 3.0, 1.0) if int(_death_timer * 20.0) % 2 == 0 else Color(1.0, 1.0, 1.0, 0.35)


# ── 射击 ──

# 斜上射击位(与 SHOOT 锚点同一逻辑):玩家侧向 + 上方,鸟不穿越玩家头顶。
# 世界坐标与格坐标共用同一侧,保证寻路目标可到、直线兜底同向。
# 侧向优先取 LOS 通的一侧:几何侧对玩家无视线(被墙挡,如玩家站高平台一侧有墙)时,
# 鸟会一直停在射击位进不了 SHOOT——换另一侧绕过去攻击。两侧都堵才退回几何侧。
func _shoot_side() -> float:
	var geo := _shoot_side_geo()
	var p := _player_pos()
	for side in [geo, -geo]:
		var pos := p + Vector2(side * EnemyParams.FlyBird.hover_offset_x,
				-EnemyParams.FlyBird.hover_offset_y)
		if _cell_is_solid(_cell_of(pos)):
			continue
		if MazeGenerator.has_line_of_sight(_cell_of(pos), _cell_of(p)):
			return side
	return geo


# 几何侧:鸟在玩家哪一侧,射击位就放哪一侧(避免穿越玩家头顶)。20px 死区防抖。
func _shoot_side_geo() -> float:
	var delta := toroidal_delta_to_player()
	return -1.0 if delta.x > 20.0 else 1.0


func _shoot_pos() -> Vector2:
	var p := _player_pos()
	var side := _shoot_side()
	var pos := p + Vector2(side * EnemyParams.FlyBird.hover_offset_x, -EnemyParams.FlyBird.hover_offset_y)
	if _cell_is_solid(_cell_of(pos)):
		pos = p + Vector2(-side * EnemyParams.FlyBird.hover_offset_x, -EnemyParams.FlyBird.hover_offset_y)
	return pos


func _shoot_cell() -> Vector2i:
	return _cell_of(_shoot_pos())


# 是否已在斜上射击位附近:SHOOT 只应在鸟接近锚点时进入,否则下方/远方的鸟会
# 直线硬插到锚点被墙卡住。未就位时留在 FLY,靠 BFS 绕到玩家上方再进 SHOOT。
func _near_shoot_pos() -> bool:
	return _toroidal_dist_to(_shoot_pos()) <= EnemyParams.FlyBird.shoot_position_radius


func _start_shoot() -> void:
	_set_state(State.SHOOT)
	_pick_hover_side()
	_update_hover_anchor()
	_shoot_timer = 0.2


func _pick_hover_side() -> void:
	# 与 FLY 目标同侧(复用 LOS 感知的 _shoot_side),SHOOT 悬停锚点才和寻路目标一致。
	_hover_side = _shoot_side()


func _update_hover_anchor() -> void:
	# 斜上锚点:玩家侧向 + 上向偏移,不在玩家正头顶。
	var p := _player_pos()
	_hover_anchor = p + Vector2(_hover_side * EnemyParams.FlyBird.hover_offset_x,
			-EnemyParams.FlyBird.hover_offset_y)
	if _cell_is_solid(_cell_of(_hover_anchor)):
		_hover_side = -_hover_side
		_hover_anchor = p + Vector2(_hover_side * EnemyParams.FlyBird.hover_offset_x,
				-EnemyParams.FlyBird.hover_offset_y)


func _hover_to_anchor(delta: float) -> void:
	_glide_to(_hover_anchor, delta)


# 以 fly_speed 向 point 直线滑翔(悬停归位 / 开火后短距随机移动共用)。
func _glide_to(point: Vector2, delta: float) -> void:
	var spd := EnemyParams.FlyBird.fly_speed
	var to_target := point - global_position
	if to_target.length() <= spd * delta:
		global_position = point
		velocity = Vector2.ZERO
		return
	velocity = to_target.normalized() * spd


# 开火后短距随机移动:在当前位置 ±strafe_range 内取一个随机点作为滑翔目标。
func _start_strafe() -> void:
	_strafe_target = global_position + Vector2(
			randf_range(-EnemyParams.FlyBird.strafe_range, EnemyParams.FlyBird.strafe_range),
			randf_range(-EnemyParams.FlyBird.strafe_range, EnemyParams.FlyBird.strafe_range))
	_strafe_timer = EnemyParams.FlyBird.strafe_duration


# 弹道无遮挡:鸟与玩家格子之间无墙(平抛子弹会被地形挡住)。
func _shot_clear() -> bool:
	return MazeGenerator.has_line_of_sight(_cell_of(global_position), _cell_of(_player_pos()))


func _fire_parabolic() -> void:
	# 平抛:水平初速 + 重力,落点按玩家坐标 + 玩家即时速度预测。
	var v0 := _bullet_v0()
	var b: EnemyBullet = ENEMY_BULLET_SCENE.instantiate()
	b.launch(Vector2(v0, 0.0), EnemyParams.FlyBird.bullet_range,
			EnemyParams.FlyBird.bullet_damage, EnemyParams.FlyBird.bullet_gravity,
			EnemyParams.FlyBird.bullet_size)
	b.global_position = global_position
	get_viewport().add_child(b)
	# 开火后座:沿发射反方向轻推鸟(v0 符号即发射方向)。
	velocity += Vector2(-signf(v0) * EnemyParams.FlyBird.shoot_recoil, 0.0)


# 平抛水平初速(含玩家即时速度预测):开火与朝向共用,符号即弹道水平方向。
# 落差 = 玩家.y − 鸟.y(玩家在鸟下方为正);玩家高于鸟时夹到下限,弹道偏近属预期。
func _bullet_v0() -> float:
	var drop := maxf(_player_pos().y - global_position.y, EnemyParams.FlyBird.bullet_min_drop)
	var t := sqrt(2.0 * drop / GameParameters.gravity0)
	var pred := _player_pos() + _player_velocity() * t
	var dx := pred.x - global_position.x
	if absf(dx) > GameParameters.MAP_WIDTH * 0.5:
		dx = -signf(dx) * (GameParameters.MAP_WIDTH - absf(dx))
	return clampf(absf(dx) / t, EnemyParams.FlyBird.bullet_min_speed,
			EnemyParams.FlyBird.bullet_max_speed) * signf(dx)


# ── 冲撞 ──

func _update_charge_intent_if_needed() -> void:
	# 血量跌穿 25% 单向切冲撞意图(HP 只减不增)。
	if intent == Intent.SHOOT and hp < _max_hp * EnemyParams.FlyBird.charge_hp_fraction:
		intent = Intent.CHARGE


func _try_charge() -> bool:
	if toroidal_dist_to_player() > EnemyParams.FlyBird.charge_range:
		return false
	if not MazeGenerator.has_line_of_sight(_cell_of(global_position), _cell_of(_player_pos())):
		return false
	_start_charge()
	return true


func _start_charge() -> void:
	_set_state(State.CHARGE)
	use_gravity = false  # 冲撞为水平直线,不吃重力
	var dir := toroidal_dir_to_player()
	velocity = dir * EnemyParams.FlyBird.charge_speed
	_anim.play("dashing")


func _on_charge_impact() -> void:
	if is_dead:  # 本帧若已由接触判定自毁,避免二次结算
		return
	for i in range(get_slide_collision_count()):
		var collider := get_slide_collision(i).get_collider()
		if collider != null and collider.is_in_group("player") and collider.has_method("take_hit"):
			# 冲撞穿透无敌帧,命中必掉血(自杀攻击的威慑)
			collider.take_hit(global_position, EnemyParams.FlyBird.charge_damage, true)
			_apply_charge_impact(collider)
			break
	_die_self()


# 冲撞接触命中玩家:接触区/距离判定触发,伤害 + 自毁。
func _on_charge_hit_player() -> void:
	if is_dead:
		return
	var p := get_tree().get_first_node_in_group("player")
	if p != null and p.has_method("take_hit"):
		# 冲撞穿透无敌帧,命中必掉血(自杀攻击的威慑)
		p.take_hit(global_position, EnemyParams.FlyBird.charge_damage, true)
		_apply_charge_impact(p)
	_die_self()


# 冲撞冲击力:沿远离鸟的方向猛推玩家(覆盖 take_hit 的普通击退,冲撞更狠)。
func _apply_charge_impact(p: Node) -> void:
	var p2 := p as Node2D
	if p2 == null:
		return
	var away := (p2.global_position - global_position).normalized()
	if away == Vector2.ZERO:
		away = Vector2.LEFT
		if p2.has_method("get_facing"):
			away.x = -float(p2.get_facing())
	p2.velocity = away * EnemyParams.FlyBird.charge_impact
	p2.velocity.y -= EnemyParams.FlyBird.charge_impact_up


# ── 返程与入睡 ──

func _start_return() -> void:
	_set_state(State.RETURN)
	_landing = false
	_anim.play("flying")
	# 玩家太远时不启动任何搜索,清空路径交给 RETURN 的直线兜底飞回家。
	if toroidal_dist_to_player() <= EnemyParams.FlyBird.max_chase_distance:
		_repath_to(_home_cell)
	else:
		_path = []


func _home_reached() -> bool:
	return _toroidal_dist_to(_spawn_pos) <= EnemyParams.FlyBird.arrival_radius


func _start_landing() -> void:
	_landing = true
	_path = []
	use_gravity = true
	velocity = Vector2.ZERO
	_state_timer = 0.0  # 落地计时从零起,到 landing_time 直接入睡
	_apply_flight_collision(false)  # 落地用站立碰撞箱


func _player_home_dist() -> float:
	return MazeGenerator.toroidal_delta_px(_player_pos(), _spawn_pos,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()


func _takeoff_velocity() -> void:
	var dir := toroidal_dir_to_player()
	var s := EnemyParams.FlyBird.take_off_speed
	velocity = Vector2(dir.x * s, -s * 0.75)
	use_gravity = true


func _update_facing() -> void:
	if state == State.SHOOT:
		# 射击时朝向弹道水平方向(含玩家速度预测,可能与正对玩家略有差异)。
		# v0 为 0(玩家近正上方)时不翻转,保持上一帧朝向防抖。
		var v0 := _bullet_v0()
		if v0 != 0.0:
			_anim.flip_h = v0 < 0.0
	else:
		var vx := velocity.x
		if absf(vx) > 5.0:
			_anim.flip_h = vx < 0.0
