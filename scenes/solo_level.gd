class_name SoloLevel
extends MatchController

var spec: WorldSpec
var preview_minute := -1.0

static func create(document: Dictionary, spawn: Vector2i, weapons: Array[int]) -> SoloLevel:
	var scene: PackedScene = load("res://scenes/level_0.tscn")
	var level: SoloLevel = scene.instantiate()
	level.spec = WorldSpec.solo(document, spawn, weapons, randi())
	return level

func _enter_tree() -> void:
	session = MatchSession.open_local(spec, 1)
	super()

func _ready() -> void:
	_mount_session()
	_presenter.preview_minute = preview_minute

func _input(event: InputEvent) -> void:
	var recorder: Node = get_node_or_null("View/Recorder")
	if recorder != null:
		if recorder.is_replaying():
			return
		if event.is_action_pressed(&"R") and recorder.start_rewind():
			get_viewport().set_input_as_handled()
			return
	var reversing := session.world.death_rewind_end >= 0.0
	if not reversing and (not player.sim_downed or not event.is_action_pressed(&"R")):
		return
	get_viewport().set_input_as_handled()
	if not event.is_pressed():
		return
	for action in InputMap.get_actions():
		if event.is_action(action):
			Input.action_release(action)
	if event.is_echo():
		return
	if not reversing:
		session.enqueue(MatchWorld.Command.DEATH_REWIND)
	elif event.is_action_pressed(&"R") or event.is_action_pressed(&"ui_cancel") \
			or (event is InputEventKey and (event.keycode == KEY_SPACE or event.physical_keycode == KEY_SPACE)) \
			or (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT):
		session.enqueue(MatchWorld.Command.SKIP_REWIND)

func restart_single() -> void:
	controls = LocalInputSource.new()
	session.enqueue(MatchWorld.Command.RESTART)
