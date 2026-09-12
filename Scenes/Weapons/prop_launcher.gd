extends WeaponBase

# 道具发射器基座(击退炮/吸力炮/烟雾弹共用):把卡参数灌进投掷物。
# 行为全部由 BulletBase 的新字段承担(blast_force 无伤冲击 / smoke_duration 烟雾区),
# 本脚本只负责"按卡生成投掷物"。每命携带数 = mag_size(prop_no_reload=true,不可换弹,
# 复活由 restart_at / MatchHost._respawn_player 经 refill_all 回满)。

@export var blast_force := 2600.0     # >0 推 / <0 吸;0 = 无(烟雾弹)
@export var blast_radius := 260.0     # 作用半径
@export var smoke_duration := 0.0     # >0 = 烟雾(持续秒)
@export var fuse_time := 0.5          # 首次碰撞后延迟起效(秒)
@export var explosion_visual: PackedScene = null   # 起效视效(击退/吸引用爆炸特效;烟雾用烟区)


func _spawn_projectiles(base_dir: Vector2) -> void:
	var spread := deg_to_rad(spread_deg)
	for i in range(pellet_count):
		var b: BulletBase = bullet_scene.instantiate()
		var ang := base_dir.angle() + randf_range(-spread, spread)
		b.setup(Vector2.from_angle(ang), bullet_speed, bullet_range, bullet_size, bullet_color, self)
		b.shooter = player
		b.gravity_factor = bullet_gravity
		b.hit_damage = 0
		b.hit_impact = 0.0
		b.explodes = true
		b.direct_hit_damage = 0
		b.blast_force = blast_force
		b.smoke_duration = smoke_duration
		b.explosion_radius = blast_radius
		b.explosion_damage = 0
		b.explosion_knockback = 0
		b.fuse_time = fuse_time
		b.hit_fuse_time = 0.15
		b.explosion_visual = explosion_visual
		b.apply_damage = not Level0.pvp_mode
		# 出生位置 = 枪口:漏了这行投掷物会出生在世界原点(0,0),远处凭空爆炸(实测事故)
		b.global_position = muzzle.global_position
		b.set_meta("scene_path", bullet_scene.resource_path)
		get_viewport().add_child(b)
	_throw_anim()


## 掷出动画:罐体向瞄准方向一送再回位(区别于枪械后坐的向后缩)
func _throw_anim() -> void:
	if sprite == null:
		return
	sprite.position = _base_sprite_pos + Vector2(7.0, -3.0)
	var tw := sprite.create_tween()
	tw.tween_property(sprite, "position", _base_sprite_pos, 0.22) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
