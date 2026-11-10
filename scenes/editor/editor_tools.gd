extends RefCounted

# 编辑器的「工具层」:工具状态(画笔/橡皮/…/渐变)+ 画布指针 → doc 写入 + 选区拖拽 + meta 放置。
# UI 在 scenes/editor/editor_root.tscn(root 只接线);本文件不碰任何控件,只发信号让 root 显示。
# ★ 进客户端导出包 ⇒ 禁止 RegEx。所有坐标 = 子格(16px);格 = 子格/4。

const TOOL_BRUSH := "brush"
const TOOL_ERASER := "eraser"
const TOOL_LINE := "line"
const TOOL_RECT := "rect"
const TOOL_BUCKET := "bucket"
const TOOL_EYEDROP := "eyedrop"
const TOOL_SELECT := "select"
const TOOL_GRADIENT := "gradient"

const TOOL_LABELS := {
	TOOL_BRUSH: "画笔", TOOL_ERASER: "橡皮", TOOL_LINE: "直线",
	TOOL_RECT: "矩形", TOOL_BUCKET: "油漆桶", TOOL_EYEDROP: "吸管",
	TOOL_SELECT: "选框", TOOL_GRADIENT: "渐变",
}

# meta 放置模式(点画布 = 在当前格放一个;不改地形)。
const META_NONE := "none"
const META_PLAYER := "player"
const META_RESPAWN1 := "respawn1"
const META_RESPAWN2 := "respawn2"
const META_ENEMY := "enemy"
const META_LABELS := {
	META_NONE: "编辑地形", META_PLAYER: "放出生点",
	META_RESPAWN1: "放复活点侧1", META_RESPAWN2: "放复活点侧2", META_ENEMY: "放敌人",
}

signal message(text: String, is_error: bool)
signal tool_changed(key: String)
signal meta_mode_changed(key: String)
signal paint_desc_changed(desc: int)
signal selection_changed()

var doc: EditorDoc = null
var canvas: EditorCanvas = null

var tool := TOOL_BRUSH
var paint_desc := 0
var brush_cells := 1
var color_value := Color(0.0, 0.0, 0.0, 0.0)
var gradient_end := Color(1.0, 1.0, 1.0, 0.0)
var meta_mode := META_NONE

var _painting := false
var _stroke_begin := Vector2i.ZERO
var _last_cell := Vector2i.ZERO
var _has_last := false
var _selecting := false
var _select_start := Vector2i.ZERO


func setup(p_doc: EditorDoc, p_canvas: EditorCanvas) -> void:
	doc = p_doc
	canvas = p_canvas


func set_tool(key: String) -> void:
	tool = key
	canvas.set_preview_desc(0 if key == TOOL_ERASER else paint_desc)
	tool_changed.emit(key)
	if key == TOOL_SELECT:
		message.emit("选框:在画布上拖出矩形", false)
	elif key == TOOL_GRADIENT:
		message.emit("渐变:在颜色层(3-6)从起点拖到终点(两端颜色见右栏「颜色」)", false)


func set_brush_cells(n: float) -> void:
	brush_cells = maxi(1, int(n))
	canvas.set_brush_preview(brush_cells)


func set_paint_desc(desc: int) -> void:
	paint_desc = desc
	canvas.set_preview_desc(desc)
	paint_desc_changed.emit(desc)


func set_meta_mode(key: String) -> void:
	meta_mode = key
	meta_mode_changed.emit(key)
	if key != META_NONE:
		message.emit("放置模式:%s(点画布放置;再点一次「编辑地形」退出)"
				% String(META_LABELS.get(key, key)), false)


func tool_label() -> String:
	return String(TOOL_LABELS.get(tool, tool))


# ── 画布指针 ──────────────────────────────────────────────────────────

func pointer_down(sub: Vector2i, button: int, _shift: bool, _ctrl: bool) -> void:
	if button != MOUSE_BUTTON_LEFT:
		return
	if meta_mode != META_NONE:
		_place_meta_at(sub)
		return
	_painting = true
	_stroke_begin = sub
	_has_last = false
	match tool:
		TOOL_SELECT:
			_selecting = true
			_select_start = cell_of(sub)
			doc.set_selection(sub_rect_cells(_select_start, _select_start))
			canvas.set_selection(doc.selection)
			selection_changed.emit()
		TOOL_GRADIENT:
			pass                                  # 渐变在 pointer_up 时按起点/终点落笔
		TOOL_BRUSH, TOOL_ERASER:
			doc.begin_stroke()
			stamp(sub)
			_last_cell = cell_of(sub)
			_has_last = true
		TOOL_BUCKET:
			doc.begin_stroke()
			doc.flood_fill(sub, current_value())
			doc.end_stroke()
			_painting = false
		TOOL_EYEDROP:
			set_paint_desc(doc.sample(sub.x, sub.y))
			set_tool(TOOL_BRUSH)
			_painting = false
		_:
			doc.begin_stroke()


func pointer_drag(sub: Vector2i) -> void:
	if not _painting:
		return
	if tool == TOOL_SELECT:
		doc.set_selection(sub_rect_cells(_select_start, cell_of(sub)))
		canvas.set_selection(doc.selection)
		canvas.queue_redraw()
		selection_changed.emit()
		return
	if tool == TOOL_BRUSH or tool == TOOL_ERASER:
		if _has_last:
			var from := _last_cell
			var to := cell_of(sub)
			for c in EditorGeometry.line_cells(from.x, from.y, to.x, to.y):
				stamp_cell(c)
			_last_cell = to
		else:
			stamp(sub)
			_has_last = true
		_last_cell = cell_of(sub)


func pointer_up(sub: Vector2i) -> void:
	if not _painting:
		return
	match tool:
		TOOL_SELECT:
			_selecting = false
			doc.set_selection(sub_rect_cells(_select_start, cell_of(sub)))
			canvas.set_selection(doc.selection)
			selection_changed.emit()
		TOOL_GRADIENT:
			var res := doc.paint_gradient(_stroke_begin, sub, color_u32(color_value), color_u32(gradient_end))
			if bool(res.get("ok", false)):
				message.emit("渐变已应用(%d 个子格)" % int(res.get("count", 0)), false)
			else:
				message.emit("渐变失败:%s" % String(res.get("error", "")), true)
		TOOL_LINE:
			for c in EditorGeometry.line_cells(cell_of(_stroke_begin).x, cell_of(_stroke_begin).y,
					cell_of(sub).x, cell_of(sub).y):
				stamp_cell(c)
		TOOL_RECT:
			var r := EditorGeometry.norm_region(cell_of(_stroke_begin).x, cell_of(_stroke_begin).y,
					cell_of(sub).x, cell_of(sub).y)
			for y in range(int(r["y"]), int(r["y"]) + int(r["h"])):
				for x in range(int(r["x"]), int(r["x"]) + int(r["w"])):
					stamp_cell(Vector2i(x, y))
	doc.end_stroke()
	_painting = false
	_has_last = false


# 格矩形(含两端)→ 子格矩形(选区单位是子格)。
func sub_rect_cells(a: Vector2i, b: Vector2i) -> Rect2i:
	var r := EditorGeometry.norm_region(a.x, a.y, b.x, b.y)
	var s := EditorConstants.SUB_PER_CELL
	return Rect2i(int(r["x"]) * s, int(r["y"]) * s, int(r["w"]) * s, int(r["h"]) * s)


func stamp(sub: Vector2i) -> void:
	stamp_cell(cell_of(sub))


func stamp_cell(cell: Vector2i) -> void:
	var off := EditorGeometry.brush_offsets(brush_cells)
	var value := current_value()
	var cells: Array[Vector2i] = []
	for dy in range(-int(off["lo"]), int(off["hi"]) + 1):
		for dx in range(-int(off["lo"]), int(off["hi"]) + 1):
			for sy in EditorConstants.SUB_PER_CELL:
				for sx in EditorConstants.SUB_PER_CELL:
					cells.append(Vector2i((cell.x + dx) * EditorConstants.SUB_PER_CELL + sx,
							(cell.y + dy) * EditorConstants.SUB_PER_CELL + sy))
	doc.set_cells(cells, value)


func current_value() -> int:
	if tool == TOOL_ERASER:
		return 0
	if EditorConstants.is_color_layer(doc.active_layer):
		return color_u32(color_value)
	return paint_desc


func cell_of(sub: Vector2i) -> Vector2i:
	return Vector2i(floori(sub.x / float(EditorConstants.SUB_PER_CELL)),
			floori(sub.y / float(EditorConstants.SUB_PER_CELL)))


static func color_u32(c: Color) -> int:
	var r := clampi(int(round(c.r * 255.0)), 0, 255)
	var g := clampi(int(round(c.g * 255.0)), 0, 255)
	var b := clampi(int(round(c.b * 255.0)), 0, 255)
	var a := clampi(int(round(c.a * 255.0)), 0, 255)
	return (r << 24) | (g << 16) | (b << 8) | a


func _place_meta_at(sub: Vector2i) -> void:
	var cell := cell_of(sub)
	var placed := -1
	match meta_mode:
		META_PLAYER:
			placed = doc.add_player(cell)
		META_RESPAWN1:
			placed = doc.add_respawn(1, cell)
		META_RESPAWN2:
			placed = doc.add_respawn(2, cell)
		META_ENEMY:
			placed = doc.add_enemy("slime", cell)
	if placed >= 0:
		message.emit("已放置%s @ (%d,%d)" % [String(META_LABELS.get(meta_mode, meta_mode)), cell.x, cell.y], false)
	else:
		message.emit("放置失败:%s" % String(META_LABELS.get(meta_mode, meta_mode)), true)
