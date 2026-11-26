class_name MapEditorInspector
extends VBoxContainer

signal changed

var session: MapEditSession
var brush: MapBrush
var canvas: MapEditCanvas

var param_rows: Dictionary[String, Control] = {}
var tints: Array[SpinBox] = []
var ink := ColorPickerButton.new()
var points: MapEditorPoints

var _selection_info: Label

func setup(p_session: MapEditSession, p_brush: MapBrush, p_canvas: MapEditCanvas,
		clipboard: Array, on_changed: Callable) -> void:
	session = p_session
	brush = p_brush
	canvas = p_canvas
	add_theme_constant_override("separation", UiDesign.SP_2)
	_build(clipboard)
	changed.connect(on_changed)

func _build(clipboard: Array) -> void:
	var width := UiKit.spin_row(self, "笔宽（子格）", 1, 60, brush.width)
	param_rows.width = width.get_parent()
	width.value_changed.connect(func(value: float) -> void:
		brush.width = int(value)
		changed.emit()
		canvas.preview.queue_redraw())

	param_rows.outline = _check(self, "仅画矩形边框", func(on: bool) -> void:
		brush.outline = on
		changed.emit())

	var material := FoldableContainer.new()
	material.title = "材质调色"
	material.folded = true
	add_child(material)
	param_rows.material = material
	var fields := UiDesign.box(material, UiDesign.SP_1, true)
	for i in 4:
		var spin := UiKit.spin_row(fields, ["色相", "亮度", "饱和度", "透明度"][i], 0, 7, brush.tint[i])
		spin.value_changed.connect(func(value: float) -> void:
			brush.tint[i] = int(value)
			changed.emit())
		tints.append(spin)
	_check(fields, "仅修改调色", func(on: bool) -> void:
		brush.tint_only = on
		material.title = "材质调色 · 仅调色" if on else "材质调色")

	param_rows.color = VBoxContainer.new()
	add_child(param_rows.color)
	for property: String in ["color", "end_color"]:
		var row := HBoxContainer.new()
		param_rows.color.add_child(row)
		var start := property == "color"
		UiKit.label(row, "颜色" if start else "终点色").size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var picker := ink if start else ColorPickerButton.new()
		row.add_child(picker)
		picker.custom_minimum_size = Vector2(85, 34)
		picker.color = brush.get(property)
		picker.color_changed.connect(func(value: Color) -> void:
			brush.set(property, value)
			changed.emit())
		if not start: param_rows.end_color = row

	param_rows.selection = VBoxContainer.new()
	add_child(param_rows.selection)
	_selection_info = UiKit.label(param_rows.selection, "")
	var actions := GridContainer.new()
	actions.columns = 2
	param_rows.selection.add_child(actions)
	for item in clipboard + [["清除选区内容", session.clear_selection], ["水平镜像", session.mirror.bind(true)],
			["垂直镜像", session.mirror.bind(false)]]:
		UiKit.button(actions, item[0], item[1]).size_flags_horizontal = Control.SIZE_EXPAND_FILL

	points = MapEditorPoints.new()
	add_child(points)
	points.setup(session, canvas)
	param_rows.points = points

func sync(params: Array, hidden_ink: String) -> void:
	for parameter: String in param_rows:
		param_rows[parameter].visible = parameter != hidden_ink and params.has(parameter)
	points.sync()

func set_selection(selection: Rect2i) -> void:
	_selection_info.text = "%d × %d 子格" % [selection.size.x, selection.size.y] if selection.has_area() else "拖动框选范围"

func set_ink(color: Color) -> void:
	ink.color = color

func set_tints(values: Vector4i) -> void:
	for i in tints.size():
		tints[i].set_value_no_signal(values[i])

func _check(parent: Control, text: String, action: Callable) -> CheckBox:
	var check := CheckBox.new()
	check.text = text
	parent.add_child(check)
	check.toggled.connect(action)
	return check
