class_name EnemyBullet
extends BulletBase

# 敌方投弹:由发射者给定初速向量与重力倍率,重力抛物线飞行,命中玩家造成 damage。
# 场景 collision_mask=3(层1地形+层2玩家),不含层3 → 不撞自己/其他敌人。
var damage: int = 2


# 抛物线初速版 setup:直接设初速向量(平抛/投掷用)。不染色,子弹用贴图本底色。
# siz 是放大倍数(默认 1.0 不动),与 BulletBase.setup() 一样作用于整颗子弹。
func launch(vel: Vector2, rng: float, dmg: int, grav: float, siz: float = 1.0) -> void:
	velocity_vec = vel
	speed = vel.length()
	max_range = rng
	damage = dmg
	gravity_factor = grav
	size = siz
	rotation = vel.angle()
	scale = Vector2(size, size)


func _physics_process(delta: float) -> void:
	velocity_vec.y += GameParameters.gravity0 * gravity_factor * delta
	rotation = velocity_vec.angle()
	var step := velocity_vec * delta
	traveled += step.length()
	var col := move_and_collide(step)
	if col:
		var hit := col.get_collider()
		if hit != null and hit.is_in_group("player") and hit.has_method("take_hit"):
			hit.take_hit(global_position, damage)
		queue_free()
		return
	if traveled >= max_range:
		queue_free()
		return
	_wrap()
