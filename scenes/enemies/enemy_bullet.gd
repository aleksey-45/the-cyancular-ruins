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
	if d.is_empty():
		return
	damage = int(d.get("emd", damage))
	water_mult = float(d.get("ewm", water_mult))


func _physics_process(delta: float) -> void:
	# 物理步进受时间场倍率调节（加速状态下敌方子弹相对减速，回溯状态下冻结）
	delta = TimeField.bullet_delta(delta, self)
	if TimeField.current != null and TimeField.current.is_rewinding():
		return
	velocity_vec.y += GameParameters.gravity0 * gravity_factor * delta
	rotation = velocity_vec.angle()
	_apply_water_drag(delta)
	var step := velocity_vec * delta
	traveled += step.length()
	var col := move_and_collide(step)
	if col:
		var hit := col.get_collider()
		# 客户端视觉副本仅做飞行与消失表现，伤害由服务端权威判定
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

# 多人对战权威端约束在规范坐标区间内，单人模式与客户端锚定至就近副本
func _wrap() -> void:
	if get_tree().get_nodes_in_group("player").size() >= 2:
		global_position = MazeGenerator.wrap_to_range(global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		return
	super._wrap()
