class_name BulletBase
extends CharacterBody2D

const BOUNCE_DAMPING: float = 0.6  # 撞墙反弹速度保留比例
const TileHitFx := preload("res://Scenes/Effects/tile_hit_fx.gd")

# 子弹只管理物理属性(开火时由武器设置)。不含伤害:命中敌人回调 source.apply_hit。
var velocity_vec: Vector2 = Vector2.ZERO
var speed: float = 0.0
var size: float = 1.0  # 子弹放大倍数(setup 时应用为节点缩放)
var gravity_factor: float = 0.0   # 重力下坠倍率(枪械=0,以后敌方弹药可>0)
var breaks_terrain: bool = false
var has_aoe: bool = false
var bullet_color: Color = Color.WHITE  # 纹理本底;武器如需染色再设
var max_range: float = 0.0
var traveled: float = 0.0
var source: Node = null
var shooter: Node = null  # 射手玩家(击杀归因用):本地=武器持有者;服务器=权威模拟里的玩家
var hit_damage: int = 0    # 命中伤害(武器 fire 注入;切枪后 source 失效时兜底直接结算)
var hit_impact: float = 0.0  # 命中击退(同上)
var apply_damage: bool = true  # 客户端视觉副本设 false:只出特效/轨迹,不裁决伤害(伤害由服务器裁决)

# ── 爆炸弹(榴弹等) ──
@export var explodes: bool = false        # 是否爆炸弹
@export var direct_hit_damage: int = 10   # 命中敌人的直接伤害(立即结算)
@export var fuse_time: float = 0.5        # 撞墙反弹后延时(秒)
@export var hit_fuse_time: float = 0.1    # 命中敌人反弹后延时(秒);直接伤立即,反弹后短引信
@export var explosion_radius: float = 128.0
@export var explosion_damage: int = 35
@export var explosion_knockback: float = 900.0
@export var explosion_visual: PackedScene = null

var _fuse_active: bool = false   # 首次碰撞(撞墙/命中敌人)后才开始计时
var _fuse_elapsed: float = 0.0
var _fuse_duration: float = 0.0  # 本次引信时长(撞墙=fuse_time,命中敌人=hit_fuse_time)

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
	# 子弹贴图与碰撞体由场景(bullet.tscn)配置:贴图是 Bullets.png 的 Sprite2D,
	# 碰撞体已是 RectangleShape2D。这里不再动态生成方块,只把武器 bullet_color 作 tint。
	var sp := get_node_or_null("Sprite2D") as Sprite2D
	if sp != null:
		sp.modulate = bullet_color
	# 服务器裁决用:所有子弹进 bullet 组,MatchHost 遍历做命中判定/广播
	add_to_group("bullet")

func _physics_process(delta: float) -> void:
	if gravity_factor > 0.0:
		velocity_vec.y += GameParameters.gravity0 * gravity_factor * delta
		if not velocity_vec.is_zero_approx():
			rotation = velocity_vec.angle()
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
			# 命中敌人:直接伤立即结算;与撞墙一样反弹(带衰减),引信用短时长 hit_fuse_time(0.1s)
			if hit != null and hit.is_in_group("enemies"):
				_direct_hit(hit)
				_start_fuse(hit_fuse_time)
			else:
				# 撞墙:反弹(带衰减),首次碰撞后开始引信(fuse_time);不直接清零速度
				_start_fuse(fuse_time)
			var normal := col.get_normal()
			var reflected := velocity_vec.bounce(normal)
			velocity_vec = reflected * BOUNCE_DAMPING
			if not velocity_vec.is_zero_approx():
				rotation = velocity_vec.angle()
			return
		# 命中敌人:优先走 source(武器)的 apply_hit;切枪后旧武器已 free 时,用子弹自带 damage/impact 兜底直接结算。
		# 视觉副本(apply_damage=false)不裁决伤害,直接消失。
		if apply_damage and hit.is_in_group("enemies") and is_instance_valid(source) and source.has_method("apply_hit"):
			source.apply_hit(hit, velocity_vec)
			queue_free()
		elif apply_damage and hit.is_in_group("enemies"):
			hit.hurt(hit_damage, velocity_vec, hit_impact)
			queue_free()
		else:
			# 撞墙:可破坏(树叶/树干)→ 扣血;不可破坏墙 → 子弹消失。延迟销毁确保破坏回调跑完。
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

# 子弹在水里受速度方向阻力:velocity_vec *= exp(-drag·Δt)(纯系数在 Water.bullet_drag_factor)。
func _apply_water_drag(delta: float) -> void:
	var factor := Water.bullet_drag_factor(Water.is_in_water(global_position), GameParameters.water_bullet_drag, delta)
	if factor < 1.0:
		velocity_vec *= factor


func _wrap() -> void:
	# 与敌人一致:锚定到离玩家最近的副本(跟着主角取模),接缝附近不消失。
	# PvP 服务器上有两个玩家在 player 组:优先锚到射手(否则 role2 子弹会锚到 role1 副本)。
	# 客户端视觉副本 shooter 为 null → 回落第一个玩家(即本地玩家)。
	var p := get_tree().get_first_node_in_group("player") as Node2D
	if shooter != null and is_instance_valid(shooter) and shooter is Node2D and shooter.is_in_group("player"):
		p = shooter as Node2D
	if p == null:
		global_position = MazeGenerator.wrap_to_range(global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		return
	global_position = MazeGenerator.anchor_to_nearest(global_position, p.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)

# 撞墙处理:若该格可子弹破坏(树叶/树干)则扣血 + 受击粒子;破坏后变空气(Level0 刷新渲染/碰撞)。
func _damage_tile_at(pos: Vector2, normal: Vector2) -> void:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return
	var ts: int = GameParameters.TILE_SIZE
	var cols := grid[0].size()
	var rows := grid.size()
	# 候选格:碰撞点、沿法线推入墙内 0.5/1 格 —— 处理贴边命中/边界浮点映射到墙前空格。
	# normal 指向远离墙(朝子弹),-normal 即推入墙内。
	var probes := [Vector2.ZERO, -normal * (ts * 0.5), -normal * ts]
	for off in probes:
		var cell := MazeGenerator.cell_of(pos + off, ts, cols, rows)
		var v: int = grid[cell.y][cell.x]
		if v != 0:
			var tex: int = v / 16
			if TileDefs.bullet_destroyable(tex):
				TileDefs.damage_tile(cell, hit_damage, "bullet")
				TileHitFx.spawn(get_viewport(), pos, tex)
			return

func _direct_hit(hit: Node) -> void:
	if not apply_damage:
		return
	if hit.has_method("hurt"):
		var dir := velocity_vec.normalized() if not velocity_vec.is_zero_approx() else Vector2.RIGHT
		hit.hurt(direct_hit_damage, dir)

# 开始引信:首次碰撞(撞墙/命中敌人)起算,撞墙用 fuse_time,命中敌人用 hit_fuse_time。
# 后续反弹不重置时长(首次碰撞决定引信时长,不因再撞墙/再撞敌人刷新)。
func _start_fuse(duration: float) -> void:
	if not _fuse_active:
		_fuse_duration = duration
	_fuse_active = true

func _explode() -> void:
	if explosion_visual != null:
		var fx: Node = explosion_visual.instantiate()
		fx.global_position = global_position
		get_viewport().add_child(fx)
	if apply_damage:
		Explosion.apply_aoe(global_position, explosion_radius, explosion_damage, explosion_knockback, shooter)
