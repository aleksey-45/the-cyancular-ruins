class_name MatchController
extends Node2D

const CFG: PlayerConfig = preload("res://core/config/player_config.tres")
const Mode := MatchFrame.Mode

var session: MatchSession
var controls := LocalInputSource.new()
var player: Player:
	get: return session.world.players[session.role]
var terrain: Terrain:
	get: return session.world.terrain
var _world := WorldView.new()
var _sampler: MatchSampler
var _presenter: MatchPresenter
var _pause_open := false
var _render_time := 0.0
@onready var _view: MatchView = $View
@onready var _camera: MatchCamera = _view.camera

func _enter_tree() -> void:
	$View/WorldViewport.world_2d = terrain.physics.world

func _mount_session() -> void:
	var account: GrainAccount
	if session.world.world_time != null:
		account = session.world.world_time.account
	elif session.world.personal_time != null:
		account = session.world.personal_time.accounts[session.role]
	_presenter = MatchPresenter.new(session.world.spec, terrain, session.role, account)
	var frame := _presenter.frame
	_view.mount(_world, session.world.spec.map, frame.mode, frame.clock, session.remote and Settings.pvp_show_minimap)
	_view.pause.toggled.connect(_set_pause)
	_view.pause.leave_requested.connect(_leave_match)
	_reset_sampler()

func _reset_sampler() -> void:
	_sampler = MatchSampler.new(terrain.map_size, session.role)
	var update := session.initial_view()
	if session.remote:
		update["authority"] = session.latest_authority
	_sampler.accept(update)
	_presenter.reset()
	_world.reset()

func _physics_process(delta: float) -> void:
	var record := controls.complete(player, controls.sample(), delta, _aim_direction())
	var updated := session.fixed_step({session.role: record}, NetBus.ping_ms if session.remote else 0)
	if session.remote:
		NetBus.send_input(session.outgoing_input)
	_sampler.accept(updated)

func _process(delta: float) -> void:
	var started := PerformanceStats.begin()
	_render_time += delta
	var sample := _sampler.sample(_render_time, Engine.get_physics_interpolation_fraction())
	var local_view := {"drop": controls.drop_hold_progress(), "walls": terrain.take_wall_changes()}
	var frame := _presenter.compose(sample, _render_time, local_view)
	var own: Array = sample["local"]
	var speed_x: float = own[PlayerStateSchema.VEL].x + own[PlayerStateSchema.KNOCK_VEL].x
	_camera.advance(delta, frame.focus, terrain.map_size, -speed_x if frame.clock != null and frame.clock.rewind else speed_x)
	_view.present(delta, frame)
	if session.remote:
		PerformanceStats.end(PerformanceStats.CLIENT_PRESENT, started)

func _aim_direction() -> Vector2:
	var window := get_window()
	var offset := window.get_mouse_position() - window.get_visible_rect().size * 0.5
	return LocalInputSource.aim_direction(player.position, player.facing_direction, terrain.map_size,
			_camera.base_position, CFG.cam_zoom, offset)

func _unhandled_input(event: InputEvent) -> void:
	controls.handle_event(player, event)

func _set_pause(open: bool) -> void:
	_pause_open = open
	if not session.remote:
		controls.frozen = open
		get_tree().paused = open

func _leave_match() -> void:
	get_tree().paused = false
	if session.remote:
		NetSession.disconnect_client()
	SceneTransition.change(get_tree(), "res://scenes/main_menu.tscn")

func _exit_tree() -> void:
	if session != null:
		session.close()
