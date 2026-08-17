class_name BulletBase
extends CharacterBody2D

# 子弹只管理物理属性(开火时由武器设置)。不含伤害:命中敌人回调 source.apply_hit。
var velocity_vec: Vector2 = Vector2.ZERO
var speed: float = 0.0
var size: float = 5.0
var gravity_factor: float = 0.0   # 重力下坠倍率(枪械=0,以后敌方弹药可>0)
var breaks_terrain: bool = false
var has_aoe: bool = false
var bullet_color: Color = Color.WHITE  # 纹理本底;武器如需染色再设
var max_range: float = 0.0
var traveled: float = 0.0
var source: Node = null

func setup(dir: Vector2, spd: float, rng: float, siz: float, col: Color, src: Node) -> void:
	velocity_vec = dir.normalized() * spd
	speed = spd
	max_range = rng
	size = siz
	bullet_color = col
	source = src
	rotation = velocity_vec.angle()

func _ready() -> void:
	# 子弹贴图与碰撞体由场景(bullet.tscn)配置:贴图是 Bullets.png 的 Sprite2D,
	# 碰撞体已是 RectangleShape2D。这里不再动态生成方块,只把武器 bullet_color 作 tint。
	var sp := get_node_or_null("Sprite2D") as Sprite2D
	if sp != null:
		sp.modulate = bullet_color

func _physics_process(delta: float) -> void:
	var step := velocity_vec * delta
	traveled += step.length()
	var col := move_and_collide(step)
	if col:
		var hit := col.get_collider()
		# 切枪后旧武器可能已 free():在途子弹的 source 失效时无害消失。
		if hit.is_in_group("enemies") and is_instance_valid(source) and source.has_method("apply_hit"):
			source.apply_hit(hit, velocity_vec)
		queue_free()
		return
	if traveled >= max_range:
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
