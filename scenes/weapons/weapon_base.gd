class_name WeaponBase
extends Node2D

const RECOIL_TIME: float = 0.06  # 枪口后坐复位时长（秒）
const BOB_AMOUNT: float = 1.4
const SHEET := preload("res://assets/textures/weapons.png")

var type_id := 0
var _spec: Dictionary
var _animator: AnimatedSprite2D
var _equipped: GunBody
const RELOAD_TILT := 0.9
const RELOAD_OFFSET := Vector2(-3.0, 7.0)

## 后坐力、装填与步态偏移都作用在枪身贴图上，枪口和预瞄沿用武器根节点的变换。
func _process(delta: float) -> void:
	if _recoil_timer > 0.0:
		_recoil_timer = maxf(_recoil_timer - delta, 0.0)
	var offset := _recoil_offset()
	var tilt := 0.0
	if _equipped != null and _equipped.reloading:
		var p := clampf(_equipped.reload_progress(), 0.0, 1.0)
		var k := sin(p * PI)
		var jiggle := sin(p * 34.0) * 1.2 * k
		tilt = RELOAD_TILT * k
		offset += RELOAD_OFFSET * k + Vector2(jiggle, 0.0)
	offset.y += _walk_bob()
	sprite.rotation = tilt
	sprite.position = _base_sprite_pos + offset

func _recoil_offset() -> Vector2:
	if _recoil_timer <= 0.0:
		return Vector2.ZERO
	return Vector2(-1.0, 0.0) * float(_spec.get("kick", 0.0)) * (_recoil_timer / RECOIL_TIME)

func _walk_bob() -> float:
	if _animator.animation != &"move" or not _animator.is_playing():
		return 0.0
	var frame_count := _animator.sprite_frames.get_frame_count(&"move")
	var phase := (_animator.frame + _animator.frame_progress) / frame_count
	return sin(TAU * phase) * BOB_AMOUNT

var sprite: Sprite2D


var _recoil_timer: float = 0.0
var _base_sprite_pos: Vector2 = Vector2.ZERO
var _laser: Line2D = null
var _explosion_marker: Sprite2D = null

static func make_sprite(region: Rect2) -> Sprite2D:
	var sprite_node := Sprite2D.new()
	sprite_node.texture = SHEET
	sprite_node.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite_node.region_enabled = true
	sprite_node.region_rect = region
	return sprite_node

func _ready() -> void:
	sprite = make_sprite(_spec["region"])
	_base_sprite_pos = _spec["sprite_offset"]
	sprite.position = _base_sprite_pos
	add_child(sprite)
	process_priority = 3

func configure(id: int, animator: AnimatedSprite2D) -> void:
	type_id = id
	_spec = WeaponRegistry.definition(id)
	_animator = animator

func present_equipped(actor: Player, equipped: GunBody, aim: Vector2) -> void:
	_equipped = equipped
	drive_remote_visual(aim, _equipped.shot_facing)
	_update_laser(actor, aim)

func _ensure_aim_visuals() -> void:
	if _laser != null: return
	_laser = Line2D.new()
	_laser.width = 1.0
	_laser.default_color = _spec.get("guide_color", Color(1.0, 0.2, 0.2, 0.6))
	_laser.visible = false
	add_child(_laser)
	if not _spec["projectile"]["blast"].is_empty():
		_explosion_marker = Sprite2D.new()
		_explosion_marker.texture = ProjectileVisual.circle_texture(16)
		_explosion_marker.modulate = Color(1.0, 0.4, 0.2, 0.9)
		_explosion_marker.visible = false
		add_child(_explosion_marker)

func present_shot() -> void:
	play_recoil()
	Sfx.play(_spec["shot_sound"])
	var cam := get_viewport().get_camera_2d()
	if cam != null and _spec.has("shake"):
		cam.shake(_spec["shake"], _spec.get("shake_time", 0.1))

func play_recoil() -> void:
	_recoil_timer = RECOIL_TIME

func drive_remote_visual(aim_dir: Vector2, facing: int) -> void:
	var pose := GunBody.aim_transform(aim_dir, facing, _spec["pitch"])
	pose.origin = position
	transform = pose

func _update_laser(actor: Player, aim: Vector2) -> void:
	if not _equipped.aiming or _spec["attack"] == WeaponRegistry.Attack.MELEE:
		if _laser != null: _laser.visible = false
		_update_explosion_marker(false)
		return
	_ensure_aim_visuals()
	_laser.visible = true
	if _spec.has("arc_time"):
		var muzzle := _equipped.muzzle_pose(actor, aim)
		var speed := ShotRules.launch_speed(_spec, _equipped.charge_ratio()) * actor.pvp_haste_mult
		var dt := ActorStep.DT
		if actor.time_field != null and actor.time_field.is_hasting():
			dt *= actor.time_field.player_speed_mult()
		var points := ShotRules.trace_arc(actor.terrain, muzzle.origin, muzzle.x * speed, _spec, dt, _spec["arc_time"])
		for i in points.size():
			points[i] = to_local(points[i])
		_laser.points = points
		_update_explosion_marker(not _spec["projectile"]["blast"].is_empty())
	else:
		var muzzle: Vector2 = _spec["muzzle"]
		_laser.points = PackedVector2Array([muzzle, muzzle + Vector2(600.0, 0.0)])
		_update_explosion_marker(false)

func _update_explosion_marker(show: bool) -> void:
	if _explosion_marker == null:
		return
	_explosion_marker.visible = show
	if show and _laser.points.size() > 0:
		_explosion_marker.position = _laser.points[_laser.points.size() - 1]
