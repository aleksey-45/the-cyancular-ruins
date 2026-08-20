class_name BulletBase
extends CharacterBody2D

const BOUNCE_DAMPING: float = 0.6  # 撞墙反弹速度保留比例

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
var hit_damage: int = 0    # 命中伤害(武器 fire 注入;切枪后 source 失效时兜底直接结算)
var hit_impact: float = 0.0  # 命中击退(同上)

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
		if hit.is_in_group("enemies") and is_instance_valid(source) and source.has_method("apply_hit"):
			source.apply_hit(hit, velocity_vec)
		elif hit.is_in_group("enemies"):
			hit.hurt(hit_damage, velocity_vec, hit_impact)
		queue_free()
		return
	if traveled >= max_range:
		if explodes:
			_explode()
		queue_free()
		return
	_wrap()

func _wrap() -> void:
	# 与敌人一致:锚定到离玩家最近的副本(跟着主角取模),接缝附近不消失。
	var p := get_tree().get_first_node_in_group("player") as Node2D
	if p == null:
		global_position = MazeGenerator.wrap_to_range(global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		return
	global_position = MazeGenerator.anchor_to_nearest(global_position, p.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)

func _direct_hit(hit: Node) -> void:
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
	Explosion.apply_aoe(global_position, explosion_radius, explosion_damage, explosion_knockback)
