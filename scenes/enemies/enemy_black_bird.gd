class_name EnemyBlackBird
extends EnemyBase

# 精英刺客敌人（乌鸫）：
# 行为状态循环：睡眠 -> 随机游走 -> 周期性寻找玩家侧后方 3~8 格通视落点 -> 起飞上挑 -> 落地播放隐去动画 -> 白闪传送 ->
# 空中显现 -> 落地冲锋造成伤害 -> 大幅度后跳 -> 恢复游走；玩家远离时重新进入休眠。
# 全程受重力影响的地面实体，不使用飞行寻路。

var _wander_timer: float = 0.0       # 当前游走剩余时间
var _wander_dir: float = 1.0         # 游走方向（±1）
var _wander_idle_timer: float = 0.0  # 游走停顿剩余时间（>0 表示原地待机）
var _flank_check_timer: float = 0.0  # 瞬移落点检测周期计时
var _flank_cell: Vector2i = Vector2i(-1, -1)  # 选定的传送目标网格
var _landing_timer: float = 0.0      # 传送后着地超时保护计时器
var _prep_timer: float = 0.0         # 起飞/传送着地后的准备停顿剩余时长
var _wait_land: bool = false         # 传送后是否仍处于空中（等待着地）
var _left_ground: bool = false       # 起飞跳跃是否已离地（排除起跳初始帧的地面状态）
var _teleport_cooldown: float = 0.0  # 冲锋结束后的瞬移冷却计时器
var _charge_timer: float = 0.0       # 冲锋超时计时器
var _back_hop_cd: float = 0.0        # 后跳落地后的冷却时间
var _body_min: Vector2 = Vector2.ZERO   # 碰撞盒 AABB 最小顶点（经 scale 变换后）
var _body_max: Vector2 = Vector2.ZERO   # 碰撞盒 AABB 最大顶点（经 scale 变换后）
var _body_shape: RectangleShape2D = null  # 落点净空查询复用的形状
var _teleport_left := 0.0
var _hover_left := 0.0


func _ready() -> void:
	# 精英实体标记：免疫时空回溯（不计入快照）、时间加速倍率与玩家同步、被击杀后掉落 300 单位时间颗粒
	set_meta("elite", true)
	super._ready()
	wake_radius = EnemyParams.BlackBird.wake_radius
	# 记录碰撞箱 AABB(按 scale 换算),供瞬移落点清空判定用
	var cp := get_node_or_null("CollisionPolygon2D") as CollisionPolygon2D
	if cp != null and cp.polygon.size() > 0:
		var mn := cp.polygon[0]
		var mx := cp.polygon[0]
		for p in cp.polygon:
			mn = mn.min(p)
			mx = mx.max(p)
		_body_min = mn * scale
		_body_max = mx * scale


func _ai(delta: float) -> void:
	var dist := toroidal_dist_to_player()
	_back_hop_cd = maxf(_back_hop_cd - delta, 0.0)
	if state != State.SLEEP:
		_update_facing()
	match state:
		State.SLEEP:
			if _wake_ready(delta, dist, EnemyParams.BlackBird.wake_time):
				_set_state(State.WAKE)
		State.WAKE:
			_set_state(State.WANDER)
			_wander_timer = 0.2
			_wander_idle_timer = 0.0
			_flank_check_timer = 0.5 # 醒来先游走一会。
		State.WANDER:
			_tick_wander(delta, dist)
		State.TAKE_OFF:
			_tick_take_off(delta)
		State.CHARGE:
			_tick_charge(delta)
		State.BACK_HOP:
			_tick_back_hop()


# 状态机帧逻辑更新，各状态逻辑分派至独立方法处理

func _tick_wander(delta: float, dist: float) -> void:
	if dist > EnemyParams.BlackBird.sleep_radius:
		_set_state(State.SLEEP)
		_settle_sleep(EnemyParams.BlackBird.settle_time)
		velocity.x = 0.0
		return
	# 行走一段后随机停顿 0~wander_idle_max(站着不动),减少频繁游荡感
	if _wander_idle_timer > 0.0:
		_wander_idle_timer -= delta
		velocity.x = 0.0
		activity = Activity.WAIT
	else:
		activity = Activity.RUN
		_wander_timer -= delta
		if _wander_timer <= 0.0:
			_wander_timer = randf_range(EnemyParams.BlackBird.wander_min_t, EnemyParams.BlackBird.wander_max_t)
			_wander_dir = 1.0 if randf() < 0.5 else -1.0
			_wander_idle_timer = randf_range(0.0, EnemyParams.BlackBird.wander_idle_max)
		if _wander_idle_timer > 0.0:
			# 刚决定停顿:本帧就停(切站立帧),不再移动
			velocity.x = 0.0
			activity = Activity.WAIT
		else:
			velocity.x = _wander_dir * EnemyParams.BlackBird.wander_speed
			# 游走撞墙不卡死:小跳翻越矮墙(与冲锋自动跳相同机制判定)
			if _hit_wall():
				velocity.y = EnemyParams.BlackBird.wander_jump_velocity
	_teleport_cooldown = maxf(_teleport_cooldown - delta, 0.0)
	_flank_check_timer -= delta
	if _flank_check_timer <= 0.0 and _teleport_cooldown <= 0.0:
		_flank_check_timer = EnemyParams.BlackBird.flank_check_interval
		if _find_flank_cell():
			velocity = Vector2(0.0, EnemyParams.BlackBird.take_off_jump_velocity)
			_wait_land = true
			_left_ground = false
			_prep_timer = 0.0
			_set_state(State.TAKE_OFF)
			motion.emit(&"take_off", 0.0)
			activity = Activity.TAKE_OFF


# 起跳落地后原地停顿，再传送。
func _tick_take_off(delta: float) -> void:
	if _wait_land:
		# 进状态那帧着地状态是旧的(上帧在地面),要求先离地再落地才算数
		if _grounded:
			if _left_ground:
				_wait_land = false
				_prep_timer = EnemyParams.BlackBird.teleport_prep_time
			else:
				_left_ground = true
	elif _prep_timer > 0.0:
		_prep_timer -= delta
		velocity.x = 0.0  # 停顿期间停止左右移动
		activity = Activity.PREPARE_TELEPORT
	else:
		if _flank_cell == Vector2i(-1, -1):
			# TAKE_OFF 只在 _find_flank_cell() 成功后进入；走到这里说明状态机被外部破坏，显式暴露并回到游走。
			push_error("BlackBird: TAKE_OFF 无传送落点(状态机不一致) pf=%d" % Engine.get_physics_frames())
			_set_state(State.WANDER)
			return
		_teleport_to_flank()
		_set_state(State.CHARGE)
		motion.emit(&"charge", 0.0)
		_charge_timer = EnemyParams.BlackBird.charge_timeout
		_landing_timer = EnemyParams.BlackBird.landing_timeout
		_wait_land = true
		_left_ground = true  # 传送后必在落点上方空中,之后任何落地都是真落地
		_hover_left = EnemyParams.BlackBird.teleport_hover_time


func _tick_charge(delta: float) -> void:
	if _hover_left > 0.0:
		_hover_left -= delta
		velocity = Vector2.ZERO  # 空中滞留,不受重力下落
		if _teleport_left <= 0.0:
			activity = Activity.RECOVER
		return
	activity = Activity.RUN
	if _wait_land:
		if _grounded:
			if _left_ground:
				_wait_land = false
				_prep_timer = EnemyParams.BlackBird.charge_prep_time
			else:
				_left_ground = true
		_landing_timer -= delta
		if _landing_timer <= 0.0:
			_wait_land = false
			_prep_timer = EnemyParams.BlackBird.charge_prep_time  # 保底处理:超时也进停顿
		velocity.x = 0.0
		return
	elif _prep_timer > 0.0:
		_prep_timer -= delta
		velocity.x = 0.0
		return
	var target := _charge_victim()
	if target != null:
		if combat_rules.resolve_hit(self, target, CombatProfiles.SMASH,
				global_position, EnemyParams.BlackBird.charge_damage, -1.0):
			_smash_player(target, EnemyParams.BlackBird.charge_impact, EnemyParams.BlackBird.charge_impact_up)
		_start_back_hop()
		return
	_charge_timer -= delta
	if _charge_timer <= 0.0:
		_start_back_hop()
		return
	var dir := toroidal_dir_to_player()
	velocity.x = dir.x * EnemyParams.BlackBird.charge_speed
	if _hit_wall():
		velocity.x = 0.0  # 越障跳纯上跳,不叠加水平分量
		velocity.y = EnemyParams.BlackBird.charge_jump_velocity


func _tick_back_hop() -> void:
	if _grounded and _back_hop_cd <= 0.0:
		_set_state(State.WANDER)
		_wander_timer = 0.2
		_wander_idle_timer = 0.0
		_flank_check_timer = EnemyParams.BlackBird.flank_check_interval


# 游走中瞬移判定:在「距玩家 3~8 格(随机)、且位于玩家相对鸟的另一侧」的环形带
# (环面取模)搜地板格(EMPTY 且正下方非 EMPTY),且该格到玩家格 LOS 通 → 可瞬移冲锋。
func _find_flank_cell() -> bool:
	var p := _nearest_player()
	if p == null or terrain.empty():
		return false
	var ts := GameParameters.TILE_SIZE
	var player_cell := terrain.cell(p.global_position)
	var player_px := terrain.cell_center(player_cell)
	var bird_px := terrain.cell_center(terrain.cell(global_position))
	# 目标侧 = 玩家相对鸟的另一侧:取「玩家→鸟」偏移的主轴,落点取该轴反号
	var off := GridPathfinder.toroidal_delta_px(player_px, bird_px, terrain.map_size)
	var sx := signf(off.x)  # 鸟在玩家 +x 侧 → 目标 −x 侧
	var sy := signf(off.y)
	var use_x := absf(off.x) >= absf(off.y)
	if absf(off.x) < 1.0 and absf(off.y) < 1.0:
		# 鸟几乎压在玩家上:无「另一侧」,退到玩家面朝反方向
		sx = -_player_facing()
		sy = 0.0
		use_x = true
	var min_d := EnemyParams.BlackBird.teleport_min_tiles * ts
	var max_d := EnemyParams.BlackBird.teleport_max_tiles * ts
	var max_r := EnemyParams.BlackBird.teleport_max_tiles
	var valid: Array[Vector2i] = []
	for dy in range(-max_r, max_r + 1):
		for dx in range(-max_r, max_r + 1):
			var c := Vector2i(posmod(player_cell.x + dx, terrain.columns), posmod(player_cell.y + dy, terrain.rows))
			# 距离与侧向都用环面最短向量,避免跨接缝失真
			var c_px := terrain.cell_center(c)
			var rel := GridPathfinder.toroidal_delta_px(player_px, c_px, terrain.map_size)
			var dlen := rel.length()
			if dlen < min_d or dlen > max_d:
				continue
			if use_x and signf(rel.x) != -sx:
				continue
			if not use_x and signf(rel.y) != -sy:
				continue
			if terrain.value(c) != MapFormat.EMPTY or not _cell_is_solid(c + Vector2i.DOWN):
				continue
			# 瞬移落点上方必须有空间:碰撞箱在「下落起点」处不压到任何实心格,
			# 否则会穿进天花板/檐下/矮洞(落点格是地板但头顶有墙)。
			var drop_pos := c_px + Vector2.UP * EnemyParams.BlackBird.teleport_drop
			if not _body_clear_at(drop_pos):
				continue
			if not terrain.line_of_sight(c_px, player_px):
				continue
			valid.append(c)
	if valid.is_empty():
		return false
	_flank_cell = valid[randi() % valid.size()]  # 距离与方位在环带内随机
	return true


# 落点净空由引擎形状重叠判定，避免在传送点压进地形。
func _body_clear_at(pos: Vector2) -> bool:
	if _body_shape == null:
		_body_shape = RectangleShape2D.new()
		_body_shape.size = _body_max - _body_min
	var center := pos + (_body_min + _body_max) * 0.5
	var world := CollisionWorld.acquire(self)
	return world.shape_overlaps(_body_shape, Transform2D(0.0, center), CollisionWorld.LAYER_TERRAIN).is_empty()


func _teleport_to_flank() -> void:
	var ts := GameParameters.TILE_SIZE
	global_position = Vector2(_flank_cell.x * ts + ts * 0.5,
			_flank_cell.y * ts + ts * 0.5 - EnemyParams.BlackBird.teleport_drop)
	velocity = Vector2.ZERO
	_teleport_left = EnemyParams.BlackBird.teleport_entry_time
	activity = Activity.TELEPORT
	_flank_cell = Vector2i(-1, -1)
	_wrap()  # 物理保持规范坐标，只把渲染投影到玩家最近副本
	# 传送后朝向玩家。
	facing_left = toroidal_dir_to_player().x < 0.0


func _player_facing() -> int:
	var p := _nearest_player()
	if p != null:
		return p.facing_direction
	return 1


func _update_facing() -> void:
	if state == State.BACK_HOP:
		return
	if absf(velocity.x) > 5.0:
		_set_facing(velocity.x < 0.0)


func _start_back_hop() -> void:
	_set_state(State.BACK_HOP)
	activity = Activity.BACK_HOP
	var away := toroidal_dir_to_player()
	velocity = Vector2(-away.x * EnemyParams.BlackBird.back_hop_away, EnemyParams.BlackBird.back_hop_up)
	_back_hop_cd = 0.35
	_teleport_cooldown = EnemyParams.BlackBird.teleport_cooldown


func simulate_tick(delta: float) -> void:
	_teleport_left = maxf(_teleport_left - delta, 0.0)
	super(delta)

# 落水:朝玩家水平游(不朝岸边,保持追击感)。
func _water_swim_dir() -> Vector2:
	return toroidal_dir_to_player()


func _on_death() -> void:
	combat_rules.drop_grain(global_position, TimeParams.ELITE_GRAIN_DROP)
