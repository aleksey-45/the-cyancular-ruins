class_name EnemyBullet
extends BulletBase

# 敌方投弹实体：受重力影响沿抛物线飞行，命中玩家后结算伤害。
# 场景 collision_mask=3（层 1 地形 + 层 2 玩家），不含层 3 敌人，避免碰撞自身或其他敌人。
var damage: int = 2
var water_mult: float = 1.0  # 针对水下玩家的额外伤害倍率


# 初始化投掷初速度向量与相关物理参数
func launch(vel: Vector2, rng: float, dmg: int, grav: float, siz: float = 1.0) -> void:
	velocity_vec = vel
	speed = vel.length()
	max_range = rng
	damage = dmg
	gravity_factor = grav
	size = siz
	rotation = vel.angle()
	scale = Vector2(size, size)


# 时间回溯状态保存
func rewind_state() -> Dictionary:
	var d := super()
	d["emd"] = damage
	d["ewm"] = water_mult
	return d


func apply_rewind_state(d: Dictionary) -> void:
	super(d)
	damage = d["emd"]
	water_mult = d["ewm"]


func _physics_process(delta: float) -> void:
	# 物理步进受时间场倍率调节（加速状态下敌方子弹相对减速，回溯状态下冻结）
	delta = TimeField.bullet_delta(delta, self)
	if TimeField.current != null and TimeField.current.is_rewinding():
		return
	var result := advance_physics(delta)
	present_projection()
	match result:
		BulletBody.AdvanceResult.ACTOR_HIT:
			var hit: Node = impact_node()
			# 客户端视觉副本仅做飞行与消失表现，伤害由服务端权威判定。
			if apply_damage and hit is Player:
				var target := hit as Player
				var dmg := damage
				if water_mult > 1.0 and Water.is_in_water(target.global_position):
					dmg = roundi(damage * water_mult)
				target.take_hit(global_position, dmg)
			queue_free()
		BulletBody.AdvanceResult.TERRAIN_HIT, BulletBody.AdvanceResult.RANGE_END, BulletBody.AdvanceResult.FUSE_END:
			queue_free()
