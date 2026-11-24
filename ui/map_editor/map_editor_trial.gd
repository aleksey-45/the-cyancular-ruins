class_name MapEditorTrial
extends Node

var session: MapEditSession
var canvas: MapEditCanvas
var workspace: Control
var say: Callable

var trial: SoloLevel

func setup(p_session: MapEditSession, p_canvas: MapEditCanvas, p_workspace: Control, p_say: Callable) -> void:
	session = p_session
	canvas = p_canvas
	workspace = p_workspace
	say = p_say

func active() -> bool:
	return trial != null

func start(cell: Vector2i = session.selected_point().get("cell", SpawnPicker.NO_CELL)) -> void:
	if trial != null:
		return
	var map := session.map
	var spawn := cell if session.bounds.has_point(cell) else SpawnPicker.single_spawn(map)
	if spawn == SpawnPicker.NO_CELL:
		say.call("地图没有可用起点")
		return
	trial = SoloLevel.create(map, spawn, WeaponRegistry.enabled_ids([]))
	trial.preview_minute = canvas.preview_minute
	canvas.cancel()
	workspace.hide()
	add_child(trial)
	var hint := CanvasLayer.new()
	hint.layer = 160
	trial.add_child(hint)
	var text := UiFactory.label("试玩    Esc 返回地图编辑器", 28)
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	text.add_theme_constant_override("outline_size", 5)
	hint.add_child(text)
	text.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	text.offset_top = -66
	text.offset_bottom = -22

func finish() -> void:
	if trial == null:
		return
	get_tree().paused = false
	remove_child(trial)
	trial.queue_free()
	trial = null
	workspace.show()
	canvas.grab_focus()
	say.call("已返回编辑现场")

func validate() -> void:
	var map := session.map
	var problem := SpawnPicker.validate_multiplayer_spawns(map)
	var solo := SpawnPicker.single_spawn(map)
	var sides := SpawnPicker.respawn_cells(map)
	var summary := "侧 1 / 侧 2：%d / %d" % [sides[1].size(), sides[2].size()]
	if problem.is_empty():
		for mode: String in PvpSession.MODE_NAMES:
			var limit := SpawnPicker.player_limit(sides, mode)
			var label := "点位不足"
			if mode == PvpSession.MODE_ROYALE:
				label = "最多 %d 人" % limit if limit else "点位不足，至少需要 %d 人" % RoomOptions.MIN_PLAYERS
			elif limit: label = "通过"
			summary += "    %s：%s" % [PvpSession.mode_name(mode), label]
	else:
		summary += "    " + problem
	say.call("单人：%s    %s" % ["无起点" if solo == SpawnPicker.NO_CELL else str(solo), summary])
