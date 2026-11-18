extends RefCounted

# 顶栏「视图」组:真渲染预览(含「光照」时辰条)与「试玩当前地图」。root 只转发公开 API。
# 无 class_name(调用方 preload),与 editor_tools/editor_actions 同规。

const PREVIEW_SCRIPT := preload("res://scenes/editor/editor_preview.gd")
const PLAYTEST_SCRIPT := preload("res://scenes/editor/editor_playtest.gd")

var page: Control = null
var doc: EditorDoc = null
var canvas: EditorCanvas = null
var canvas_host: Control = null

var preview: Control = null
var preview_on := false
var preview_btn: Button = null
var playtest_btn: Button = null
var _last_origin := Vector2.INF
var _last_zoom := -1.0

var light_bar: Control = null
var light_hour: HSlider = null
var light_time: Label = null
var hour := 12.0                       # 预览光照时辰(0..24;正午最亮 = 看地图版式的默认)


func setup(p: Control, d: EditorDoc, c: EditorCanvas, host: Control) -> void:
	page = p
	doc = d
	canvas = c
	canvas_host = host


## 接线:预览/试玩按钮 + 光照条样式。预览节点由 build() 在 canvas.set_doc 之后创建。
func wire(preview_button: Button, playtest_button: Button) -> void:
	preview_btn = preview_button
	playtest_btn = playtest_button
	preview_btn.pressed.connect(toggle)
	playtest_btn.pressed.connect(on_playtest_pressed)

	light_bar = page.get_node("%LightBar") as Control
	light_hour = page.get_node("%LightHour") as HSlider
	light_time = page.get_node("%LightTime") as Label
	UiFactory.hud_plate(light_bar, UiFactory.SP_3, UiFactory.SP_2, true, UiFactory.C_PLATE_DEEP)
	UiFactory.style_slider(light_hour)
	UiFactory.style_control(light_time, UiFactory.T_LABEL)
	light_time.add_theme_color_override("font_color", UiFactory.C_TEXT)
	(page.get_node("%LightLabel") as Label).add_theme_color_override("font_color", UiFactory.C_TEXT_DIM)
	light_hour.value = hour
	update_light_time()
	light_hour.value_changed.connect(_on_light_hour_changed)


## 建预览层(挂在画布上用同一套游戏管线)。调用时机 = root 把 doc 交给 canvas 之后。
func build() -> void:
	if preview != null:
		return
	preview = PREVIEW_SCRIPT.new()
	preview.name = "Preview"
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE      # 让画布继续收鼠标(预览是只读层)
	canvas_host.add_child(preview)
	# 绘制顺序:画布 → 预览 → 浮动控件(光照条)。预览必须盖住画布,但不能盖住贴着画布底部的控件。
	var overlay := page.get_node_or_null("%OverlayHost") as Control
	if overlay != null:
		canvas_host.move_child(preview, overlay.get_index())
	preview.setup(doc)
	preview.set_hour(hour)
	preview.set_active(false)
	preview.visible = false


func process(_dt: float) -> void:
	if not preview_on or preview == null or canvas == null:
		return
	var origin := canvas.origin
	var zoom := canvas.zoom
	if origin != _last_origin or zoom != _last_zoom:
		_last_origin = origin
		_last_zoom = zoom
		preview.set_camera(origin, zoom)


func get_preview() -> Control:
	return preview


func is_preview_on() -> bool:
	return preview_on


func set_preview(on: bool) -> void:
	if preview == null:
		return
	preview_on = on
	preview.visible = on
	preview.set_active(on)
	if preview_btn != null:
		preview_btn.text = "预览:开" if on else "预览:关"
	if light_bar != null:
		light_bar.visible = on
	if on:
		_last_origin = canvas.origin
		_last_zoom = canvas.zoom
		preview.set_camera(canvas.origin, canvas.zoom)
		preview.set_hour(hour)
	page.call("notify", "预览:%s" % ("开(复用游戏渲染管线;底部「光照」可换时辰)"
			if on else "关(快速画布)"), false)


func toggle() -> void:
	set_preview(not preview_on)


## 设置预览光照时辰(0..24)。公开 API:探针/截图/UI 共用同一个入口。
func set_hour(h: float) -> void:
	var v := fposmod(h, 24.0)
	if light_hour != null and not is_equal_approx(light_hour.value, v):
		light_hour.set_value_no_signal(v)
	hour = v
	update_light_time()
	if preview != null and preview_on:
		preview.set_hour(hour)


func get_hour() -> float:
	return hour


func update_light_time() -> void:
	if light_time == null:
		return
	var h := fposmod(hour, 24.0)
	light_time.text = "%02d:%02d" % [int(h), int((h - float(int(h))) * 60.0)]


func _on_light_hour_changed(v: float) -> void:
	if absf(v - hour) < 0.001:
		return
	hour = fposmod(v, 24.0)
	update_light_time()
	if preview != null and preview_on:
		preview.set_hour(hour)


# ── 试玩(编辑器 → 游戏;不落用户文件)────────────────────────────────────

## 用当前内存文档起一局试玩:编码到临时图 → 钉住临时图 → 换到 level_0。
## spawn_cell 给 (x,y) 就从该出生点起;(-1,-1) = 由 map 里的 `# player` 决定。
func start_playtest(spawn_cell: Vector2i = Vector2i(-1, -1)) -> Dictionary:
	if doc == null or doc.map.is_empty():
		page.call("notify", "先新建或打开一张地图,再试玩", true)
		return {"ok": false, "error": "空地图"}
	var enc := EditorCodec.encode_map(doc.map)
	if not bool(enc.get("ok", false)):
		page.call("notify", "试玩失败:%s" % String(enc.get("error", "")), true)
		return {"ok": false, "error": String(enc.get("error", ""))}
	var f := FileAccess.open(PLAYTEST_SCRIPT.TMP_MAP, FileAccess.WRITE)
	if f == null:
		page.call("notify", "试玩失败:写不了临时地图(%s)"
				% error_string(FileAccess.get_open_error()), true)
		return {"ok": false, "error": "写临时地图失败"}
	f.store_buffer(enc["bytes"] as PackedByteArray)
	f.close()
	var picked := MazeGenerator.picked_map_path()   # 试玩完 Level0 要还回原来的地图
	PLAYTEST_SCRIPT.stash(doc, String(page.call("current_path")), spawn_cell, picked)
	MazeGenerator.set_map_file(PLAYTEST_SCRIPT.TMP_MAP)
	Level0.pvp_mode = false
	CombatComponent.pvp_arena = false
	Level0.playtest_restore_map = picked
	Level0.playtest_spawn = spawn_cell
	Level0.playtest_mode = true
	var where := ""
	if spawn_cell.x >= 0 and spawn_cell.y >= 0:
		where = " · 出生点 (%d,%d)" % [spawn_cell.x, spawn_cell.y]
	page.call("notify", "试玩:敌人静止、空手%s;Esc 返回编辑器(未保存改动不丢)" % where, false)
	Level0.safe_change_scene(page.get_tree(), "res://scenes/level_0.tscn")
	return {"ok": true}


func on_playtest_pressed() -> void:
	start_playtest(first_player_cell())


func on_player_marker_clicked(cell: Vector2i) -> void:
	start_playtest(cell)


# 地图里第一个出生点(没有就 (-1,-1):由游戏按「左上第一个空格」兜底)。
func first_player_cell() -> Vector2i:
	if doc == null or doc.map.is_empty():
		return Vector2i(-1, -1)
	var players: Array = doc.map.get("players", [])
	if players.is_empty():
		return Vector2i(-1, -1)
	var p: Variant = players[0]
	if not (p is Dictionary):
		return Vector2i(-1, -1)
	var pd: Dictionary = p
	return Vector2i(int(pd.get("x", 0)), int(pd.get("y", 0)))
