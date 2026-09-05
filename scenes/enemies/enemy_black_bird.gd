class_name EnemyBlackBird
extends EnemyBase

# 绕背瞬移刺客:睡眠 → 随机游走 → 周期性判定「玩家另一侧 × 距玩家 3~8 格(随机)」的
# 地板格落点(LOS 通)→ 起飞上跳 → 落地播 disappear → 白闪 → 传送 → 闪后空中播 appear
# → 落地 → 带跳跃的地面冲锋打 6 伤 → 大后跳(命中/未命中都) → 回游走,玩家远离入睡。
# 地面敌人(同 JumpBird 模式),全程受重力,不用飞行寻路。

enum State { SLEEP, WAKE, WANDER, TAKE_OFF, CHARGE, BACK_HOP }

var _wake_timer: float = -1.0        # wake_up 动画剩余;>=0 表示在播
var _sleep_anim_timer: float = -1.0  # fall_asleep 动画剩余
var _wander_timer: float = 0.0       # 当前这段行走剩余
var _wander_dir: float = 1.0         # 游走方向(±1)
var _wander_idle_timer: float = 0.0  # 游走停顿剩余(>0 = 站着不动)
var _flank_check_timer: float = 0.0  # 瞬移判定周期剩余
var _flank_cell: Vector2i = Vector2i(-1, -1)  # 选定落点格
var _landing_timer: float = 0.0      # 瞬移后落地兜底
var _prep_timer: float = 0.0         # 起飞落地后/传送落地后停顿剩余
var _wait_land: bool = false         # 起飞/传送后是否还在空中(等落地)
var _left_ground: bool = false       # 起飞/传送跳是否已离地(排除进状态帧 is_on_floor 的旧值)
var _teleport_cooldown: float = 0.0  # 冲锋结束后瞬移冷却剩余
var _charge_timer: float = 0.0       # 冲锋超时
var _back_hop_cd: float = 0.0        # 后跳落地冷却
var _body_min: Vector2 = Vector2.ZERO   # 碰撞箱 AABB 最小角(按 scale 换算)
var _body_max: Vector2 = Vector2.ZERO   # 碰撞箱 AABB 最大角(按 scale 换算)
var _teleport_flash_timer: float = 0.0  # 瞬移前后白闪剩余(纯白剪影,结束恢复)
var _silhouette_mat: ShaderMaterial = null  # 纯白剪影着色器材质
var _appear_timer: float = 0.0         # 传送后 appear 播完剩余(期间空中滞留,不落地)


func _ready() -> void:
	super._ready()
	_anim = $AnimatedSprite2D
	wake_radius = EnemyParams.BlackBird.wake_radius
	# 纯白剪影材质:每实例独立创建——tscn 里共享 sub_resource 材质会导致一只鸟白闪
	# 全屏鸟跟着白闪(跨实例),且编辑器重存 tscn 会把场景材质冲掉;代码挂最稳。
	var bb_shader := load("res://scenes/enemies/black_bird_silhouette.gdshader") as Shader
	var bb_mat := ShaderMaterial.new()
	bb_mat.shader = bb_shader
	_anim.material = bb_mat
	_silhouette_mat = bb_mat
	_set_state(State.SLEEP)
	_anim.play("sleep")
	_align_contact_area()
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
				_wander_idle_timer = 0.0
				_flank_check_timer = 0.5  # 先游走一会再判定瞬移,避免一醒就闪
		State.WANDER:
			if dist > EnemyParams.BlackBird.sleep_radius:
				_set_state(State.SLEEP)
				_anim.play("fall_asleep")
				_sleep_anim_timer = _anim_duration("fall_asleep")
				velocity.x = 0.0
				return
			# 行走一段后随机停顿 0~wander_idle_max(站着不动),减少频繁游荡感
			if _wander_idle_timer > 0.0:
				_wander_idle_timer -= delta
				velocity.x = 0.0
				_anim.stop()  # 冻在站立帧(idle 开始那帧已切到 frame 0)
			else:
				_anim.play("run")
				_wander_timer -= delta
				if _wander_timer <= 0.0:
					_wander_timer = randf_range(EnemyParams.BlackBird.wander_min_t, EnemyParams.BlackBird.wander_max_t)
					_wander_dir = 1.0 if randf() < 0.5 else -1.0
					_wander_idle_timer = randf_range(0.0, EnemyParams.BlackBird.wander_idle_max)
				if _wander_idle_timer > 0.0:
					# 刚决定停顿:本帧就停(切站立帧),不再移动
					velocity.x = 0.0
					_anim.play("run")
					_anim.frame = 0
					_anim.stop()
				else:
					velocity.x = _wander_dir * EnemyParams.BlackBird.wander_speed
					# 游走撞墙不卡死:小跳翻越矮墙(与冲锋自动跳同款判定)
					if is_on_wall():
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
					_anim.play("take_off")
		State.TAKE_OFF:
			# 起飞竖直上跳 → 落地 → 播 disappear → 白闪 → 传送
			if _wait_land:
				_anim.play("take_off")
				# 进状态那帧 is_on_floor 是旧的(上帧在地面),要求先离地再落地才算数
				if is_on_floor():
					if _left_ground:
						_wait_land = false
						# 落地瞬间:播 disappear(消散),停顿等它播完再闪
						_prep_timer = maxf(EnemyParams.BlackBird.teleport_prep_time, _anim_duration("disappear"))
					else:
						_left_ground = true
			elif _prep_timer > 0.0:
				_prep_timer -= delta
				velocity.x = 0.0  # 停顿期间停止左右移动
				_anim.play("disappear")
			else:
				if _flank_cell == Vector2i(-1, -1):
					_set_state(State.WANDER)  # 兜底:无落点不该进 TAKE_OFF
					return
				_teleport_to_flank()  # 白闪在 _teleport_to_flank 内触发(传送瞬间)
				_set_state(State.CHARGE)
				_charge_timer = EnemyParams.BlackBird.charge_timeout
				_landing_timer = EnemyParams.BlackBird.landing_timeout
				_wait_land = true
				_left_ground = true  # 传送后必在落点上方空中,之后任何落地都是真落地
				# appear 总时长 = 白闪 + 动画本身,期间在空中滞留(不落地)
				_appear_timer = EnemyParams.BlackBird.teleport_flash_time + _anim_duration("appear")
		State.CHARGE:
			if _appear_timer > 0.0:
				# 传送后:白闪滞留 → appear 播完(在空中)→ 才落地
				_appear_timer -= delta
				velocity = Vector2.ZERO  # 空中滞留,不受重力下落
				if _teleport_flash_timer <= 0.0:
					_anim.play("appear")  # 白闪结束才开始播 appear
				return
			_anim.play("run")
			# appear 落地 → 停顿 charge_prep_time → 才冲锋
			if _wait_land:
				if is_on_floor():
					if _left_ground:
						_wait_land = false
						_prep_timer = EnemyParams.BlackBird.charge_prep_time
					else:
						_left_ground = true
				_landing_timer -= delta
				if _landing_timer <= 0.0:
					_wait_land = false
					_prep_timer = EnemyParams.BlackBird.charge_prep_time  # 兜底:超时也进停顿
				velocity.x = 0.0
				return
			elif _prep_timer > 0.0:
				_prep_timer -= delta
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
				velocity.x = 0.0  # 越障跳纯上跳,不叠加水平分量
				velocity.y = EnemyParams.BlackBird.charge_jump_velocity
		State.BACK_HOP:
			if is_on_floor() and _back_hop_cd <= 0.0:
				_set_state(State.WANDER)
				_wander_timer = 0.2
				_wander_idle_timer = 0.0
				_flank_check_timer = EnemyParams.BlackBird.flank_check_interval


# 游走中瞬移判定:在「距玩家 3~8 格(随机)、且位于玩家相对鸟的另一侧」的环形带
# (环面取模)搜地板格(EMPTY 且正下方非 EMPTY),且该格到玩家格 LOS 通 → 可瞬移冲锋。
func _find_flank_cell() -> bool:
	var p := _nearest_player() as Node2D
	var grid := MazeGenerator.current_grid
	if p == null or grid.is_empty():
		return false
	var cols := grid[0].size()
	var rows := grid.size()
	var ts := GameParameters.TILE_SIZE
	var player_cell := MazeGenerator.cell_of(p.global_position, ts, cols, rows)
	var bird_cell := MazeGenerator.cell_of(global_position, ts, cols, rows)
	var player_px := Vector2(player_cell.x * ts + ts * 0.5, player_cell.y * ts + ts * 0.5)
	var bird_px := Vector2(bird_cell.x * ts + ts * 0.5, bird_cell.y * ts + ts * 0.5)
	# 目标侧 = 玩家相对鸟的另一侧:取「玩家→鸟」偏移的主轴,落点取该轴反号
	var off := MazeGenerator.toroidal_delta_px(player_px, bird_px, cols * ts, rows * ts)
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
			var c := Vector2i(posmod(player_cell.x + dx, cols), posmod(player_cell.y + dy, rows))
			# 距离与侧向都用环面最短向量,避免跨接缝失真
			var c_px := Vector2(c.x * ts + ts * 0.5, c.y * ts + ts * 0.5)
			var rel := MazeGenerator.toroidal_delta_px(player_px, c_px, cols * ts, rows * ts)
			var dlen := rel.length()
			if dlen < min_d or dlen > max_d:
				continue
			if use_x and signf(rel.x) != -sx:
				continue
			if not use_x and signf(rel.y) != -sy:
				continue
			if not _is_floor_cell(c):
				continue
			# 瞬移落点上方必须有空间:碰撞箱在「下落起点」处不压到任何实心格,
			# 否则会穿进天花板/檐下/矮洞(落点格是地板但头顶有墙)。
			var drop_pos := Vector2(c.x * ts + ts * 0.5, c.y * ts + ts * 0.5 - EnemyParams.BlackBird.teleport_drop)
			if not _body_clear_at(drop_pos):
				continue
			if not MazeGenerator.has_line_of_sight(c, player_cell):
				continue
			valid.append(c)
	if valid.is_empty():
		return false
	_flank_cell = valid[randi() % valid.size()]  # 距离与方位在环带内随机
	return true


func _is_floor_cell(c: Vector2i) -> bool:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return false
	return grid[c.y][c.x] == MazeGenerator.EMPTY and TileDefs.is_blocked(grid[posmod(c.y + 1, grid.size())][c.x])


# 黑鸟碰撞箱(按 scale 换算)在 pos 处覆盖的格子是否全是 EMPTY。
# 用于瞬移落点清空判定:落点/下落路径不能穿墙。
func _body_clear_at(pos: Vector2) -> bool:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return true
	var rows := grid.size()
	var cols := grid[0].size()
	var ts := GameParameters.TILE_SIZE
	var x0 := floori((pos.x + _body_min.x) / ts)
	var x1 := floori((pos.x + _body_max.x) / ts)
	var y0 := floori((pos.y + _body_min.y) / ts)
	var y1 := floori((pos.y + _body_max.y) / ts)
	for gy in range(y0, y1 + 1):
		for gx in range(x0, x1 + 1):
			if TileDefs.is_blocked(grid[posmod(gy, rows)][posmod(gx, cols)]):
				return false
	return true


func _teleport_to_flank() -> void:
	var ts := GameParameters.TILE_SIZE
	global_position = Vector2(_flank_cell.x * ts + ts * 0.5,
			_flank_cell.y * ts + ts * 0.5 - EnemyParams.BlackBird.teleport_drop)
	velocity = Vector2.ZERO
	_teleport_flash_timer = EnemyParams.BlackBird.teleport_flash_time  # 传送白闪(覆盖消散→到达),闪完播 appear
	_flank_cell = Vector2i(-1, -1)
	_wrap()  # 锚定到玩家最近副本(环面)
	# 传送后朝向玩家(appear 出现即面向目标;后续冲锋 _update_facing 也会跟方向)
	_anim.flip_h = toroidal_dir_to_player().x < 0.0


func _player_facing() -> int:
	var p := _nearest_player()
	if p != null and p.has_method("get_facing"):
		return p.get_facing()
	return 1


func _update_facing() -> void:
	if absf(velocity.x) > 5.0:
		_set_facing(velocity.x < 0.0)


# 冲锋命中玩家:穿透无敌帧打伤 + 猛推飞玩家,随后大后跳。
func _on_charge_hit_player() -> void:
	var p := _nearest_player()
	if p != null and p.has_method("take_hit"):
		p.take_hit(global_position, EnemyParams.BlackBird.charge_damage, true)
		_apply_charge_impact(p)
	_start_back_hop()


# 冲锋冲击力:沿远离黑鸟的方向猛推玩家(覆盖 take_hit 的普通击退,冲锋更狠,同飞鸟)。
func _apply_charge_impact(p: Node) -> void:
	var p2 := p as Node2D
	if p2 == null:
		return
	var away := (p2.global_position - global_position).normalized()
	if away == Vector2.ZERO:
		away = Vector2.LEFT
		if p2.has_method("get_facing"):
			away.x = -float(p2.get_facing())
	p2.velocity = away * EnemyParams.BlackBird.charge_impact
	p2.velocity.y -= EnemyParams.BlackBird.charge_impact_up


func _start_back_hop() -> void:
	_set_state(State.BACK_HOP)
	_anim.play("jump_backward")
	var away := toroidal_dir_to_player()
	velocity = Vector2(-away.x * EnemyParams.BlackBird.back_hop_away, EnemyParams.BlackBird.back_hop_up)
	_back_hop_cd = 0.35
	_teleport_cooldown = EnemyParams.BlackBird.teleport_cooldown


func hurt(damage: int, knock_dir: Vector2, knock_strength: float = 0.0, set_velocity: bool = false) -> void:
	if is_dead:
		_apply_knock_only(knock_dir, knock_strength, set_velocity)
		return
	_apply_hit(damage, knock_dir, knock_strength, set_velocity)
	if hp <= 0:
		_begin_death()


func _physics_process(delta: float) -> void:
	# 瞬移白闪计时(渲染由 _flash_update 统一处理)
	if _teleport_flash_timer > 0.0:
		_teleport_flash_timer = maxf(_teleport_flash_timer - delta, 0.0)
	super._physics_process(delta)


# 黑鸟白闪走纯白剪影 shader(自定义 canvas shader 覆写 COLOR 时 modulate 不生效):
# 受击/死亡/瞬移任一激活即纯白,否则正常渲染。
func _flash_update() -> void:
	if _silhouette_mat != null:
		_silhouette_mat.set_shader_parameter("silhouette",
				1.0 if _hit_flash_time > 0.0 or _death_timer > 0.0 or _teleport_flash_timer > 0.0 else 0.0)

# 落水:朝玩家水平游(不朝岸边,保持追击感)。
func _water_swim_dir() -> Vector2:
	return toroidal_dir_to_player()
