class_name EnemyBlackBird
extends EnemyBase

# 绕背瞬移刺客:睡眠 → 随机游走 → 周期性判定「玩家面朝反方向」的地板格落点(LOS 通)
# → 起飞动作 → 瞬移落地 → 带跳跃的地面冲锋打 6 伤 → 大后跳(命中/未命中都) → 回游走。
# 地面敌人(同 JumpBird 模式),全程受重力,不用飞行寻路。

enum State { SLEEP, WAKE, WANDER, TAKE_OFF, CHARGE, BACK_HOP }

var _wake_timer: float = -1.0        # wake_up 动画剩余;>=0 表示在播
var _sleep_anim_timer: float = -1.0  # fall_asleep 动画剩余
var _wander_timer: float = 0.0       # 下次随机换向剩余
var _wander_dir: float = 1.0         # 游走方向(±1)
var _flank_check_timer: float = 0.0  # 瞬移判定周期剩余
var _flank_cell: Vector2i = Vector2i(-1, -1)  # 选定落点格
var _landing_timer: float = 0.0      # 瞬移后落地兜底
var _charge_timer: float = 0.0       # 冲锋超时
var _back_hop_cd: float = 0.0        # 后跳落地冷却
var _death_timer: float = -1.0       # 死亡白闪剩余;<0 表示未死亡


func _ready() -> void:
	super._ready()
	_anim = $AnimatedSprite2D
	_set_state(State.SLEEP)
	_anim.play("sleep")
	_align_contact_area()


# 接触范围与身体对齐:黑鸟碰撞箱按 scale 2.5 世界约 100px,ContactArea 由 EnemyBase
# 代码创建(不在场景里),这里把形状放大并下移对齐身体中心。
func _align_contact_area() -> void:
	var area := get_node_or_null("ContactArea") as Area2D
	if area != null:
		for child in area.get_children():
			if child is CollisionShape2D:
				var area_shape := RectangleShape2D.new()
				area_shape.size = Vector2(46, 36)
				child.shape = area_shape
				child.position = Vector2(4, 4)
				break


func _ai(delta: float) -> void:
	var dist := toroidal_dist_to_player()
	_back_hop_cd = maxf(_back_hop_cd - delta, 0.0)
	if state != State.SLEEP:
		_update_facing()
	match state:
		State.SLEEP:
			if _wake_timer > 0.0:
				_wake_timer -= delta
				if _wake_timer <= 0.0:
					_set_state(State.WAKE)
			elif _sleep_anim_timer > 0.0:
				_sleep_anim_timer -= delta
				if _sleep_anim_timer <= 0.0:
					_anim.play("sleep")
			else:
				_anim.play("sleep")
				if dist <= EnemyParams.BlackBird.wake_radius:
					_anim.play("wake_up")
					_wake_timer = _anim_duration("wake_up")
		State.WAKE:
			if _wake_timer > 0.0:
				_wake_timer -= delta
			if _wake_timer <= 0.0:
				_set_state(State.WANDER)
				_wander_timer = 0.2
				_flank_check_timer = 0.5  # 先游走一会再判定瞬移,避免一醒就闪
		State.WANDER:
			_anim.play("run")
			if dist > EnemyParams.BlackBird.sleep_radius:
				_set_state(State.SLEEP)
				_anim.play("fall_asleep")
				_sleep_anim_timer = _anim_duration("fall_asleep")
				velocity.x = 0.0
				return
			_wander_timer -= delta
			if _wander_timer <= 0.0:
				_wander_timer = randf_range(EnemyParams.BlackBird.wander_min_t, EnemyParams.BlackBird.wander_max_t)
				_wander_dir = 1.0 if randf() < 0.5 else -1.0
			velocity.x = _wander_dir * EnemyParams.BlackBird.wander_speed
			_flank_check_timer -= delta
			if _flank_check_timer <= 0.0:
				_flank_check_timer = EnemyParams.BlackBird.flank_check_interval
				if _find_flank_cell():
					velocity.x = 0.0
					_set_state(State.TAKE_OFF)
					_anim.play("take_off")
					_state_timer = _anim_duration("take_off")
		State.TAKE_OFF:
			_state_timer -= delta
			if _state_timer <= 0.0:
				if _flank_cell == Vector2i(-1, -1):
					_set_state(State.WANDER)  # 兜底:无落点不该进 TAKE_OFF
					return
				_teleport_to_flank()
				_set_state(State.CHARGE)
				_charge_timer = EnemyParams.BlackBird.charge_timeout
				_landing_timer = EnemyParams.BlackBird.landing_timeout
				_anim.play("run")
		State.CHARGE:
			_anim.play("run")
			# 瞬移后先落地(只受重力),落地或兜底后才开始水平冲锋
			if _landing_timer > 0.0:
				_landing_timer -= delta
				if is_on_floor() or _landing_timer <= 0.0:
					_landing_timer = 0.0
				else:
					velocity.x = 0.0
					return
			if _player_overlapping or toroidal_dist_to_player() <= CONTACT_RADIUS:
				_on_charge_hit_player()
				return
			_charge_timer -= delta
			if _charge_timer <= 0.0:
				_start_back_hop()
				return
			var dir := toroidal_dir_to_player()
			velocity.x = dir.x * EnemyParams.BlackBird.charge_speed
			if is_on_wall():
				velocity.y = EnemyParams.BlackBird.charge_jump_velocity
		State.BACK_HOP:
			if is_on_floor() and _back_hop_cd <= 0.0:
				_set_state(State.WANDER)
				_wander_timer = 0.2
				_flank_check_timer = EnemyParams.BlackBird.flank_check_interval


# 游走中瞬移判定:在「玩家面朝反方向 × flank_distance」的理想格周围按距离递增(环面
# 取模)搜地板格(EMPTY 且正下方 SOLID),且该格到玩家格 LOS 通 → 可瞬移冲锋。
func _find_flank_cell() -> bool:
	var p := get_tree().get_first_node_in_group("player") as Node2D
	var grid := MazeGenerator.current_grid
	if p == null or grid.is_empty():
		return false
	var cols := grid[0].size()
	var rows := grid.size()
	var ts := GameParameters.TILE_SIZE
	var facing := _player_facing()
	var player_cell := MazeGenerator.cell_of(p.global_position, ts, cols, rows)
	var dist_cells := int(EnemyParams.BlackBird.flank_distance / ts)
	var ideal := Vector2i(player_cell.x - facing * dist_cells, player_cell.y)
	var search := EnemyParams.BlackBird.flank_search_cells
	for radius in range(0, search + 1):
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if max(abs(dx), abs(dy)) != radius:
					continue
				var c := Vector2i(posmod(ideal.x + dx, cols), posmod(ideal.y + dy, rows))
				if _is_floor_cell(c) and MazeGenerator.has_line_of_sight(c, player_cell):
					_flank_cell = c
					return true
	return false


func _is_floor_cell(c: Vector2i) -> bool:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return false
	return grid[c.y][c.x] == MazeGenerator.EMPTY and grid[posmod(c.y + 1, grid.size())][c.x] == MazeGenerator.SOLID


func _teleport_to_flank() -> void:
	var ts := GameParameters.TILE_SIZE
	global_position = Vector2(_flank_cell.x * ts + ts * 0.5,
			_flank_cell.y * ts + ts * 0.5 - EnemyParams.BlackBird.teleport_drop)
	velocity = Vector2.ZERO
	_flank_cell = Vector2i(-1, -1)
	_wrap()  # 锚定到玩家最近副本(环面)


func _player_facing() -> int:
	var p := get_tree().get_first_node_in_group("player")
	if p != null and p.has_method("get_facing"):
		return p.get_facing()
	return 1


func _update_facing() -> void:
	if absf(velocity.x) > 5.0:
		_anim.flip_h = velocity.x < 0.0


# 冲锋命中玩家:穿透无敌帧打 6 伤,随后大后跳。
func _on_charge_hit_player() -> void:
	var p := get_tree().get_first_node_in_group("player")
	if p != null and p.has_method("take_hit"):
		p.take_hit(global_position, EnemyParams.BlackBird.charge_damage, true)
	_start_back_hop()


func _start_back_hop() -> void:
	_set_state(State.BACK_HOP)
	_anim.play("jump_backward")
	var away := toroidal_dir_to_player()
	velocity = Vector2(-away.x * EnemyParams.BlackBird.back_hop_away, EnemyParams.BlackBird.back_hop_up)
	_back_hop_cd = 0.35


func hurt(damage: int, knock_dir: Vector2, knock_strength: float = 0.0, set_velocity: bool = false) -> void:
	if is_dead:
		_apply_knock_only(knock_dir, knock_strength, set_velocity)
		return
	_apply_hit(damage, knock_dir, knock_strength, set_velocity)
	if hp <= 0:
		is_dead = true
		died.emit()
		_death_timer = EnemyParams.BlackBird.death_flash_time


func _physics_process(delta: float) -> void:
	if is_dead:
		_death_timer -= delta
		if _death_timer <= 0.0:
			queue_free()
			return
		# 白闪闪烁,物理与生前一致(走 super 统一路径)
		modulate = Color(3.0, 3.0, 3.0, 1.0) if int(_death_timer * 20.0) % 2 == 0 else Color(1.0, 1.0, 1.0, 0.35)
		super._physics_process(delta)
		return
	super._physics_process(delta)
