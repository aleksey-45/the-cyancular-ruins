class_name SoloLevel
extends MatchController

const INTRO_VIEW := preload("res://scenes/match_view.tscn")

var session: MatchHost
var spec: WorldSpec
var preview_minute := -1.0
var _intro_enabled := false
var _opening := false
var _skip_intro := false
var _replay: MatchView

static func create(document: Dictionary, spawn: Vector2i, weapons: Array[int], with_intro := false) -> SoloLevel:
	var scene: PackedScene = load("res://scenes/level_0.tscn")
	var level: SoloLevel = scene.instantiate()
	level.spec = WorldSpec.solo(document, spawn, weapons, randi())
	level._intro_enabled = with_intro and DisplayServer.get_name() != "headless"
	return level

func _enter_tree() -> void:
	session = MatchHost.new(spec, spec.roles[0])
	_bind(session.world, spec.roles[0])

func _physics_process(delta: float) -> void:
	_step(_sample_input(delta))

func _step(input: Array) -> void:
	session.fixed_step({role: input})
	_sampler.accept_local(world.sample())

func _ready() -> void:
	_mount_session()
	_reset_sampler()
	_sampler.accept_local(world.sample())
	_view.pause.toggled.connect(_set_pause)
	_presenter.preview_minute = preview_minute
	if _intro_enabled:
		_opening = true
		set_physics_process(false)
		set_process(false)
		var loading := LoadingScreen.find(get_tree())
		if loading != null and loading.is_loading():
			await loading.tree_exited
		_begin_attempt(false)

func _input(event: InputEvent) -> void:
	if _opening:
		get_viewport().set_input_as_handled()
		if _replay != null and (event.is_action_pressed(&"ui_cancel") or (event is InputEventKey
				and event.physical_keycode == KEY_SPACE and event.pressed)):
			_skip_intro = true
		return
	if not player.sim_downed or not event.is_action_pressed(&"R"):
		return
	get_viewport().set_input_as_handled()
	Input.action_release(&"R")
	if not _intro_enabled:
		restart_single()
		return
	_opening = true
	set_physics_process(false)
	# 当前帧先呈现倒地画面并存档。
	await RenderingServer.frame_post_draw
	set_process(false)
	_view.end_intro_capture()
	_begin_attempt(true)

func _begin_attempt(retry: bool) -> void:
	var intro := RunIntro.load_pending()
	if intro != null:
		await _play_intro(intro)
	if retry:
		restart_single()
		_step(ActorInput.neutral())
		_camera.reset_follow()
	_view.begin_intro_capture(spec.map)
	set_process(true)
	# 摄像机和画布先显示出生时的状态，下一帧再推进模拟。
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	for action in InputMap.get_actions():
		Input.action_release(action)
	set_physics_process(true)
	_opening = false

func _play_intro(intro: RunIntro) -> void:
	_view.set_battle_visible(false)
	_replay = INTRO_VIEW.instantiate()
	_replay.get_node("WorldViewport").world_2d = World2D.new()
	add_child(_replay)
	_replay.mount_intro(intro)
	var textures := intro.load_textures()
	_skip_intro = false
	var start := Time.get_ticks_usec()
	var elapsed := 0.0
	var duration := intro.duration()
	var shown := -1
	while not _skip_intro and elapsed < duration:
		_replay.present_intro_effect(elapsed, duration)
		var index := intro.frame_index(elapsed)
		if index != shown:
			_replay.show_intro_frame(intro.frames[index], textures)
			shown = index
		await get_tree().process_frame
		elapsed = (Time.get_ticks_usec() - start) / 1000000.0
	remove_child(_replay)
	_replay.queue_free()
	_replay = null
	_view.set_battle_visible(true)
	DirAccess.remove_absolute(RunIntro.PATH)

func _set_pause(open: bool) -> void:
	if open:
		_view.capture_intro_frame(true)
	controls.frozen = open
	get_tree().paused = open

func _leave_match() -> void:
	_view.end_intro_capture(true)
	get_tree().paused = false
	super()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_view.end_intro_capture(true)

func restart_single() -> void:
	controls = LocalInputSource.new()
	session.enqueue(MatchWorld.Command.RESTART)
