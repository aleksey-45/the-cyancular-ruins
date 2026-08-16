class_name PlayerGun
extends Node2D

const BULLET_SCENE: PackedScene = preload("res://Scenes/Bullet.tscn")

@onready var sprite: Sprite2D = $Sprite2D
@onready var muzzle: Marker2D = $Muzzle

var player: Node2D
var fire_cd_timer: float = 0.0
var _recoil_timer: float = 0.0
var _base_sprite_pos: Vector2 = Vector2.ZERO

# 俯仰角:把面向折进 dir.x,相对水平线求角并钳制到 ±45°。
static func clamp_pitch(dir: Vector2, facing: int) -> float:
	var local := Vector2(dir.x * float(facing), dir.y)
	var limit := deg_to_rad(GameParameters.aim_pitch_deg)
	return clampf(local.angle(), -limit, limit)

func _ready() -> void:
	player = get_parent() as Node2D
	_base_sprite_pos = sprite.position

func _process(delta: float) -> void:
	if player != null and player.has_method("is_downed") and player.is_downed():
		return
	fire_cd_timer = maxf(fire_cd_timer - delta, 0.0)
	var facing: int = 1
	if player != null and player.has_method("get_facing"):
		facing = player.get_facing()
	# 自动帮助角色转向:鼠标在玩家哪一侧就朝哪侧(玩家零输入时生效)
	var dir := _aim_world_dir()
	if player != null and player.has_method("set_facing") and absf(dir.x) > 0.1:
		player.set_facing(1 if dir.x > 0.0 else -1)
		facing = player.get_facing()
	# 朝向镜像(scale.x=-1)会翻转旋转方向。clamp_pitch 已按 facing 折叠 dir.x,
	# 返回值乘 facing 取反:朝左时镜像后的枪口才指向正确的俯仰象限。
	rotation = clamp_pitch(dir, facing) * float(facing)
	scale.x = float(facing)
	if _recoil_timer > 0.0:
		_recoil_timer = maxf(_recoil_timer - delta, 0.0)
		sprite.position = _base_sprite_pos - Vector2(1.0, 0.0) * GameParameters.recoil_kick * (_recoil_timer / GameParameters.recoil_time)
		if _recoil_timer == 0.0:
			sprite.position = _base_sprite_pos

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("attack"):
		fire()

func fire() -> void:
	if fire_cd_timer > 0.0:
		return
	if player != null and player.has_method("is_downed") and player.is_downed():
		return
	fire_cd_timer = GameParameters.fire_cooldown
	var dir := _aim_world_dir()
	var b: Bullet = BULLET_SCENE.instantiate()
	b.setup(dir, GameParameters.bullet_speed, GameParameters.bullet_range, GameParameters.bullet_damage)
	b.global_position = muzzle.global_position
	get_parent().get_parent().add_child(b)  # 加入 WorldViewport
	_recoil_timer = GameParameters.recoil_time
	sprite.position = _base_sprite_pos - Vector2(1.0, 0.0) * GameParameters.recoil_kick
	var cam: Camera2D = get_viewport().get_camera_2d()
	if cam != null and cam.has_method("shake"):
		cam.shake(GameParameters.cam_shake, GameParameters.cam_shake_time)

# 世界坐标系下从玩家指向鼠标的单位向量(未钳制俯仰)。
func _aim_world_dir() -> Vector2:
	var cam: Camera2D = get_viewport().get_camera_2d()
	var sub: SubViewport = get_viewport()
	if cam == null or sub == null:
		return Vector2(float(get_facing()), 0.0)
	var win: Viewport = sub.get_window()
	if win == null:
		return Vector2(float(get_facing()), 0.0)
	# 窗口鼠标 -> 世界坐标。鼠标用根 Window 的真实坐标(SubViewport 的
	# get_mouse_position 是被 push 进去的窗口坐标,不能直接用)。
	# 相机把屏幕中心映射到 cam.global_position,故 world_mouse =
	# cam.global_position + (鼠标 - 窗口中心) / crop。
	var win_size := win.get_visible_rect().size
	var mouse := win.get_mouse_position()
	var crop := Vector2(win_size.x / sub.size.x, win_size.y / sub.size.y)
	var world_mouse := cam.global_position + (mouse - win_size * 0.5) / crop
	var dir := world_mouse - (get_parent() as Node2D).global_position
	if dir.length_squared() < 0.0001:
		return Vector2(float(get_facing()), 0.0)
	return dir.normalized()

func get_facing() -> int:
	if player != null and player.has_method("get_facing"):
		return player.get_facing()
	return 1
