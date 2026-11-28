class_name SoloLevel
extends MatchController

const INTRO_VIEW := preload("res://scenes/match_view.tscn")

var session: MatchHost
var spec: WorldSpec
var preview_minute := -1.0
var _recording_path: String
var _skip_intro := false
var _intro: RunIntro
var _saved_death := false

static func create(document: Dictionary, spawn: Vector2i, weapons: Array[int], recording_path := RunIntro.PATH) -> SoloLevel:
	var scene: PackedScene = load("res://scenes/level_0.tscn")
	var level: SoloLevel = scene.instantiate()
	level.spec = WorldSpec.solo(document, spawn, weapons, randi())
	level._recording_path = recording_path
	return level

func _enter_tree() -> void:
	session = MatchHost.new(spec, spec.roles[0])
	_bind(session.world, spec.roles[0])

func _physics_process(delta: float) -> void:
	if not get_tree().paused:
		_step(_sample_input(delta))

func _step(input: Array) -> void:
	session.fixed_step({role: input})
	_presenter.accept({"current": world.sample()})

func _ready() -> void:
	_mount_session()
	_view.pause.toggled.connect(_set_pause)
	_begin_run(false)

func _process(delta: float) -> void:
	var paused := get_tree().paused
	var frame := _present(0.0 if paused else delta, delta)
	if paused: return
	var downed := _presenter.frame.downed
	if _intro and (not downed or not _saved_death):
		_intro.append(frame)
		_saved_death = downed
		if downed:
			_intro.save(_recording_path)
	# 在画出并保存倒地帧后响应重开，包括同一帧里按下的 R。
	if downed and Input.is_action_just_pressed(&"R"):
		Input.action_release(&"R")
		_begin_run(true)

func _input(event: InputEvent) -> void:
	get_viewport().set_input_as_handled()
	if event.is_action_pressed(&"ui_cancel") or (event is InputEventKey
			and event.physical_keycode == KEY_SPACE and event.pressed):
		_skip_intro = true

func _begin_run(restart: bool) -> void:
	set_process_input(true)
	set_physics_process(false)
	set_process(false)
	_intro = null
	if not _recording_path.is_empty():
		var loading := LoadingScreen.find(get_tree())
		if loading != null and loading.is_loading():
			await loading.tree_exited
		var previous := RunIntro.load_pending(_recording_path)
		if previous:
			await _play_intro(previous)
			DirAccess.remove_absolute(_recording_path)
	if restart:
		controls = LocalInputSource.new()
		session.enqueue(MatchWorld.Command.RESTART)
		session.fixed_step({role: ActorInput.neutral()})
	_start_presentation({"current": world.sample()})
	_presenter.preview_minute = preview_minute
	if not _recording_path.is_empty():
		_intro = RunIntro.new(spec.map, _view.textures)
		_saved_death = false
		_intro.append(_present(0.0, 0.0))
		await get_tree().process_frame
		for action in InputMap.get_actions():
			Input.action_release(action)
	set_process_input(false)
	set_process(true)
	set_physics_process(true)

func _play_intro(intro: RunIntro) -> void:
	_view.set_battle_visible(false)
	var replay: MatchView = INTRO_VIEW.instantiate()
	replay.name = "PreviousRun"
	replay.get_node("WorldViewport").world_2d = World2D.new()
	add_child(replay)
	replay.mount(intro.map, WorldSpec.SOLO, true, false)
	replay.textures = intro.textures
	replay.pause.set_process_unhandled_input(false)
	var hint := UiDesign.label("Esc / 空格 跳过", 28)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hint.add_theme_constant_override("outline_size", 6)
	UiDesign.place(replay.feedback, hint, Rect2(-252, -70, 224, 44), Vector2.ONE)
	_skip_intro = false
	var start := Time.get_ticks_usec()
	var elapsed := 0.0
	var duration := intro.duration()
	var shown: DrawFrame
	while not _skip_intro and elapsed < duration:
		var fade := smoothstep(0.0, 0.1, elapsed) * smoothstep(0.0, 0.12, duration - elapsed)
		replay.post.set_intro_rewind(elapsed, fade * lerpf(0.35, 1.0, elapsed / duration))
		var frame := intro.frame_at(elapsed)
		if frame != shown:
			replay.draw_frame(frame)
			shown = frame
		await get_tree().process_frame
		elapsed = (Time.get_ticks_usec() - start) / 1000000.0
	remove_child(replay)
	replay.queue_free()
	_view.set_battle_visible(true)

func _set_pause(open: bool) -> void:
	controls.frozen = open
	get_tree().paused = open

func _save_intro() -> void:
	if _intro and not _saved_death:
		_intro.save(_recording_path)

func _leave_match() -> void:
	_save_intro()
	get_tree().paused = false
	super()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_save_intro()
