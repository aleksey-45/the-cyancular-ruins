class_name PlayerMotor
extends RefCounted

# 移动 / 姿态 / 物理的**唯一帧内顺序源**。顺序即契约,顺序写在这里一处:
#   swim.update → 水下计时 → climb.update → 垂直 → 蹲/冲 → 水平 → 朝向 → 姿态+碰撞 → 迈台阶/自动跳
#   → 击退 → 记 _pre_move_vy → move_and_slide → 贴地 → 台沿抬升 → 滑面反应 → 环面回绕
# ★ 为什么必须集中:这些步骤的相对顺序不可拆 —— 迈台阶的位移要在 move_and_slide 之前用 test_move 判定、
#   _pre_move_vy 必须在 move_and_slide 之前取值(落地那帧之后就被清零)、squash 要在倒地早退之前 tick。
#   散在根里时"顺序"只活在阅读者的短期记忆里;在这里它是一份可 diff、可引用的清单。
# ★ 只拥有只被移动读写的字段(计时器/姿态锁/碰撞箱表/本帧倍率)。facing / state / is_squat / is_charge / charge_timer
#   仍归 Player:武器、快照、远端副本都读它们,搬过来会逼出一层转发属性,反而更难定位。
# ★ 依赖方向:Motor → Player(Component)单向。Player 只通过 tick / capture_extra / restore_extra 与本类交互。

const DashRule := preload("res://core/sim/dash_rule.gd")   # 冲刺倍率/准入判据唯一入口(两端同一份算式)

const AUTO_JUMP_CLEARANCE := 2.0
const AUTO_LEDGE_NUDGE_PX := 16.0
const STATE_LOCK_TIME := 0.15   # 秒,切换姿态后的最短停留时长

var body: Player = null

# ── 移动参数(来源 = core/config/player_config.tres,经 PlayerParams 读一次)──
var gravity: float = GameParameters.gravity0
var jump_velocity: float = PlayerParams.jump_velocity
var charge_down_velocity: float = PlayerParams.charge_down_velocity
var charge_velocity: float = PlayerParams.charge_velocity
var charge_duration: float = PlayerParams.charge_duration
var charge_air_gravity_mult: float = PlayerParams.charge_air_gravity_mult
var move_speed: float = PlayerParams.move_speed
var crouch_walk_speed: float = PlayerParams.crouch_walk_speed
var accel_ground: float = PlayerParams.accel_ground
var accel_air: float = PlayerParams.accel_air
var brake_ground: float = PlayerParams.brake_ground
var brake_air: float = PlayerParams.brake_air
var coyote_time: float = PlayerParams.coyote_time
var jump_buffer_time: float = PlayerParams.jump_buffer_time
var jump_cut_factor: float = PlayerParams.jump_cut_factor

# ── 本类拥有的跨帧状态(进整态)──
var coyote_timer: float = 0.0
var jump_buffer_timer: float = 0.0
var jump_cut_applied: bool = false
var state_lock_timer: float = 0.0
var _last_move_dir: int = 1
var _last_move_timer: float = 0.0

# ── 本类拥有的帧内量(不进整态)──
var _speed_mult := 1.0
var _pre_move_vy := 0.0
var _step_up_snap := false
var _coll_by_pose: Dictionary = {}


func setup(p: Player) -> void:
	body = p
	for pose in Player.Pose.values():
		_coll_by_pose[pose] = p.get_node(PlayerVisual.COLLISION_NODE[pose])


# ── 供根读取的只读量 ──
func speed_mult() -> float:
	return _speed_mult

func pre_move_vy() -> float:
	return _pre_move_vy

# squash 的契约 = 地面真正吸收掉的坠落速度:必须在 move_and_slide 之前取值,落地那一帧之后就被清零。
func pre_move_vy_for_squash() -> float:
	return _pre_move_vy


func set_speed_mult(tm: float) -> void:
	_speed_mult = tm


# ── 整态:本类拥有的 6 个字段(键名 = NetCodec 的 C2_SCHEMA)──
func capture_extra() -> Dictionary:
	return {
		"slock": state_lock_timer,
		"coyote": coyote_timer,
		"jbuf": jump_buffer_timer,
		"jcut": jump_cut_applied,
		"lmv_d": _last_move_dir,
		"lmv_t": _last_move_timer,
	}


func restore_extra(st: Dictionary) -> void:
	state_lock_timer = float(st.get("slock", state_lock_timer))
	coyote_timer = float(st.get("coyote", coyote_timer))
	jump_buffer_timer = float(st.get("jbuf", jump_buffer_timer))
	jump_cut_applied = bool(st.get("jcut", jump_cut_applied))
	_last_move_dir = int(st.get("lmv_d", _last_move_dir))
	_last_move_timer = float(st.get("lmv_t", _last_move_timer))


# 攀爬跳离梯顶:清跳跃缓冲/土狼/截断标记,防残留输入造成二次起跳(由 climb 组件调根转发)。
func cancel_jump_state() -> void:
	jump_buffer_timer = 0.0
	coyote_timer = 0.0
	jump_cut_applied = false


func reset_timers() -> void:
	cancel_jump_state()
	state_lock_timer = 0.0
	_last_move_timer = 0.0


# 整态恢复后的收尾:按当前姿态启用碰撞箱(不可序列化的场景状态,与 Player._after_state_restore 分工)。
func sync_pose_collision() -> void:
	for pose in _coll_by_pose:
		_coll_by_pose[pose].disabled = pose != body.state


# ── 一帧的全部移动/物理步骤:顺序即契约,别在这里重排 ──
func tick(delta: float, tm: float) -> void:
	_speed_mult = tm
	var mult := body.weapons.movement_multiplier()
	var input: PlayerInput = body.input_source
	var horizontal_input := input.get_axis("left", "right")

	# ① 水判定(本帧唯一来源)与呼吸;② 攀爬只在不游时跑
	var in_water := body.swim.update(body, delta, mult, input, tm)
	body.swim.update_waterproof(delta, body.swim.sample, body)
	var latched := false
	if not in_water:
		body.climb.update(mult, delta, body.is_squat, input)
		latched = body.climb.is_latched()
	else:
		body.is_charge = false
		body.is_squat = false

	_tick_vertical(delta, latched, in_water, mult, input)
	_tick_crouch_and_dash(delta, latched, in_water, mult, input)
	_tick_horizontal(delta, in_water, horizontal_input, mult)
	_tick_facing(delta, horizontal_input)
	_tick_pose_and_collision(delta, in_water)
	# ③ 迈台阶/自动跳必须在 move_and_slide 之前:先用 test_move 判"这一帧会不会被台阶挡住"
	if not latched and not in_water:
		_try_step_or_jump(delta, mult, horizontal_input, input)

	# ④ 爆炸击退单独走 move_and_collide(带碰撞),不污染 velocity
	body.combat.apply_knock(delta)

	# ⑤ 必须在 move_and_slide() 之前取值;水中/攀爬中置 0 是设计取舍(见 docs/systems/gameplay/player.md)
	_pre_move_vy = 0.0 if (in_water or latched) else body.velocity.y
	body.move_and_slide()
	if _step_up_snap:
		# 迈台阶后脚底只离台面 1px:吸一下地,避免"腾空一帧"的姿态/挤压抖动
		_step_up_snap = false
		body.apply_floor_snap()
	_try_ledge_nudge(in_water, latched, horizontal_input)

	_tick_slide_reactions()
	_wrap_position()


# 倒地路径:不读输入、不跑武器/攀爬/跳跃/冲刺/姿态切换,但重力/制动/击退照常。
# ★ 重力刻意不与正常路径合并(不乘 charge_air_gravity_mult、不递减土狼时间) —— 今天不可观测,但不可观测是要论证的。
func tick_downed(delta: float) -> void:
	if body.is_on_floor():
		coyote_timer = coyote_time
	else:
		body.velocity.y += gravity * delta
	_brake_horizontal(delta)
	body.combat.apply_knock(delta)
	body.move_and_slide()
	_wrap_position()


func _tick_vertical(delta: float, latched: bool, in_water: bool, mult: Vector2, input: PlayerInput) -> void:
	if latched or in_water:
		return
	if body.is_on_floor():
		coyote_timer = coyote_time
	else:
		# 空中冲刺那几帧重力 ×charge_air_gravity_mult(变平,可跨沟)。
		var grav_mult := charge_air_gravity_mult if body.is_charge else 1.0
		body.velocity.y += gravity * grav_mult * delta
		coyote_timer = maxf(coyote_timer - delta, 0.0)

	if input.is_action_just_pressed("up"):
		jump_buffer_timer = jump_buffer_time
	else:
		jump_buffer_timer = maxf(jump_buffer_timer - delta, 0.0)

	if jump_buffer_timer > 0.0 and (body.is_on_floor() or coyote_timer > 0.0) and not body.is_squat:
		# 冲刺中按跳 = 打断冲刺转跳跃,保留当前水平速度作动量。
		if body.is_charge:
			body.is_charge = false
			body.charge_timer = 0.0
		body.velocity.y = jump_velocity * mult.y
		jump_buffer_timer = 0.0
		coyote_timer = 0.0
		jump_cut_applied = false
		body.squash.impulse(SquashStretch.Impulse.JUMP)

	if not jump_cut_applied and input.is_action_just_released("up") and body.velocity.y < 0.0:
		body.velocity.y *= jump_cut_factor
		jump_cut_applied = true


func _try_step_or_jump(delta: float, mult: Vector2, horizontal_input: float, input: PlayerInput) -> void:
	if not body.is_on_floor() or body.is_squat or body.is_charge or jump_buffer_timer > 0.0:
		return
	var dx: float = body.velocity.x * delta
	if absf(dx) < 0.5:
		return
	var dir := 1 if dx > 0.0 else -1
	if not body.test_move(body.global_transform, Vector2(dx, 0.0)):
		return   # 这一帧本来就过得去
	var feet := _front_feet_subcell(dir)
	var h := StepJump.low_step_height(feet, dir, Callable(self, "_sub_solid_at"))
	if h <= 0 or not _step_up_headroom_clear(feet, dir, h):
		return
	var sub_px := float(GameParameters.TILE_SIZE) / float(StepJump.SUB_PER_CELL)
	# 抬起来之后本帧位移必须真的进得去(物理判据,不只信网格):否则那面"台阶"其实进不去,不抬。
	var lift := float(h) * sub_px + 1.0
	if body.test_move(body.global_transform.translated(Vector2(0.0, -lift)), Vector2(dx, 0.0)):
		return
	var full_x := horizontal_input * move_speed * _speed_mult * mult.x
	if StepJump.is_walk_up_step(h):
		# 矮台阶(≤32px):抬到台阶顶,同一帧的 move_and_slide 直接迈上去 —— 不丢那一帧。
		body.global_position.y -= lift
		body.velocity.y = 0.0
		body.velocity.x = full_x
		_step_up_snap = true
		return
	# 3~4 子格(48/64px):按台阶高度起跳(跳高 = 台阶高度,不是满力跳)。
	body.velocity.y = StepJump.jump_velocity_for_height(float(h) * sub_px + AUTO_JUMP_CLEARANCE, gravity)
	body.velocity.x = full_x
	jump_buffer_timer = 0.0
	coyote_timer = 0.0
	jump_cut_applied = true
	body.squash.impulse(SquashStretch.Impulse.JUMP)


# 自动跳跃的两个数据口:脚底前方落在哪个 16px 子格 / 该子格有没有碰撞。
# ★ 用 hurt_rect()(当前姿态的逻辑体)而不是碰撞箱:与"受击面"同一份几何,蹲下时不会用站立身高去探。
func _front_feet_subcell(dir: int) -> Vector2i:
	var r := body.hurt_rect()
	var sub := float(GameParameters.TILE_SIZE) / float(StepJump.SUB_PER_CELL)
	var x := r.position.x + r.size.x * 0.5 + float(dir) * (r.size.x * 0.5 + 1.0)
	var y := r.position.y + r.size.y - 2.0
	return Vector2i(int(floor(x / sub)), int(floor(y / sub)))


# 子格是否挡路:与 CollisionBuilder.build_sub 同一份判据(type=wall 才有碰撞;可破坏砖还要 sub_alive)。
# ★ 世界是环面的 ⇒ 子格坐标先环面回绕,否则接缝旁的台阶永远判成"没挡路"。
func _sub_solid_at(cell: Vector2i) -> bool:
	var sub := MazeGenerator.current_subgrid
	if sub.is_empty():
		return false
	var sr := sub.size()
	var sc := (sub[0] as Array).size()
	var wrapped := Vector2i(posmod(cell.x, sc), posmod(cell.y, sr))
	var tex := int((sub[wrapped.y] as Array)[wrapped.x])
	if tex == 0:
		return false
	if TileDefs.type_id_of(tex) != TileDefs.TYPE_WALL:
		return false
	var destr: bool = TileDefs.bullet_destroyable(tex) or TileDefs.explosion_destroyable(tex)
	if destr and TileDefs.sub_cols != 0 and not TileDefs.sub_alive(wrapped):
		return false
	return true


# 迈台阶前的净空检查:台阶顶面往上 4 个子格必须是空的。
# ★ 台阶实体子格 = 脚底那行往上连续 step_sub 行,顶面 = (feet_sub.y - step_sub + 1) 行的上沿 ⇒ 顶面上方第一行 = feet_sub.y - step_sub。
func _step_up_headroom_clear(feet_sub: Vector2i, dir: int, step_sub: int) -> bool:
	var top_row := feet_sub.y - step_sub
	for k in range(0, StepJump.SUB_PER_CELL):
		if _sub_solid_at(Vector2i(feet_sub.x + dir, top_row - k)):
			return false
	return true


# 卡脚修复:跳跃/下落贴着台沿时,脚底会以 ≤1 个子格的深度卡在台沿竖直面或顶面。
func _try_ledge_nudge(in_water: bool, latched: bool, horizontal_input: float) -> void:
	if in_water or latched or body.is_on_floor() or not body.is_on_wall() or absf(horizontal_input) < 0.01:
		return
	var sub := MazeGenerator.current_subgrid
	if sub.is_empty():
		return
	var dir := 1 if horizontal_input > 0.0 else -1
	var sub_px := float(GameParameters.TILE_SIZE) / float(StepJump.SUB_PER_CELL)
	var r := body.hurt_rect()
	var feet_y := r.position.y + r.size.y
	var x_px := r.position.x + r.size.x * 0.5 + float(dir) * (r.size.x * 0.5 + 1.0)
	var col := int(floor(x_px / sub_px))
	var feet_sub := int(floor(feet_y / sub_px))
	# 只看"脚所在子格"与"再上一格":台沿顶面必须在这 2 个子格内,否则是撞真墙,不抬。
	for k in range(0, 2):
		var row := feet_sub - k
		if not _sub_solid_at(Vector2i(col, row)):
			continue
		var dy := feet_y - float(row) * sub_px
		if dy <= 0.0 or dy > AUTO_LEDGE_NUDGE_PX:
			continue
		if _sub_solid_at(Vector2i(col, row - 1)) or _sub_solid_at(Vector2i(col, row - 2)):
			return
		body.global_position.y -= dy + 1.0
		body.velocity.y = minf(body.velocity.y, 0.0)
		return


func _tick_crouch_and_dash(delta: float, latched: bool, in_water: bool, mult: Vector2, input: PlayerInput) -> void:
	if latched or in_water:
		return
	# 下冲:空中按 S 给一次向下的速度脉冲;已经比他掉得还快时不给(= 不许用它刹车)。
	if not body.is_on_floor() and input.is_action_just_pressed("down") \
			and not body.climb.is_over_climb_tile() \
			and DashRule.down_dash_allowed(body.velocity.y, charge_down_velocity):
		body.velocity.y = charge_down_velocity
		if body.present != null:
			body.present.down_dash_started()
	# 下蹲逐帧推导,不用边沿:旧实现把 release 分支套在 is_on_floor() 内,空中松开 S 不执行 ⇒ 落地仍蹲(卡蹲)。
	var want_squat: bool = body.is_on_floor() and input.is_action_pressed("down")
	if want_squat and not body.is_squat:
		body.is_charge = false   # 冲刺中按 S → 取消冲刺进蹲
	body.is_squat = want_squat

	# 冲刺 = 双击左/右走(没有独立键,边沿由 LocalInputSource 合成);已比冲刺还快时不触发。
	if not body.is_charge and not body.is_squat and input.is_action_just_pressed("charge"):
		if DashRule.dash_allowed(body.velocity.x, DashRule.dash_speed(charge_velocity, _speed_mult, mult.x)):
			body.is_charge = true
			body.charge_timer = charge_duration
			body.squash.impulse(SquashStretch.Impulse.DASH)
			# 冲刺方向沿用最近移动方向;没在走路(如刚用枪瞄)则保留当前朝向。
			if _last_move_timer > 0.0:
				body.facing_direction = _last_move_dir


# 水平速度:攀爬中不锁横移(爬/挂/空闲都可左右走,由 climb 只管垂直)。
func _tick_horizontal(delta: float, in_water: bool, horizontal_input: float, mult: Vector2) -> void:
	if in_water:
		return
	if body.is_charge:
		# 速度 ×tm、计时 ÷tm(判据见 DashRule)⇒ 时间加速只让冲刺更快、不改距离;武器减速只缩短距离。
		body.velocity.x = DashRule.dash_speed(charge_velocity, _speed_mult, mult.x) * body.facing_direction
		body.charge_timer -= delta * _speed_mult
		if body.charge_timer <= 0:
			body.is_charge = false
	else:
		var speed_target := (crouch_walk_speed if body.is_squat else move_speed) * _speed_mult
		var target_velocity_x = horizontal_input * speed_target * mult.x
		if horizontal_input != 0:
			if body.is_on_floor():
				body.velocity.x = MathUtil.approach(body.velocity.x, target_velocity_x, accel_ground, delta)
			else:
				body.velocity.x = MathUtil.approach(body.velocity.x, target_velocity_x, accel_air, delta)
		else:
			_brake_horizontal(delta)


# 移动输入非零时朝向跟随移动;零输入时保留(枪瞄准设置的)当前朝向。
func _tick_facing(delta: float, horizontal_input: float) -> void:
	if not body.is_charge and horizontal_input != 0:
		body.facing_direction = 1 if horizontal_input > 0 else -1
		_last_move_dir = body.facing_direction
		_last_move_timer = PlayerParams.charge_dir_window
	else:
		_last_move_timer = maxf(_last_move_timer - delta, 0.0)


# 期望姿态由输入/接触状态决定;每个姿态对应一个 CollisionPolygon2D,运行时只启用当前姿态那个。
func _tick_pose_and_collision(delta: float, in_water: bool) -> void:
	body.animator.flip_h = body.facing_direction < 0
	if body.present != null:
		body.present.sync_form_flip()

	var desired: int = Player.Pose.STAND
	if in_water:
		desired = Player.Pose.MOVE if absf(body.velocity.x) > 1.0 else Player.Pose.STAND
	elif body.is_charge:
		desired = Player.Pose.CHARGE
	elif body.is_squat:
		desired = Player.Pose.SQUAT
	elif not body.is_on_floor():
		desired = Player.Pose.FLY
	elif body.velocity.x != 0:
		desired = Player.Pose.MOVE

	if state_lock_timer > 0.0:
		state_lock_timer -= delta
	elif body.state != desired:
		body.state = desired
		state_lock_timer = STATE_LOCK_TIME

	body.animator.play(PlayerVisual.ANIM[body.state])

	for pose in _coll_by_pose:
		_coll_by_pose[pose].disabled = pose != body.state


func _tick_slide_reactions() -> void:
	if body.is_charge:
		for i in range(body.get_slide_collision_count()):
			var col := body.get_slide_collision(i)
			if col != null and absf(col.get_normal().x) > 0.5:
				body.is_charge = false
				body.charge_timer = 0.0
				body.velocity.x = 0.0
				break

	# 弹性瓦片(如树叶)弱反弹;空网格跳过(冒烟测试会清空 current_grid;真实游戏 Level0 总会赋值)。
	if not MazeGenerator.current_grid.is_empty():
		for i in range(body.get_slide_collision_count()):
			var sc := body.get_slide_collision(i)
			if sc == null:
				continue
			var ec := MazeGenerator.cell_of(sc.get_position(), GameParameters.TILE_SIZE,
					MazeGenerator.current_grid[0].size(), MazeGenerator.current_grid.size())
			var ev: int = MazeGenerator.current_grid[ec.y][ec.x]
			if ev != 0 and TileDefs.elastic(MazeGenerator.texture_of(ev)):
				body.velocity += sc.get_normal() * PlayerParams.elastic_bounce
				break


# 无水平输入时的制动 + 吸附(倒地路径与正常路径逐句相同):指数缓动逼近不到 0,接近 0 时直接吸附。
func _brake_horizontal(delta: float) -> void:
	if body.is_on_floor():
		body.velocity.x = MathUtil.approach(body.velocity.x, 0.0, brake_ground, delta)
	else:
		body.velocity.x = MathUtil.approach(body.velocity.x, 0.0, brake_air, delta)
	if absf(body.velocity.x) < PlayerParams.stop_snap:
		body.velocity.x = 0.0


# 环面回卷:玩家只能在中间副本,离开时取模送回。
func _wrap_position() -> void:
	body.global_position = MazeGenerator.wrap_to_range(body.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
