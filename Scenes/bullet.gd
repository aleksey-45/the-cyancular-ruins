class_name Bullet
extends CharacterBody2D

var velocity_vec: Vector2 = Vector2.ZERO
var damage: int = 1
# 默认与全局射程一致(setup() 会再覆盖)
var max_range: float = GameParameters.bullet_range
var traveled: float = 0.0

func setup(dir: Vector2, speed: float, range: float, dmg: int) -> void:
	velocity_vec = dir.normalized() * speed
	max_range = range
	damage = dmg
	rotation = velocity_vec.angle()

func _ready() -> void:
	# 简单发光方块作为子弹贴图(以后可换成 Bullets.png 剪裁)
	var img := Image.create(10, 10, false, Image.FORMAT_RGBA8)
	img.fill(Color(1.0, 0.95, 0.6))
	var sp := Sprite2D.new()
	sp.texture = ImageTexture.create_from_image(img)
	add_child(sp)

func _physics_process(delta: float) -> void:
	var step := velocity_vec * delta
	traveled += step.length()
	var col := move_and_collide(step)
	if col:
		var hit := col.get_collider()
		if hit.is_in_group("enemies") and hit.has_method("hurt"):
			hit.hurt(damage, velocity_vec)
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
