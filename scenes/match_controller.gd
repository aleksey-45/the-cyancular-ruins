class_name MatchController
extends Node2D

const CFG: PlayerConfig = preload("res://core/config/player_config.tres")

var world: MatchWorld
var role: int
var controls := LocalInputSource.new()
var player: Player:
	get: return world.players[role]
var terrain: Terrain:
	get: return world.terrain
var _world := WorldView.new()
var _sampler: MatchSampler
var _presenter: MatchPresenter
var _render_time := 0.0
@onready var _view: MatchView = $View
@onready var _camera: MatchCamera = _view.camera

func _bind(simulation: MatchWorld, observing_role: int) -> void:
	world = simulation
	role = observing_role
	$View/WorldViewport.world_2d = terrain.physics.world

func _mount_session(radar := false) -> void:
	_presenter = MatchPresenter.new(world.spec, terrain, role, world.time_account(role))
	var frame := _presenter.frame
	_view.mount(_world, world.spec.map, frame.mode, frame.clock, radar)
	_view.pause.leave_requested.connect(_leave_match)

func _reset_sampler() -> void:
	_sampler = MatchSampler.new(terrain.map_size, role)
	_presenter.reset()
	_world.reset()

func _sample_input(delta: float) -> Array:
	return controls.sample(player, delta, _aim_direction())

func _process(delta: float) -> void:
	_render_time += delta
	var sample := _sampler.sample(_render_time, Engine.get_physics_interpolation_fraction())
	var frame := _presenter.compose(sample, _render_time, controls.drop_hold_progress(), terrain.take_wall_changes())
	var own: Array = sample["local"]
	var speed_x: float = own[PlayerStateSchema.VEL].x + own[PlayerStateSchema.KNOCK_VEL].x
	_camera.advance(delta, frame.focus, terrain.map_size, -speed_x if frame.clock != null and frame.clock.rewind else speed_x)
	_view.present(delta, frame)

func _aim_direction() -> Vector2:
	var window := get_window()
	var offset := window.get_mouse_position() - window.get_visible_rect().size * 0.5
	return LocalInputSource.aim_direction(player.position, player.facing_direction, terrain.map_size,
			_camera.base_position, CFG.cam_zoom, offset)

func _unhandled_input(event: InputEvent) -> void:
	controls.handle_event(event)

func _leave_match() -> void:
	SceneTransition.change(get_tree(), "res://scenes/main_menu.tscn")

func _exit_tree() -> void:
	world.close()
