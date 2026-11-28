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
var _presenter: MatchPresenter
var _radar := false
@onready var _view: MatchView = $View

func _bind(simulation: MatchWorld, observing_role: int) -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	world = simulation
	role = observing_role
	$View/WorldViewport.world_2d = terrain.physics.world

func _mount_session(radar := false) -> void:
	_radar = radar
	_view.mount(world.spec.map, world.spec.mode, world.time_account(role) != null, radar)
	_view.pause.leave_requested.connect(_leave_match)

func _start_presentation(step: Dictionary) -> void:
	_presenter = MatchPresenter.new(world.spec, terrain, role, world.time_account(role))
	_presenter.radar = _radar
	if _view.watch:
		_presenter.watch_offset = _view.watch.get_global_rect().get_center() - get_viewport_rect().size * 0.5
	_view.textures = _presenter.world.textures.items
	_presenter.accept(step)
	_presenter.camera.advance(0.0, player.position, terrain.map_size)

func _sample_input(delta: float) -> Array:
	return controls.sample(player, delta, _aim_direction())

func _present(world_delta: float, ui_delta: float) -> DrawFrame:
	var live := _presenter.advance(world_delta, ui_delta, Engine.get_physics_interpolation_fraction(), controls.drop_hold_progress())
	_view.draw_frame(live)
	Sfx.pitch_mult = _presenter.pitch
	for sound: Array in _presenter.sounds:
		Sfx.play(sound[0], 1.0, sound[1])
	return live

func _aim_direction() -> Vector2:
	var window := get_window()
	var offset := window.get_mouse_position() - window.get_visible_rect().size * 0.5
	return LocalInputSource.aim_direction(player.position, player.facing_direction, terrain.map_size,
			_presenter.camera.base_position, CFG.cam_zoom, offset)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_barrel"):
		_presenter.post.barrel = not _presenter.post.barrel
		get_viewport().set_input_as_handled()
	if not get_tree().paused:
		controls.handle_event(event)

func _leave_match() -> void:
	SceneTransition.change(get_tree(), "res://scenes/main_menu.tscn")

func _exit_tree() -> void:
	Sfx.pitch_mult = 1.0
	world.close()
