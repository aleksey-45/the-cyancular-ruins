class_name EnemyBase
extends CharacterBody2D

const HitShape := preload("res://core/sim/hit_shape.gd")

signal died

var use_gravity: bool = true

@export var hp: int = 3
## 冲击攻击伤害:只被冲击攻击消费(跳鸟扑击读本字段;黑鸟/飞鸟冲锋读 EnemyParams 的 charge_damage)。
@export var impact_damage: int = 0
@export var knockback_strength: float = 150.0
var knock_velocity: Vector2 = Vector2.ZERO
@export var knock_decay_rate: float = 10.0

# 贴身感知半径:ContactArea 重叠或环面距离进入本半径,只喂冲锋/扑击判定,不产生伤害。
const CONTACT_RADIUS: float = 40.0

const GROUND_FRICTION: float = 0.85
const STOP_EPSILON: float = 5.0

var is_dead: bool = false
var _rewind_hold: bool = false
var _rw_held_layer: int = -1
var _hit_flash_time: float = 0.0
var _death_timer: float = -1.0
var _player_overlapping: bool = false
var _overlapping_players: Array = []
var _turn_cooldown: float = 0.0
# 玩家组每帧缓存:同一物理帧内 _players_frame() 只建一次数组,砍掉每帧每敌多次 get_nodes_in_group 分配。
var _players_frame_cache: Array = []
var _players_frame_id: int = -1
var wake_radius: float = 1000.0
var network_canonical: bool = false
var _in_water: bool = false
var _waterproof: int = 6
var waterproof_max: int = 6
var _waterproof_drain_timer: float = 0.0
var _waterproof_recover_timer: float = 0.0
var _drown_tick: float = 0.0
var state: int = 0
var _state_timer: float = 0.0
@export var light_model: String = "ellipsoid"   # 形体光策略(TAG):ellipsoid / cylinder / flat / sdf
var _anim: AnimatedSprite2D
var squash: SquashStretch = null
var _pre_move_vy: float = 0.0

func _ai(_delta: float) -> void:
	pass

func _anim_update() -> void:
	pass

func _water_swim_dir() -> Vector2:
	return Vector2.ZERO

func _ready() -> void:
	add_to_group("enemies")
	_setup_contact_area()
	add_child.call_deferred(WaterFx.new())
	squash = SquashStretch.new()
	add_child(squash)
	# ★ 查不到 animator 就当场报错,不让它静默降级:组件容忍 null animator,于是查表失败的表现是「这只鸟永远不变形」、一个字都不打 —— 三个 .tscn 里该节点都叫 AnimatedSprite2D,改名必须响。
	var anim := get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	if anim == null:
		push_error("EnemyBase: 找不到 AnimatedSprite2D 节点,补间形变将静默失效(节点名 = %s)"
				% name)
	squash.setup(anim, SquashStretch.Profile.ENEMY)
	# 形体光:敌人与玩家/武器共用同一份材质,由 PostProcess 每帧统一推方向。
	FormLight.attach(anim, light_model)

func _setup_contact_area() -> void:
	var area := Area2D.new()
	area.name = "ContactArea"
	area.collision_layer = 0
	area.collision_mask = 2
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
	delta = TimeField.enemy_delta(delta, self)
	if TimeField.current != null and TimeField.current.is_rewinding() and not has_meta("elite"):
		return
	var sleeping := _is_far_sleeping()
	squash.tick(delta, _pre_move_vy, is_on_floor(), is_dead)
	if sleeping:
		_pre_move_vy = 0.0
		_ai(delta)
		_wrap()
		return
	_turn_cooldown = maxf(_turn_cooldown - delta, 0.0)
	if use_gravity and not is_on_floor():
		velocity.y += GameParameters.gravity0 * delta
	if use_gravity and is_on_floor():
		velocity.x *= GROUND_FRICTION
		if absf(velocity.x) < STOP_EPSILON:
			velocity.x = 0.0
	if not is_dead:
		_ai(delta)
		_anim_update()
	if _hit_flash_time > 0.0:
		_hit_flash_time = maxf(_hit_flash_time - delta, 0.0)
	if _death_timer > 0.0:
		_death_timer -= delta
		if _death_timer <= 0.0:
			if _rewind_hold:
				visible = false
				set_physics_process(false)
				_rw_held_layer = collision_layer
				collision_layer = 0
				_death_timer = -1.0
			else:
				queue_free()
			return
	_flash_update()
	if is_dead:
		velocity *= exp(-knock_decay_rate * delta)
	_apply_water(delta)
	move_and_collide(knock_velocity * delta)
	knock_velocity *= exp(-knock_decay_rate * delta)
	# ★ 必须在 move_and_slide() 之前:落地那一帧它在调用后就被清零了。★ 敌人侧不做任何过滤,就是裸值 —— 这是实测后的裁定。
	# ⚠ 下面那些读数(239/1350 帧、13 次真实落水挤压、1.0861)出自一个已删除、此后从未重测的临时探针,本注释是它们唯一的留存处;裁定本身不依赖重测:过滤防的幽灵结构上不可达,却会吃掉真实落水挤压,净有害。
	_pre_move_vy = velocity.y
	# 时间场:水平运动走速度域(move_and_slide 用引擎 delta,缩放 delta 不改变位移);计时器/动画/重力仍走上面的 delta 缩放。精英与玩家同步,普通敌放慢。
	velocity.x *= TimeField.enemy_speed_mult(self)
	move_and_slide()
	_wrap()

func hurt(damage: int, knock_dir: Vector2, knock_strength: float = 0.0, set_velocity: bool = false) -> void:
	if is_dead:
		_apply_knock_only(knock_dir, knock_strength, set_velocity)
		return
	_apply_hit(damage, knock_dir, knock_strength, set_velocity)
	if hp <= 0:
		_begin_death()

func hurt_rect() -> Rect2:
	return HitShape.hurt_rect_of(self)

func is_hurtable() -> bool:
	return not is_dead and collision_layer != 0

func _apply_hit(damage: int, knock_dir: Vector2, knock_strength: float = 0.0, set_velocity: bool = false) -> void:
	hp -= damage
	var ks := knockback_strength if knock_strength <= 0.0 else knock_strength
	if set_velocity:
		knock_velocity = knock_dir.normalized() * ks
	else:
		velocity += knock_dir.normalized() * ks
	modulate = Color(3.0, 3.0, 3.0, 1.0)
	_hit_flash_time = EnemyParams.shared.hit_flash
	squash.impulse(SquashStretch.Impulse.HURT)

func _apply_knock_only(knock_dir: Vector2, knock_strength: float, set_velocity: bool) -> void:
	var ks := knockback_strength if knock_strength <= 0.0 else knock_strength
	if set_velocity:
		knock_velocity = knock_dir.normalized() * ks
	else:
		velocity += knock_dir.normalized() * ks


func _is_asleep() -> bool:
	return state == 0


func _is_far_sleeping() -> bool:
	if is_dead or _hit_flash_time > 0.0 or _death_timer > 0.0:
		return false
	if not _is_asleep():
		return false
	if not is_on_floor():
		return false
	if absf(velocity.x) > 5.0 or absf(velocity.y) > 5.0:
		return false
	return toroidal_dist_to_player() > wake_radius


func _apply_water(delta: float) -> void:
	var water := Water.sample_body(self, _in_water)
	_in_water = water.in_water
	if _in_water:
		var target_vy := clampf((water.surface_y - global_position.y) * EnemyParams.shared.bird_buoyancy_k,
			-EnemyParams.shared.bird_max_float, EnemyParams.shared.bird_max_sink)
		velocity.y = MathUtil.approach(velocity.y, target_vy, EnemyParams.shared.bird_water_damp, delta)
		var dir := _water_swim_dir()
		velocity.x = MathUtil.approach(velocity.x, dir.x * EnemyParams.shared.bird_swim_speed,
			EnemyParams.shared.bird_water_damp, delta)
	if water.head_under:
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
func _begin_death() -> void:
	if is_dead:
		return
	is_dead = true
	died.emit()
	_death_timer = EnemyParams.shared.death_flash_time
	if WorldRewind.hold_corpses and not has_meta("elite"):
		_rewind_hold = true
		set_meta("rw_death_ms", Time.get_ticks_msec())
	_on_death()


func _on_death() -> void:
	pass


# 冲锋冲击力:沿远离本体的方向猛推玩家(覆盖 take_hit 的普通击退);away 为 0(与玩家完全重合)时朝玩家背向推,拿不到 get_facing 就用 LEFT。
# ★ 名字刻意不叫 _apply_charge_impact:两个子类各自持有同名但两参的包装方法,而 GDScript 不允许子类以不同签名覆写父类方法(Parse Error,整个子类脚本加载失败 ⇒ -s 冒烟挂死),故基类另起名、子类包装转调这里。
func _smash_player(p: Node, impact: float, impact_up: float) -> void:
	var p2 := p as Node2D
	if p2 == null:
		return
	var away := (p2.global_position - global_position).normalized()
	if away == Vector2.ZERO:
		away = Vector2.LEFT
		if p2.has_method("get_facing"):
			away.x = -float(p2.get_facing())
	p2.velocity = away * impact
	p2.velocity.y -= impact_up


# 白闪渲染:受击/死亡任一激活即纯白,否则恢复。默认走 modulate;黑鸟因 silhouette shader 覆写 COLOR 而 modulate 失效,覆写本方法改走 shader 参数。
func _flash_update() -> void:
	modulate = Color(3.0, 3.0, 3.0, 1.0) if _hit_flash_time > 0.0 or _death_timer > 0.0 else Color.WHITE


func _set_facing(facing_left: bool) -> void:
	if _turn_cooldown > 0.0 or _anim.flip_h == facing_left:
		return
	_turn_cooldown = EnemyParams.shared.turn_min_interval
	_anim.flip_h = facing_left



func _set_state(s: int) -> void:
	state = s
	_state_timer = 0.0
	_on_state_entered(s)


func _on_state_entered(_s: int) -> void:
	pass


func _anim_duration(name: String) -> float:
	if _anim == null:
		return 0.0
	var spf := _anim.sprite_frames
	return float(spf.get_frame_count(name)) / spf.get_animation_speed(name)


# 玩家组引用(单机 1 人 / PvP 服务器 2 人通用):物理帧内按帧缓存一次、帧内复用;非物理上下文(如测试直调内部方法)每次现查,避免用过期的缓存位置。
func _players_frame() -> Array:
	if Engine.is_in_physics_frame():
		var fid := Engine.get_physics_frames()
		if fid != _players_frame_id:
			_players_frame_cache = get_tree().get_nodes_in_group("player")
			_players_frame_id = fid
		return _players_frame_cache
	return get_tree().get_nodes_in_group("player")


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
		return Vector2.RIGHT
	return delta.normalized()

func toroidal_delta_to_player() -> Vector2:
	var p := _nearest_player()
	if p == null:
		return Vector2.INF
	return MazeGenerator.toroidal_delta_px(global_position, (p as Node2D).global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)

func _wrap() -> void:
	if network_canonical:
		global_position = MazeGenerator.wrap_to_range(global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		return
	var p := _nearest_player() as Node2D
	if p == null:
		global_position = MazeGenerator.wrap_to_range(global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		return
	global_position = MazeGenerator.anchor_to_nearest(global_position, p.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)

func rewind_restore(d: Dictionary) -> void:
	var was_dead := is_dead
	global_position = d["p"]
	if d["v"] != null:
		velocity = d["v"]
	hp = int(d["hp"])
	is_dead = bool(d["dead"])
	if was_dead and not is_dead:
		visible = true
		set_physics_process(true)
		if _rw_held_layer >= 0:
			collision_layer = _rw_held_layer
			_rw_held_layer = -1
		_rewind_hold = false
		if has_meta("rw_death_ms"):
			remove_meta("rw_death_ms")
		_death_timer = -1.0
		_hit_flash_time = 0.0
		_flash_update()
	elif not was_dead and is_dead:
		visible = bool(d["vis"])
