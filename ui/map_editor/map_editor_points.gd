class_name MapEditorPoints
extends VBoxContainer

signal point_selected(id: int)
signal point_activated(id: int)

const ENEMY_LABELS := {"jump_bird": "跳鸟", "fly_bird": "飞鸟", "black_bird": "乌鸫"}

var session: MapEditSession
var canvas: MapEditCanvas

var place_button := CheckBox.new()
var _type := OptionButton.new()
var _list := ItemList.new()
var _details := HBoxContainer.new()

func setup(p_session: MapEditSession, p_canvas: MapEditCanvas) -> void:
	session = p_session
	canvas = p_canvas
	_build()

func _build() -> void:
	add_theme_constant_override("separation", UiDesign.SP_2)
	place_button.text = "放置点位（连续）"
	place_button.tooltip_text = "勾选后单击画布放置所选类型，取消勾选可拖动已有点位"
	add_child(place_button)

	UiKit.label(self, "点位类型")

	_type.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_type.tooltip_text = "选择出生点、敌人或路灯"
	_type.item_selected.connect(_change_type)
	add_child(_type)
	_option("单人出生点", {"kind": "player"})
	_option("第二出生点", {"kind": "player2"})
	for side in [1, 2]:
		_option("侧 %d 复活点" % side, {"kind": "respawn", "side": side})
	for id: String in EnemyType.PATHS:
		_option("敌人 · " + str(ENEMY_LABELS.get(id, id)), {"kind": "enemy", "type": id})
	_option("路灯 · 暖白", {"kind": "lamp", "tone": "warm"})
	_option("路灯 · 冷青", {"kind": "lamp", "tone": "cool"})

	_list.custom_minimum_size.y = 270
	_list.item_selected.connect(func(index: int) -> void:
		point_selected.emit(_list.get_item_metadata(index)))
	_list.item_activated.connect(func(index: int) -> void:
		point_activated.emit(_list.get_item_metadata(index)))
	add_child(_list)

	add_child(_details)
	UiKit.button(_details, "移至…", canvas.pick_point_destination).tooltip_text = "单击目标子格移动所选点位"
	UiKit.button(_details, "删除", func() -> void: session.commit_point(session.selected_point_id, {}))

func sync() -> void:
	var placing := is_placing()
	var point := session.selected_point()
	var kind: String = point.get("kind", "")
	var editable_type := not placing and kind in ["enemy", "respawn", "lamp"]
	_details.visible = not kind.is_empty() and not placing
	if editable_type: _type.select(_option_for(point))
	for i in _type.item_count:
		_type.set_item_disabled(i, editable_type and _type.get_item_metadata(i).kind != kind)

func refresh(updated_id: int) -> void:
	var existing := _index(updated_id)
	if existing >= 0:
		_list.set_item_text(existing, _point_label(updated_id))
	else:
		_list.clear()
		for id in session.point_ids():
			var index := _list.add_item(_point_label(id))
			_list.set_item_metadata(index, id)
			if id == session.selected_point_id: _list.select(index)
	sync()

func select(id: int) -> void:
	_list.deselect_all()
	var index := _index(id)
	if index >= 0:
		_list.select(index)
		_list.ensure_current_is_visible.call_deferred()

func is_placing() -> bool:
	return place_button.button_pressed

func placed_fields() -> Dictionary:
	return _type.get_selected_metadata() if is_placing() else {}

func reset_placing() -> void:
	place_button.set_pressed_no_signal(false)

func _change_type(index: int) -> void:
	canvas.preview.queue_redraw()
	var choice: Dictionary = _type.get_item_metadata(index)
	var point := session.selected_point()
	if not is_placing() and point.get("kind") == choice.kind:
		session.commit_point(session.selected_point_id, choice.merged({"cell": point.cell}))
	elif not is_placing() and point.is_empty():
		place_button.button_pressed = true

func _option(label: String, fields: Dictionary) -> void:
	_type.add_item(label)
	_type.set_item_metadata(_type.item_count - 1, fields)

func _option_for(point: Dictionary) -> int:
	var choice := point.duplicate()
	choice.erase("cell")
	for i in _type.item_count:
		if _type.get_item_metadata(i) == choice: return i
	return -1

func _point_label(id: int) -> String:
	var point: Dictionary = session.map.points[id]
	return "%s  %s" % [_type.get_item_text(_option_for(point)), point.cell]

func _index(id: int) -> int:
	if id < 0: return -1
	for i in _list.item_count:
		if _list.get_item_metadata(i) == id: return i
	return -1
