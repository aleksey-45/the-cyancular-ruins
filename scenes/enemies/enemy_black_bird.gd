class_name EnemyBlackBird
extends EnemyBase

const TCFG: TimeConfig = preload("res://core/config/time_config.tres")

# 乌鸫在巡逻期间寻找玩家另一侧的传送位置，传送过去后冲刺，再后跳回到巡逻状态。

var _wander_timer: float = 0.0
var _wander_dir: float = 1.0
var _wander_idle_timer: float = 0.0
var _flank_check_timer: float = 0.0
var _flank_cell: Vector2i = Vector2i(-1, -1)  # (-1, -1) 表示尚未找到可用于传送的落点。
var _landing_timer: float = 0.0
var _prep_timer: float = 0.0
var _wait_land: bool = false
var _left_ground: bool = false       # 起跳与上一次落地状态的更新可能处在同一帧。用这个标记跳过起跳前留下的状态。
var _teleport_cooldown: float = 0.0
var _charge_timer: float = 0.0
var _back_hop_cd: float = 0.0
var _body_bounds: Rect2
var _teleport_left := 0.0
var _hover_left := 0.0


func _setup() -> void:
	_rewind_fields.append_array([&"_wander_timer", &"_wander_dir", &"_wander_idle_timer",
			&"_flank_check_timer", &"_flank_cell", &"_landing_timer", &"_prep_timer", &"_wait_land",
			&"_left_ground", &"_teleport_cooldown", &"_charge_timer", &"_back_hop_cd",
			&"_teleport_left", &"_hover_left"])
	wake_radius = ECFG.black_bird_wake_radius
	_body_bounds = Transform2D.IDENTITY.scaled(scale) * hull.get_rect()

func _ai(delta: float) -> void:
	_teleport_left = maxf(_teleport_left - delta, 0.0)
	var dist := toroidal_dist_to_player()
	_back_hop_cd = maxf(_back_hop_cd - delta, 0.0)
	if state != State.SLEEP:
		_update_facing()
	match state:
		State.SLEEP:
			if _wake_ready(delta, dist, ECFG.black_bird_wake_time):
				_set_state(State.WAKE)
		State.WAKE:
			_set_state(State.WANDER)
			_wander_timer = 0.2
			_wander_idle_timer = 0.0
			_flank_check_timer = 0.5
		State.WANDER:
			_tick_wander(delta, dist)
		State.TAKE_OFF:
			_tick_take_off(delta)
		State.CHARGE:
			_tick_charge(delta)
		State.BACK_HOP:
			_tick_back_hop()



func _tick_wander(delta: float, dist: float) -> void:
	if dist > ECFG.black_bird_sleep_radius:
		_set_state(State.SLEEP)
		_settle_sleep(ECFG.black_bird_settle_time)
		velocity.x = 0.0
		return
	# 巡逻由随机长度的行走和停顿组成。每次重新计时也可以改变行走方向。
	if _wander_idle_timer > 0.0:
		_wander_idle_timer -= delta
		velocity.x = 0.0
		activity = Activity.WAIT
	else:
		activity = Activity.RUN
		_wander_timer -= delta
		if _wander_timer <= 0.0:
			_wander_timer = combat.rng.randf_range(ECFG.black_bird_wander_min_t, ECFG.black_bird_wander_max_t)
			_wander_dir = 1.0 if combat.rng.randf() < 0.5 else -1.0
			_wander_idle_timer = combat.rng.randf_range(0.0, ECFG.black_bird_wander_idle_max)
		if _wander_idle_timer > 0.0:
			velocity.x = 0.0
			activity = Activity.WAIT
		else:
			velocity.x = _wander_dir * ECFG.black_bird_wander_speed
			# 碰到侧墙时给出向上的速度，尝试跳过障碍。
			if _hit_wall():
				velocity.y = ECFG.black_bird_wander_jump_velocity
	_teleport_cooldown = maxf(_teleport_cooldown - delta, 0.0)
	_flank_check_timer -= delta
	if _flank_check_timer <= 0.0 and _teleport_cooldown <= 0.0:
		_flank_check_timer = ECFG.black_bird_flank_check_interval
		if _find_flank_cell():
			velocity = Vector2(0.0, ECFG.black_bird_take_off_jump_velocity)
			_wait_land = true
			_left_ground = false
			_prep_timer = 0.0
			_set_state(State.TAKE_OFF)

			activity = Activity.TAKE_OFF


# 传送前有两段准备动作。乌鸫先跳起，落地后再短暂停留。
func _tick_take_off(delta: float) -> void:
	if _wait_land:
		# 刚起跳时仍可能看到上一帧的着地状态，此时还不能开始传送准备。
		if _grounded:
			if _left_ground:
				_wait_land = false
				_prep_timer = ECFG.black_bird_teleport_prep_time
			else:
				_left_ground = true
	elif _prep_timer > 0.0:
		_prep_timer -= delta
		velocity.x = 0.0
		activity = Activity.PREPARE_TELEPORT
	else:
		_teleport_to_flank()
		_set_state(State.CHARGE)

		_charge_timer = ECFG.black_bird_charge_timeout
		_landing_timer = ECFG.black_bird_landing_timeout
		_wait_land = true
		_left_ground = true  # 传送位置已经在空中，直接等待下一次落地。
		_hover_left = ECFG.black_bird_teleport_hover_time


func _tick_charge(delta: float) -> void:
	if _hover_left > 0.0:
		_hover_left -= delta
		velocity = Vector2.ZERO  # 短暂停留期间抵消本帧加上的重力。
		if _teleport_left <= 0.0:
			activity = Activity.RECOVER
		return
	activity = Activity.RUN
	if _wait_land:
		if _grounded:
			if _left_ground:
				_wait_land = false
				_prep_timer = ECFG.black_bird_charge_prep_time
			else:
				_left_ground = true
		_landing_timer -= delta
		if _landing_timer <= 0.0:
			_wait_land = false
			_prep_timer = ECFG.black_bird_charge_prep_time  # 一直找不到地面时，也会在等待超时后开始准备冲刺。
		velocity.x = 0.0
		return
	elif _prep_timer > 0.0:
		_prep_timer -= delta
		velocity.x = 0.0
		return
	if touches_player():
		if combat.resolve_hit(self, player, CombatProfiles.SMASH,
				position, ECFG.black_bird_charge_damage, -1.0):
			_smash_player(ECFG.black_bird_charge_impact, ECFG.black_bird_charge_impact_up)
		_start_back_hop()
		return
	_charge_timer -= delta
	if _charge_timer <= 0.0:
		_start_back_hop()
		return
	var dir := toroidal_dir_to_player()
	velocity.x = dir.x * ECFG.black_bird_charge_speed
	if _hit_wall():
		velocity.x = 0.0
		velocity.y = ECFG.black_bird_charge_jump_velocity


func _tick_back_hop() -> void:
	if _grounded and _back_hop_cd <= 0.0:
		_set_state(State.WANDER)
		_wander_timer = 0.2
		_wander_idle_timer = 0.0
		_flank_check_timer = ECFG.black_bird_flank_check_interval


# 默认在玩家的另一侧寻找距玩家所在子格中心 128 至 384 像素的落点，落点与玩家之间须有无遮挡的视线。
func _find_flank_cell() -> bool:
	var player_cell := terrain.cell(player.position)
	var player_px := terrain.cell_center(player_cell)
	var bird_px := terrain.cell_center(terrain.cell(position))
	# 对比水平和垂直距离，选择相距较远的轴来判定玩家的另一侧。
	var off := ToroidalGrid.toroidal_delta_px(player_px, bird_px, terrain.map_size)
	var sx := signf(off.x)
	var sy := signf(off.y)
	var use_x := absf(off.x) >= absf(off.y)
	if absf(off.x) < 1.0 and absf(off.y) < 1.0:
		# 乌鸫和玩家位于同一子格时，改为在玩家面朝的方向寻找落点。
		sx = -player.facing_direction
		sy = 0.0
		use_x = true
	var min_d := ECFG.black_bird_teleport_min_range
	var max_d := ECFG.black_bird_teleport_max_range
	var max_r := ceili(max_d / Terrain.SUB_SIZE)
	var valid: Array[Vector2i] = []
	for dy in range(-max_r, max_r + 1):
		for dx in range(-max_r, max_r + 1):
			var c := Vector2i(posmod(player_cell.x + dx, terrain.columns), posmod(player_cell.y + dy, terrain.rows))
			var c_px := terrain.cell_center(c)
			var rel := ToroidalGrid.toroidal_delta_px(player_px, c_px, terrain.map_size)
			var dlen := rel.length()
			if dlen < min_d or dlen > max_d:
				continue
			if use_x and signf(rel.x) != -sx:
				continue
			if not use_x and signf(rel.y) != -sy:
				continue
			if terrain.material_at(c) != 0 or not TileDefs.is_blocked(terrain.material_at(c + Vector2i.DOWN)):
				continue
			# 除了地面附近的落脚空间，还需要检查落点上方实际传送到的位置。
			var drop_pos := c_px + Vector2.UP * ECFG.black_bird_teleport_drop
			if not _body_clear_at(drop_pos):
				continue
			if not terrain.line_of_sight(c_px, player_px):
				continue
			valid.append(c)
	if valid.is_empty():
		return false
	_flank_cell = valid[combat.rng.randi_range(0, valid.size() - 1)]
	return true


# 把乌鸫的包围盒放到候选位置，检测是否与地形重叠。
func _body_clear_at(pos: Vector2) -> bool:
	var shape := CollisionWorld.rectangle(_body_bounds.size)
	return terrain.physics.shape_overlaps(shape, Transform2D(0.0, pos + _body_bounds.get_center()), CombatProfiles.Layer.TERRAIN).is_empty()

func _teleport_to_flank() -> void:
	position = terrain.cell_center(_flank_cell) + Vector2.UP * ECFG.black_bird_teleport_drop
	velocity = Vector2.ZERO
	_teleport_left = ECFG.black_bird_teleport_entry_time
	activity = Activity.TELEPORT
	_flank_cell = Vector2i(-1, -1)
	_wrap()
	facing_left = toroidal_dir_to_player().x < 0.0


func _update_facing() -> void:
	if state == State.BACK_HOP:
		return
	if absf(velocity.x) > 5.0:
		_set_facing(velocity.x < 0.0)


func _start_back_hop() -> void:
	_set_state(State.BACK_HOP)
	activity = Activity.BACK_HOP
	var away := toroidal_dir_to_player()
	velocity = Vector2(-away.x * ECFG.black_bird_back_hop_away, ECFG.black_bird_back_hop_up)
	_back_hop_cd = 0.35
	_teleport_cooldown = ECFG.black_bird_teleport_cooldown


func _water_swim_dir() -> Vector2:
	return toroidal_dir_to_player()


func _on_death() -> void:
	if combat.time_field != null:
		combat.time_field.schedule_grain(TCFG.ELITE_GRAIN_DROP)
