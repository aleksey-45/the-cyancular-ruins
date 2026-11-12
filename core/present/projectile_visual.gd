class_name ProjectileVisual
extends Sprite2D

const SHEET := preload("res://assets/textures/bullets.png")
const TileHitFx := preload("res://scenes/effects/tile_hit_fx.gd")
const EXPLOSION_SCENE := preload("res://scenes/effects/explosion.tscn")
const PREVIEW_SECONDS := 0.5

var type_id: int
var _sample_tick := -1
var _from := Vector2.ZERO
var _position := Vector2.ZERO
var _rendered := Vector2.ZERO
var _velocity := Vector2.ZERO
var _interval := 0.0
var _age := 0.0
var _rewinding := false
var _preview_gravity := 0.0
var _preview_range := 0.0
var _bullet: BulletBody
var _terrain: Terrain
var _player: Player

func configure(terrain: Terrain, id: int, size: float) -> void:
	_terrain = terrain
	type_id = id
	var spec := WeaponRegistry.projectile_definition(id)
	texture = SHEET
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	region_enabled = true
	region_rect = spec["projectile_region"]
	scale = Vector2.ONE * size

func follow(bullet: BulletBody, player: Player) -> void:
	_bullet = bullet
	_player = player
	global_position = bullet.global_position

func _ready() -> void:
	set_process(_bullet != null)
	if Settings.pvp_show_trajectories:
		BulletTrail.attach(self, modulate)

func _process(_delta: float) -> void:
	global_position = GridPathfinder.anchor_to_nearest(_bullet.global_position, _player.global_position, _terrain.map_size)
	rotation = _bullet.rotation

func sample(tick: int, pos: Vector2, vel: Vector2, rewinding: bool) -> void:
	if _preview_range > 0.0:
		_preview_range = 0.0
	elif tick == _sample_tick and pos == _position and vel == _velocity and rewinding == _rewinding:
		return
	if _sample_tick < 0:
		_rendered = pos
	_from = pos if rewinding != _rewinding else _rendered
	_interval = clampf(tick - _sample_tick, 1.0, 3.0) / 60.0
	_position = pos
	_velocity = vel
	_sample_tick = tick
	_age = 0.0
	_rewinding = rewinding
	if vel != Vector2.ZERO:
		rotation = vel.angle()

func start_preview(tick: int, pos: Vector2, vel: Vector2, spec: Dictionary) -> void:
	sample(tick, pos, vel, false)
	_preview_gravity = spec["gravity"]
	_preview_range = spec["range"]

func present_preview(delta: float, anchor: Vector2) -> bool:
	_age += delta
	_velocity = ShotRules.flight_velocity(_terrain, _rendered, _velocity, _preview_gravity, delta)
	var motion := _velocity * delta
	_preview_range -= motion.length()
	_rendered += motion
	rotation = _velocity.angle()
	_place_at_rendered(anchor)
	return _preview_range > 0.0 and _age < PREVIEW_SECONDS

func present(delta: float, anchor: Vector2) -> void:
	_age += delta
	var movement := GridPathfinder.toroidal_delta_px(_from, _position, _terrain.map_size)
	_rendered = _position if movement.length_squared() > 256.0 * 256.0 \
			else _from + movement * minf(_age / _interval, 1.0)
	if not _rewinding:
		_rendered += _velocity * clampf(_age - _interval, 0.0, 2.0 / 60.0)
	_place_at_rendered(anchor)

func _place_at_rendered(anchor: Vector2) -> void:
	global_position = GridPathfinder.anchor_to_nearest(_rendered, anchor, _terrain.map_size)

static func explosion(viewport: Viewport, pos: Vector2, player: Player, radius: float, terrain: Terrain) -> void:
	var anchor := player.global_position
	var shown := GridPathfinder.anchor_to_nearest(pos, anchor, terrain.map_size)
	var fx: Node2D = EXPLOSION_SCENE.instantiate()
	fx.position = shown
	viewport.add_child(fx)
	TileHitFx.spawn_explosion(viewport, terrain, shown, radius)
	var distance := shown.distance_to(anchor)
	var reach := maxf(radius * 2.5, 400.0)
	var camera := viewport.get_camera_2d()
	if distance <= reach and camera != null:
		camera.shake(PlayerParams.explosion_cam_shake * (1.0 - distance / reach),
				PlayerParams.explosion_cam_shake_time)

static func circle_texture(size: int) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var cx := size * 0.5
	for y in range(size):
		for x in range(size):
			var d := Vector2(x - cx, y - cx).length() / cx
			if d <= 1.0:
				img.set_pixel(x, y, Color(1, 1, 1, (1.0 - d) * 0.9))
	return ImageTexture.create_from_image(img)
