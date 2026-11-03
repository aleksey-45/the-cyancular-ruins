class_name EnemyBullet
extends BulletBase

# 敌方投弹:由发射者给定初速向量与重力倍率,重力抛物线飞行,命中玩家造成 damage。
# 场景 collision_mask=1(只撞地形):打玩家走 hurt_rect 线段扫掠(见 _physics_process),不再靠物理碰撞层。
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


# 时间回溯状态:除基类那些,再带上 launch() 给的本类字段(重建后伤害/水中加成不能丢)。
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
	# 时间场(B13):加速 = 主角时间被加快 ⇒ **除主角外一切实体变慢**,敌方弹也不例外
	delta = TimeField.bullet_delta(delta, self)
	if TimeField.current != null and TimeField.current.is_rewinding():
		return
	prev_pos = global_position
	velocity_vec.y += GameParameters.gravity0 * gravity_factor * delta
	rotation = velocity_vec.angle()
	_apply_water_drag(delta)
	var step := velocity_vec * delta
	traveled += step.length()
	var from := global_position
	var col := move_and_collide(step)
	var to := global_position
	var t_wall := 1.0
	if col != null:
		to = from + col.get_travel()
		var lens := step.length()
		t_wall = (col.get_travel().length() / lens) if lens > 0.0 else 0.0
	var hit := first_hurt_on_segment(from, to, ["player"])
	if not hit.is_empty() and float(hit["t"]) <= t_wall:
		global_position = from + (to - from) * float(hit["t"])
		# 视觉副本(apply_damage=false):只飞,碰到目标直接消失,不裁决伤害(伤害服务器裁决)。
		if apply_damage:
			var victim := hit["node"] as Node
			var victim2 := victim as Node2D
			if victim != null and victim.has_method("take_hit"):
				var dmg: int = damage
				if water_mult > 1.0 and victim2 != null and Water.sample_body(victim2, false).in_water:
					dmg = roundi(damage * water_mult)
				victim.take_hit(global_position, dmg)
		queue_free()
		return
	if col != null:
		queue_free()
		return
	if traveled >= max_range:
		queue_free()
		return
	_wrap()
	# 环面 wrap 会把 global_position 整幅平移;扫掠起点跟着平移,下一帧的线段才不横穿整图。
	prev_pos = from + (global_position - to)

# 服务器权威世界有 2 玩家且敌方子弹无射手 → 位置存 canonical(别锚到某个玩家副本漂走);
# 单机/客户端(=1 玩家)回落 BulletBase:锚本地玩家副本渲染,接缝不消失。
func _wrap() -> void:
	if get_tree().get_nodes_in_group("player").size() >= 2:
		global_position = MazeGenerator.wrap_to_range(global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		return
	super._wrap()
