class_name EnemyBullet
extends BulletBase

# 敌方投弹:由发射者给定初速向量与重力倍率,重力抛物线飞行,命中玩家造成 damage。
# 场景 collision_mask=3(层1地形+层2玩家),不含层3 → 不撞自己/其他敌人。
var damage: int = 2
var water_mult: float = 1.0  # FlyBird 子弹独有:攻击水里的玩家伤害 ×1.5


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
	_apply_water_drag(delta)
	var step := velocity_vec * delta
	traveled += step.length()
	var col := move_and_collide(step)
	if col:
		var hit := col.get_collider()
		# 视觉副本(apply_damage=false):只飞,碰到目标直接消失,不裁决伤害(伤害服务器裁决)。
		if apply_damage and hit != null and hit.is_in_group("player") and hit.has_method("take_hit"):
			var dmg: int = damage
			if water_mult > 1.0 and Water.is_in_water((hit as Node2D).global_position):
				dmg = roundi(damage * water_mult)
			hit.take_hit(global_position, dmg)
		queue_free()
		return
	if traveled >= max_range:
		queue_free()
		return
	_wrap()

# 服务器权威世界有 2 玩家且敌方子弹无射手 → 位置存 canonical(别锚到某个玩家副本漂走);
# 单机/客户端(=1 玩家)回落 BulletBase:锚本地玩家副本渲染,接缝不消失。
func _wrap() -> void:
	if get_tree().get_nodes_in_group("player").size() >= 2:
		global_position = MazeGenerator.wrap_to_range(global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		return
	super._wrap()
