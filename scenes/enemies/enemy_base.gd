class_name EnemyBase
extends CharacterBody2D

# 进入死亡状态时发射一次(用于击杀计数等 UI;撞人自毁同算,见 FlyBird._die_self)
signal died

# 物理基础(子类可覆写:扑击时关闭重力)
var use_gravity: bool = true

# 战斗数值(可在检查器调,场景值优先)
# 血量
@export var hp: int = 3
# 接触玩家伤害
@export var contact_damage: int = 1
# 受击击退力度
@export var knockback_strength: float = 150.0
# 爆炸专属击退向量:独立于 AI 移动速度,每帧叠加后指数衰减(大冲击+迅速衰减)
var knock_velocity: Vector2 = Vector2.ZERO
# 击退向量指数衰减率(越大停得越快;约 0.23s 衰减到 ~10%)
@export var knock_decay_rate: float = 10.0

# 环面接缝兜底:物理 Area 用欧氏距离,跨接缝不重叠,这里用环面距离补(略大于 ContactArea 半对角线)
const CONTACT_RADIUS: float = 40.0

const GROUND_FRICTION: float = 0.85  # 落地时水平速度衰减系数
const STOP_EPSILON: float = 5.0      # 水平速度低于此值直接归零,避免贴地滑行

var is_dead: bool = false
var _hit_flash_time: float = 0.0
var _death_timer: float = -1.0   # 死亡白闪剩余;<0 未死亡(受击/死亡白闪统一在基类)
var _player_overlapping: bool = false
var _overlapping_players: Array = []  # 当前接触到的玩家节点(1v1 PvP 里可能同时撞到两人,受击取最近者)
var _turn_cooldown: float = 0.0  # 转向冷却:两次翻转朝向至少间隔 turn_min_interval
# 玩家组每帧缓存:同一物理帧内 _players_frame() 只建一次数组,砍掉每帧每敌多次 get_nodes_in_group 分配。
var _players_frame_cache: Array = []
var _players_frame_id: int = -1
var wake_radius: float = 1000.0  # 远处睡眠优化:距玩家超此值且落地静止 → 跳过物理
var network_canonical: bool = false  # PvP 服务器权威:敌人位置存 canonical [0,MAP)(_wrap 取模);单机/客户端 false=锚玩家副本渲染
var _in_water: bool = false
var _waterproof: int = 6                 # 防水值(氧气),没顶每 0.5s 掉 1
var waterproof_max: int = 6              # 上限:black/jump 6,fly 10
var _waterproof_drain_timer: float = 0.0
var _waterproof_recover_timer: float = 0.0
var _drown_tick: float = 0.0     # 扣血倒计时
# 状态机与动画(子类共用)。state 用 int 承载各子类自己的 enum 常量(见 JumpBird/FlyBird 的 enum State)。
var state: int = 0
var _state_timer: float = 0.0
var _anim: AnimatedSprite2D

# ── 行为钩子(子类覆写)──
func _ai(_delta: float) -> void:
	pass

func _anim_update() -> void:
	pass

# 落水时水平游泳方向(基类默认零=漂着;JumpBird/BlackBird 覆写为朝玩家)。
func _water_swim_dir() -> Vector2:
	return Vector2.ZERO

func _ready() -> void:
	add_to_group("enemies")
	_setup_contact_area()
	call_deferred("add_child", WaterFx.new())

func _setup_contact_area() -> void:
	var area := Area2D.new()
	area.name = "ContactArea"
	area.collision_layer = 0
	area.collision_mask = 2  # 检测玩家(layer 2)
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(44, 40)
	shape.shape = rect
	area.add_child(shape)
	add_child(area)
	area.body_entered.connect(_on_contact_body_entered)
	area.body_exited.connect(_on_contact_body_exited)

func _on_contact_body_entered(body: Node) -> void:
	if body.is_in_group("player"):
		_player_overlapping = true
		if not _overlapping_players.has(body):
			_overlapping_players.append(body)

func _on_contact_body_exited(body: Node) -> void:
	if body.is_in_group("player"):
		_overlapping_players.erase(body)
		_player_overlapping = not _overlapping_players.is_empty()

func _physics_process(delta: float) -> void:
	# 远处睡眠优化:距玩家超唤醒半径且落地静止 → 只播睡,跳过重力/滑行/水/移动(省 CPU)
	if _is_far_sleeping():
		_ai(delta)
		_wrap()
		return
	_turn_cooldown = maxf(_turn_cooldown - delta, 0.0)
	if use_gravity and not is_on_floor():
		velocity.y += GameParameters.gravity0 * delta
	# 地面摩擦:落地且非冲刺(use_gravity=true)时,水平速度平滑衰减,
	# 避免跳跃/冲刺/击飞的残留速度让敌人在地面滑行。
	# 放在 _ai 之前,这样 _ai 里新设的跳跃/冲刺初速不受当帧摩擦影响。
	if use_gravity and is_on_floor():
		velocity.x *= GROUND_FRICTION
		if absf(velocity.x) < STOP_EPSILON:
			velocity.x = 0.0
	# 死亡:AI 不行动,但物理(重力/摩擦/击退/碰撞)与生前完全一致。
	if not is_dead:
		_ai(delta)
		_anim_update()
		# 接触伤害:物理 Area 覆盖常规情况;环面接缝处欧氏距离不重叠,用环面距离兜底
		# contact_damage<=0 时跳过:零伤也会触发玩家 take_hit 消耗 iframe 并击退。
		if contact_damage > 0 and (_player_overlapping or toroidal_dist_to_player() <= CONTACT_RADIUS):
			var p := _contact_victim()
			if p != null and p.has_method("take_hit"):
				p.take_hit(global_position, contact_damage)
	# 受击/死亡白闪统一:计时 + 渲染(子类可覆写 _flash_update 换渲染方式,如黑鸟 silhouette)
	if _hit_flash_time > 0.0:
		_hit_flash_time = maxf(_hit_flash_time - delta, 0.0)
	if _death_timer > 0.0:
		_death_timer -= delta
		if _death_timer <= 0.0:
			queue_free()
			return
	_flash_update()
	if is_dead:
		# 尸体:基础速度也按击退速率指数衰减,滑行逐渐停住(不匀速滑到底);
		# 下落也随之变慢到"终端速度",更接近失去意识的尸体。
		velocity *= exp(-knock_decay_rate * delta)
	_apply_water(delta)
	# 爆炸击退位移:单独 move_and_collide(带碰撞),不污染 velocity
	# (地面把向下击退吃掉后再减回去会把身体弹起);主移动 move_and_slide 最后跑,地面状态以它为准。
	move_and_collide(knock_velocity * delta)
	knock_velocity *= exp(-knock_decay_rate * delta)
	move_and_slide()
	_wrap()

func hurt(damage: int, knock_dir: Vector2, knock_strength: float = 0.0, set_velocity: bool = false) -> void:
	if is_dead:
		# 尸体:不再扣血/触发死亡,但冲击波仍能推动(不吞冲击波)
		_apply_knock_only(knock_dir, knock_strength, set_velocity)
		return
	_apply_hit(damage, knock_dir, knock_strength, set_velocity)
	if hp <= 0:
		_begin_death()

# 受击通用逻辑:扣血、击退、白闪。子类覆写 hurt() 时也应调用本方法,避免逻辑分叉。
# knock_strength <= 0 时回落敌人自身 knockback_strength(旧两参调用行为不变)。
# set_velocity=true(爆炸):设独立击退向量 knock_velocity(封顶),不覆盖移动速度;false(枪击):叠加到原速度。
func _apply_hit(damage: int, knock_dir: Vector2, knock_strength: float = 0.0, set_velocity: bool = false) -> void:
	hp -= damage
	var ks := knockback_strength if knock_strength <= 0.0 else knock_strength
	if set_velocity:
		# 爆炸:设独立击退向量(不封顶),不覆盖移动速度
		knock_velocity = knock_dir.normalized() * ks
	else:
		velocity += knock_dir.normalized() * ks
	# 死亡:击退不折入,尸体与生前一致——knock_velocity 继续独立衰减,由 _physics_process 统一结算。
	modulate = Color(3.0, 3.0, 3.0, 1.0)  # 受击白闪
	_hit_flash_time = EnemyParams.shared.hit_flash

# 尸体专用:只施加击退(爆炸=设独立向量、枪击=叠加速度),不扣血、不触发死亡/白闪。
func _apply_knock_only(knock_dir: Vector2, knock_strength: float, set_velocity: bool) -> void:
	var ks := knockback_strength if knock_strength <= 0.0 else knock_strength
	if set_velocity:
		knock_velocity = knock_dir.normalized() * ks
	else:
		velocity += knock_dir.normalized() * ks


# 远处睡眠判定:距玩家超唤醒半径、落地静止、非受击/死亡/非SLEEP → true。
func _is_far_sleeping() -> bool:
	if is_dead or _hit_flash_time > 0.0 or _death_timer > 0.0:
		return false
	if state != 0:
		return false  # 非 SLEEP(所有子类 State.SLEEP=0)
	if not is_on_floor():
		return false
	if absf(velocity.x) > 5.0 or absf(velocity.y) > 5.0:
		return false
	return toroidal_dist_to_player() > wake_radius


func _approach(current: float, target: float, rate: float, delta: float) -> float:
	return lerp(current, target, 1.0 - exp(-rate * delta))


# 落水浮力:弹簧把身体中心拉回水面线(半没入);水平朝 _water_swim_dir 游;没顶累计溺水。
func _apply_water(delta: float) -> void:
	var feet := Vector2(global_position.x, global_position.y + Water.feet_offset(self))
	_in_water = Water.is_in_water(feet)
	var submerged := false
	if _in_water:
		var surface_y := Water.surface_y_at(global_position)
		submerged = Water.submerged(global_position, surface_y)
		var target_vy := clampf((surface_y - global_position.y) * EnemyParams.shared.bird_buoyancy_k,
			-EnemyParams.shared.bird_max_float, EnemyParams.shared.bird_max_sink)
		velocity.y = _approach(velocity.y, target_vy, EnemyParams.shared.bird_water_damp, delta)
		var dir := _water_swim_dir()
		velocity.x = _approach(velocity.x, dir.x * EnemyParams.shared.bird_swim_speed,
			EnemyParams.shared.bird_water_damp, delta)
	# 防水值(氧气):没顶掉,暴露空气回;空后每秒扣血
	if submerged:
		_waterproof_recover_timer = 0.0
		_waterproof_drain_timer += delta
		if _waterproof_drain_timer >= GameParameters.water_drain_interval:
			_waterproof_drain_timer = 0.0
			_waterproof = maxi(_waterproof - 1, 0)
	else:
		_waterproof_drain_timer = 0.0
		_waterproof_recover_timer += delta
		if _waterproof_recover_timer >= GameParameters.water_recover_interval:
			_waterproof_recover_timer = 0.0
			_waterproof = mini(_waterproof + 1, waterproof_max)
	if _waterproof <= 0:
		_drown_tick -= delta
		if _drown_tick <= 0.0:
			_drown_tick = EnemyParams.shared.drown_interval
			hurt(EnemyParams.shared.drown_damage, Vector2.ZERO)
# 死亡白闪统一入口:置死亡状态、发信号、起白闪计时(渲染由 _flash_update 统一处理,
# 到期在基类 _physics_process 销毁)。子类可在调用后追加专属处理(JumpBird 播 dead、
# FlyBird 清冲撞速度)。
func _begin_death() -> void:
	if is_dead:
		return
	is_dead = true
	died.emit()
	_death_timer = EnemyParams.shared.death_flash_time


# 白闪渲染:受击/死亡任一激活即纯白,否则恢复。默认走 modulate;黑鸟因 silhouette
# shader 覆写 COLOR 而 modulate 失效,覆写本方法改走 shader 参数。
func _flash_update() -> void:
	modulate = Color(3.0, 3.0, 3.0, 1.0) if _hit_flash_time > 0.0 or _death_timer > 0.0 else Color.WHITE


# 统一转向:两次翻转朝向至少间隔 turn_min_interval,防止敌人来回抖(看起来像 bug)。
# 朝向未变时不消耗冷却(持续面向玩家不会因此锁死)。
func _set_facing(facing_left: bool) -> void:
	if _turn_cooldown > 0.0 or _anim.flip_h == facing_left:
		return
	_turn_cooldown = EnemyParams.shared.turn_min_interval
	_anim.flip_h = facing_left


# ── 共享工具(子类通用)──

func _set_state(s: int) -> void:
	state = s
	_state_timer = 0.0


func _anim_duration(name: String) -> float:
	if _anim == null:
		return 0.0
	var spf := _anim.sprite_frames
	return float(spf.get_frame_count(name)) / spf.get_animation_speed(name)


# 玩家组引用(单机 1 人 / PvP 服务器 2 人通用)。物理帧内按帧缓存一次、帧内复用;
# 非物理上下文(如测试直调内部方法)每次现查,避免用过期的缓存位置。
func _players_frame() -> Array:
	if Engine.is_in_physics_frame():
		var fid := Engine.get_physics_frames()
		if fid != _players_frame_id:
			_players_frame_cache = get_tree().get_nodes_in_group("player")
			_players_frame_id = fid
		return _players_frame_cache
	return get_tree().get_nodes_in_group("player")


# 多玩家目标:取组里距自己最近的玩家(单机唯一玩家 → 行为不变)。无玩家返回 null。
func _nearest_player() -> Node2D:
	var best: Node2D = null
	var best_d := INF
	for p in _players_frame():
		var n := p as Node2D
		if n == null:
			continue
		var d := _toroidal_dist_to(n.global_position)
		if d < best_d:
			best_d = d
			best = n
	return best

# 接触受击目标:重叠的玩家里取最近者;无重叠时若环面距离兜底内(接缝 Area 不重叠)→ 全局最近玩家。
func _contact_victim() -> Node2D:
	var best: Node2D = null
	var best_d := INF
	for b in _overlapping_players:
		var n := b as Node2D
		if n == null or not is_instance_valid(n):
			continue
		var d := _toroidal_dist_to(n.global_position)
		if d < best_d:
			best_d = d
			best = n
	if best != null:
		return best
	return _nearest_player() if toroidal_dist_to_player() <= CONTACT_RADIUS else null

func _player_pos() -> Vector2:
	var p := _nearest_player() as Node2D
	return p.global_position if p != null else global_position


func _player_velocity() -> Vector2:
	var p := _nearest_player()
	if p != null and "velocity" in p:
		return p.velocity
	return Vector2.ZERO


func _cell_of(pos: Vector2) -> Vector2i:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return Vector2i.ZERO
	return MazeGenerator.cell_of(pos, GameParameters.TILE_SIZE, grid[0].size(), grid.size())


func _cell_is_solid(cell: Vector2i) -> bool:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return false
	return TileDefs.is_blocked(grid[cell.y][cell.x])


func _toroidal_dist_to(pos: Vector2) -> float:
	return MazeGenerator.toroidal_delta_px(global_position, pos,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()


func toroidal_dist_to_player() -> float:
	return toroidal_delta_to_player().length()

func toroidal_dir_to_player() -> Vector2:
	var delta := toroidal_delta_to_player()
	if delta == Vector2.INF or delta.is_zero_approx():
		return Vector2.RIGHT  # 无玩家或与玩家重叠时回退水平方向,避免 0/NaN 方向
	return delta.normalized()

func toroidal_delta_to_player() -> Vector2:
	var p := _nearest_player()
	if p == null:
		return Vector2.INF
	return MazeGenerator.toroidal_delta_px(global_position, (p as Node2D).global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)

func _wrap() -> void:
	# PvP 服务器权威:位置存 canonical [0,MAP),不做玩家副本锚定(副本归各端渲染)。
	if network_canonical:
		global_position = MazeGenerator.wrap_to_range(global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		return
	# 环面渲染回绕:把自己锚定到离玩家最近的副本(跟着主角一起取模)。
	# 墙体按 3x3 铺贴,相机在接缝处能看到另一侧的墙副本;若敌人仍取模到
	# [0,MAP),接缝附近就渲染到远副本而「消失」。每次按玩家当前位置重算,
	# 玩家跨接缝时敌人相对位置连续,不会像之前相机方案那样累计漂移。
	var p := _nearest_player() as Node2D
	if p == null:
		# 无玩家(场景切换/加载中)时退回绝对取模,防止敌人无限漂移
		global_position = MazeGenerator.wrap_to_range(global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		return
	global_position = MazeGenerator.anchor_to_nearest(global_position, p.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
