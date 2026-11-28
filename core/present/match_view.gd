class_name MatchView
extends Node

const CFG: PlayerConfig = preload("res://core/config/player_config.tres")

const BACKGROUND_SCROLL := [0.8, 0.6, 0.4, 0.2]

@onready var terrain_view: TerrainView = $WorldViewport/Terrain
@onready var feedback: CombatFeedback = $Feedback
@onready var pause: PauseMenu = $Pause
var pvp_hud: PvpHud
var watch: WatchHud

@onready var camera: Camera2D = $WorldViewport/Camera
@onready var _viewport: SubViewport = $WorldViewport
@onready var _canvas: WorldCanvas = $WorldViewport/Canvas
@onready var _hud: Hud = $Hud
@onready var post: PostProcess = $PostProcess
var _radar: Minimap
var _symbol: Label
var _time_of_day: Label
var textures: Array[Texture2D]

func mount(map: Dictionary, mode: String, has_watch: bool, radar: bool) -> void:
	_mount_battlefield(map)
	pause.mount(mode != WorldSpec.SOLO)
	if mode == WorldSpec.SOLO:
		_time_of_day = UiDesign.label("", 40)
		_time_of_day.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_time_of_day.add_theme_constant_override("outline_size", 6)
		UiDesign.place(_hud, _time_of_day, Rect2(-88, 16, 176, 54), Vector2(0.5, 0))
	else:
		pvp_hud = PvpHud.new()
		pvp_hud.mode = mode
		add_child(pvp_hud)
	if radar:
		_radar = Minimap.new(map)
		add_child(_radar)
	if has_watch:
		_mount_watch(mode == WorldSpec.SOLO)

func _mount_battlefield(map: Dictionary) -> void:
	camera.zoom = Vector2.ONE * CFG.cam_zoom
	var margin := Vector2(_viewport.size) / (2.0 * camera.zoom) + Vector2.ONE * CFG.cam_seam_margin
	_mount_backgrounds(_viewport, map, margin)
	terrain_view.install(map, margin)
	_canvas.lamps.install(map, margin)
	terrain_view.wall_changed.connect(_canvas.lamps.set_support)

func draw_frame(frame: DrawFrame) -> void:
	camera.position = frame.camera
	camera.force_update_scroll()
	terrain_view.show_walls(frame.walls)
	terrain_view.present(frame.water.x, frame.water.y)
	_canvas.draw_world(frame.world, textures)
	post.display(frame.post)
	var hud: Dictionary = frame.hud
	_hud.display(hud)
	feedback.display(hud.feedback)
	if watch:
		watch.display(hud.watch)
		_symbol.text = hud.watch.symbol
		_symbol.visible = not hud.watch.symbol.is_empty()
		_symbol.add_theme_color_override("font_color", hud.watch.symbol_color)
		_symbol.modulate.a = hud.watch.symbol_alpha
	if _time_of_day: _time_of_day.text = hud.day
	if pvp_hud: pvp_hud.display(hud.score)
	if _radar: _radar.display(hud.radar)

func set_battle_visible(shown: bool) -> void:
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if shown else SubViewport.UPDATE_DISABLED
	_hud.visible = shown
	feedback.visible = shown
	post.visible = shown
	pause.set_process_unhandled_input(shown)

func _mount_backgrounds(viewport: SubViewport, map: Dictionary, margin: Vector2) -> void:
	for depth in BACKGROUND_SCROLL.size():
		var image := TerrainAtlas.background_image(map, CyrmMap.FIRST_BACKGROUND + depth)
		if image.is_invisible(): continue
		var plane := Parallax2D.new()
		plane.scroll_scale = Vector2.ONE * BACKGROUND_SCROLL[depth]
		plane.scroll_offset = Vector2(viewport.size) * 0.5 * (Vector2.ONE - plane.scroll_scale)
		plane.z_index = -1 - depth
		var sprite := Sprite2D.new()
		sprite.texture = ImageTexture.create_from_image(image)
		sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		sprite.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
		sprite.centered = false
		sprite.region_enabled = true
		# 纹理的平铺周期和视差滚动速度按同一比例缩放，摄像机绕地图一周后背景仍然对齐。
		sprite.scale = plane.scroll_scale * CyrmMap.CELL_SIZE
		var border := (margin / sprite.scale).ceil()
		sprite.region_rect = Rect2(-border, Vector2(map.size) + 2 * border)
		sprite.position = -border * sprite.scale
		plane.add_child(sprite)
		viewport.add_child(plane)

func _mount_watch(solo: bool) -> void:
	watch = WatchHud.new()
	watch.position = Vector2(24, 124)
	_hud.add_child(watch)
	_symbol = UiDesign.label("◁ ◁", UiDesign.T_H2 * 2 if solo else UiDesign.T_H1,
			WatchHud.TIME_REWIND if solo else UiDesign.C_TEXT)
	_symbol.set_anchors_preset(Control.PRESET_CENTER if solo else Control.PRESET_CENTER_TOP)
	_symbol.grow_horizontal = Control.GROW_DIRECTION_BOTH
	if solo:
		_symbol.grow_vertical = Control.GROW_DIRECTION_BOTH
		_symbol.add_theme_constant_override("outline_size", 8)
		_symbol.add_theme_color_override("font_outline_color", Color8(10, 12, 16, 200))
	else:
		_symbol.offset_top = 60.0
		_symbol.offset_bottom = 60.0
	_hud.add_child(_symbol)
	_symbol.hide()
