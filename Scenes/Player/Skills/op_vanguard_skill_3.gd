extends SkillBase

# 空投补给:在头顶呼叫补给箱(受重力下落、可被地形卡住),
# 任意玩家靠近拾取:恢复 30 点生命并清空换弹状态(当前武器弹夹回满、中断换弹)。

const HEAL := 30

func _activate() -> bool:
	var crate := SupplyCrate.new()
	crate.heal = HEAL
	crate.position = player.global_position + Vector2(0, -240)   # 头顶高空坠落
	player.get_parent().add_child(crate)   # 挂对局世界(Level0 子级,随世界坐标系)
	return true


# 程序化像素补给箱:橄榄绿箱体 + 红十字,受重力下落、落地停留 12s、靠近拾取
class SupplyCrate:
	extends CharacterBody2D

	const FALL_G := 980.0
	const PICKUP_DIST := 56.0

	var heal := 30
	var _life := 12.0
	var _vel := Vector2.ZERO

	func _ready() -> void:
		collision_layer = 0
		collision_mask = 1   # 只碰地形(可被地形卡住:斜坡/平台/箱顶都停)
		var shape := CollisionShape2D.new()
		var rect := RectangleShape2D.new()
		rect.size = Vector2(48, 34)
		shape.shape = rect
		add_child(shape)
		queue_redraw()

	func _draw() -> void:
		draw_rect(Rect2(-24, -17, 48, 34), Color8(96, 108, 62))          # 橄榄绿箱体
		draw_rect(Rect2(-24, -17, 48, 7), Color8(122, 134, 78))          # 顶盖亮色
		draw_rect(Rect2(-24, 10, 48, 7), Color8(76, 86, 50))             # 底部暗色
		draw_rect(Rect2(-7, -9, 14, 18), Color8(228, 232, 220))          # 白底红十字
		draw_rect(Rect2(-2, -7, 4, 14), Color8(180, 60, 50))
		draw_rect(Rect2(-7, -2, 14, 4), Color8(180, 60, 50))

	func _physics_process(delta: float) -> void:
		_life -= delta
		if _life <= 0.0:
			queue_free()
			return
		if _vel.y > 0.0 or not is_on_floor():
			_vel.y = minf(_vel.y + FALL_G * delta, 900.0)
			var col := move_and_collide(_vel * delta)
			if col != null and col.get_normal().y < -0.5:
				_vel = Vector2.ZERO   # 落地(斜面/平台/箱顶都算被地形卡住)
		# 拾取:任一存活玩家靠近
		for p in get_tree().get_nodes_in_group("player"):
			if not is_instance_valid(p) or p.is_downed():
				continue
			if p.global_position.distance_to(global_position) < PICKUP_DIST:
				_pickup(p)
				return

	func _pickup(p: Node2D) -> void:
		var combat: Node = p.get("combat")
		if combat != null:
			combat.hp = mini(int(combat.hp) + heal, int(combat.max_hp))
			if p.has_signal("hp_changed"):
				p.hp_changed.emit(int(combat.hp), int(combat.max_hp))
		var wpn: Node = p.get("weapons")
		if wpn != null and wpn.current_weapon() != null:
			wpn.current_weapon().set_net_reload(wpn.current_weapon().mag_size, false)   # 清空换弹状态
		Sfx.play("switch")
		queue_redraw()
		# 拾取后短暂停留展示,再消失
		var t := get_tree().create_timer(0.2).timeout
		t.connect(func() -> void: queue_free())
