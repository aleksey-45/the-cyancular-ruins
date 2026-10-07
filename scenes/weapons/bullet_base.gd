class_name BulletBase
extends CharacterBody2D

const BOUNCE_DAMPING: float = 0.6  # 撞墙反弹速度保留比例
const TileHitFx := preload("res://scenes/effects/tile_hit_fx.gd")

# 玩家命中判定半径（像素）
const PLAYER_HIT_RADIUS: float = 40.0
# 碰撞判定候选目标分组
const CONTACT_GROUPS: Array[String] = ["player", "player_replica"]

# 子弹物理属性（由武器发射时注入）
var velocity_vec: Vector2 = Vector2.ZERO
var speed: float = 0.0
var size: float = 1.0  # 子弹放大倍数
var gravity_factor: float = 0.0   # 重力下坠倍率
var breaks_terrain: bool = false
var has_aoe: bool = false
var bullet_color: Color = Color.WHITE  # 纹理材质着色
var max_range: float = 0.0
var traveled: float = 0.0
var source: Node = null
var shooter: Node = null  # 射手实体（用于击杀归因）
var hit_damage: int = 0    # 命中伤害值
var hit_impact: float = 0.0  # 命中击退力度
var apply_damage: bool = true  # 是否结算伤害（客户端视觉副本为 false）

# ── 爆炸弹（榴弹等）──
@export var explodes: bool = false        # 是否为爆炸弹
@export var direct_hit_damage: int = 10   # 命中直接伤害
@export var fuse_time: float = 0.5        # 撞墙反弹后延时引信（秒）
@export var hit_fuse_time: float = 0.1    # 命中敌人后短延时引信（秒）
@export var explosion_radius: float = 128.0
@export var explosion_damage: int = 35
@export var explosion_knockback: float = 900.0
@export var explosion_visual: PackedScene = null

var _fuse_active: bool = false   # 引信是否已激活
var _fuse_elapsed: float = 0.0
var _fuse_duration: float = 0.0  # 本次引信时长

func setup(dir: Vector2, spd: float, rng: float, siz: float, col: Color, src: Node) -> void:
	velocity_vec = dir.normalized() * spd
	speed = spd
	max_range = rng
	size = siz
	bullet_color = col
	source = src
	rotation = velocity_vec.angle()
	scale = Vector2(size, size)  # 放大倍数作用于整颗子弹(贴图+碰撞体)

func _ready() -> void:
	var sp := get_node_or_null("Sprite2D") as Sprite2D
	if sp != null:
		sp.modulate = bullet_color
	add_to_group("bullet")
	if Settings.pvp_show_trajectories:
		BulletTrail.attach(self, bullet_color)

func _physics_process(delta: float) -> void:
	delta = TimeField.bullet_delta(delta, self)
	if TimeField.current != null and TimeField.current.is_rewinding():
		return
	if gravity_factor > 0.0:
		velocity_vec.y += GameParameters.gravity0 * gravity_factor * delta
		if not velocity_vec.is_zero_approx():
			rotation = velocity_vec.angle()
	if explodes and not _fuse_active:
		_check_player_contact()
	if explodes and _fuse_active:
		_fuse_elapsed += delta
		if _fuse_elapsed >= _fuse_duration:
			_explode()
			queue_free()
			return
	_apply_water_drag(delta)
	var step := velocity_vec * delta
	traveled += step.length()
	var col := move_and_collide(step)
	if col:
		var hit := col.get_collider()
		if explodes:
			if hit != null and hit.is_in_group("enemies"):
				_direct_hit(hit)
				_start_fuse(hit_fuse_time)
			else:
				_start_fuse(fuse_time)
			var normal := col.get_normal()
			var reflected := velocity_vec.bounce(normal)
			velocity_vec = reflected * BOUNCE_DAMPING
			if not velocity_vec.is_zero_approx():
				rotation = velocity_vec.angle()
			return
		if apply_damage and hit.is_in_group("enemies") and is_instance_valid(source) and source.has_method("apply_hit"):
			CombatFeedback.hit_marker()
			source.apply_hit(hit, velocity_vec)
			Sfx.play("hit")
			queue_free()
		elif apply_damage and hit.is_in_group("enemies"):
			CombatFeedback.hit_marker()
			hit.hurt(hit_damage, velocity_vec, hit_impact)
			Sfx.play("hit")
			queue_free()
		else:
			_damage_tile_at(col.get_position(), col.get_normal())
			set_physics_process(false)
			velocity_vec = Vector2.ZERO
			get_tree().create_timer(0.05).timeout.connect(queue_free)
		return
	if traveled >= max_range:
		if explodes:
			_explode()
		queue_free()
		return
	_wrap()

# 子弹在水中受阻力减速
func _apply_water_drag(delta: float) -> void:
	var factor := Water.bullet_drag_factor(Water.is_in_water(global_position), GameParameters.water_bullet_drag, delta)
	if factor < 1.0:
		velocity_vec *= factor


func _wrap() -> void:
	# 环面世界坐标对齐：锚定至距射手或本地玩家最近的副本位置
	var p := get_tree().get_first_node_in_group("player") as Node2D
	if shooter != null and is_instance_valid(shooter) and shooter is Node2D and shooter.is_in_group("player"):
		p = shooter as Node2D
	if p == null:
		global_position = MazeGenerator.wrap_to_range(global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		return
	global_position = MazeGenerator.anchor_to_nearest(global_position, p.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)

# 撞击地形处理：对可破坏瓦片扣除耐久并生成受击碎屑
func _damage_tile_at(pos: Vector2, normal: Vector2) -> void:
	if MazeGenerator.current_subgrid.is_empty():
		var grid0 := MazeGenerator.current_grid
		if grid0.is_empty():
			return
		var ts0: int = GameParameters.TILE_SIZE
		var cell0 := MazeGenerator.cell_of(pos - normal * (ts0 * 0.5), ts0, grid0[0].size(), grid0.size())
		var v0: int = grid0[cell0.y][cell0.x]
		if v0 != 0 and TileDefs.bullet_destroyable(MazeGenerator.texture_of(v0)) and apply_damage:
			TileDefs.damage_tile(cell0, hit_damage, "bullet")
		return
	var cols: int = MazeGenerator.current_subgrid[0].size()
	var rows: int = MazeGenerator.current_subgrid.size()
	var probes := [pos, pos - normal * 8.0, pos - normal * 16.0]
	for p in probes:
		var sub := Vector2i(posmod(int(p.x) / 16, cols), posmod(int(p.y) / 16, rows))
		var tex: int = MazeGenerator.current_subgrid[sub.y][sub.x]
		if tex != 0 and TileDefs.bullet_destroyable(tex):
			TileHitFx.spawn(get_viewport(), pos, tex)
			if apply_damage:
				TileDefs.damage_sub(sub, hit_damage, "bullet", shooter)
		return


func _direct_hit(hit: Node) -> void:
	if not apply_damage:
		return
	if hit.has_method("hurt"):
		var dir := velocity_vec.normalized() if not velocity_vec.is_zero_approx() else Vector2.RIGHT
		CombatFeedback.hit_marker()
		hit.hurt(direct_hit_damage, dir)


# 检测爆炸弹与玩家的接触，触发短延时引信
func _check_player_contact() -> void:
	var tree := get_tree()
	if tree == null:
		return
	for group in CONTACT_GROUPS:
		for n in tree.get_nodes_in_group(group):
			if n == shooter or not (n is Node2D):
				continue
			var d := MazeGenerator.toroidal_delta_px(global_position, (n as Node2D).global_position,
					GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()
			if d < PLAYER_HIT_RADIUS:
				start_player_fuse()
				return

# 启动命中玩家的短延时引信
func start_player_fuse() -> void:
	if explodes:
		_start_fuse(hit_fuse_time)

# ── 时间回溯：保存与恢复引信及弹道状态 ──
func rewind_state() -> Dictionary:
	return {
		"fa": _fuse_active,
		"fe": _fuse_elapsed,
		"fd": _fuse_duration,
		"tr": traveled,
		"mr": max_range,
		"gf": gravity_factor,
		"sp": speed,
		"sz": size,
		"col": bullet_color,
	}


# 应用时间回溯状态快照
func apply_rewind_state(d: Dictionary) -> void:
	if d.is_empty():
		return
	_fuse_active = bool(d.get("fa", false))
	_fuse_elapsed = float(d.get("fe", 0.0))
	_fuse_duration = float(d.get("fd", 0.0))
	traveled = float(d.get("tr", 0.0))
	max_range = float(d.get("mr", max_range))
	gravity_factor = float(d.get("gf", gravity_factor))
	speed = float(d.get("sp", speed))
	size = float(d.get("sz", size))
	scale = Vector2(size, size)
	bullet_color = d.get("col", bullet_color)
	var sp2 := get_node_or_null("Sprite2D") as Sprite2D
	if sp2 != null:
		sp2.modulate = bullet_color


# 启动引信倒计时
func _start_fuse(duration: float) -> void:
	if not _fuse_active:
		_fuse_duration = duration
	_fuse_active = true

func _explode() -> void:
	if explosion_visual != null:
		var fx: Node = explosion_visual.instantiate()
		fx.global_position = global_position
		get_viewport().add_child(fx)
	for e in Explosion.destructible_subs(global_position, explosion_radius):
		var tile_pos: Vector2 = e["pos"]
		TileHitFx.spawn(get_viewport(), tile_pos, int(e["tex"]))
	if apply_damage:
		Explosion.apply_aoe(global_position, explosion_radius, explosion_damage, explosion_knockback, shooter)
