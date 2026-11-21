class_name MatchView
extends Node

const CFG: PlayerConfig = preload("res://core/config/player_config.tres")

const TIME_REWIND := Color(0.86, 0.90, 0.95, 0.55)
const TIME_HASTE := Color8(168, 96, 216)
const FILM := preload("res://core/present/time_film.gdshader")

@onready var terrain_view: TerrainView = $WorldViewport/Terrain
@onready var _silhouette: TerrainView = $TerrainViewport/Silhouette
@onready var _ui_canvas: GuideCanvas = $UiViewport/UiCanvas
@onready var feedback: CombatFeedback = $Feedback
@onready var pause: PauseMenu = $Pause
var pvp_hud: PvpHud
var watch: WatchHud

var _world: WorldView
@onready var camera: MatchCamera = $WorldViewport/Camera
@onready var _hud: Hud = $Hud
@onready var _screen: PostProcess = $PostProcess
var _radar: Minimap
var _symbol: Label
var _film: ShaderMaterial
var _mode: MatchFrame.Mode

func mount(world: WorldView, grid: Array[Array], descriptors: PackedInt32Array,
		mode: MatchFrame.Mode, clock: MatchFrame.Clock, radar: bool) -> void:
	_mode = mode
	_world = world
	RenderingServer.set_default_clear_color(TerrainAtlas.SKY_COLOR)
	camera.zoom = Vector2.ONE * CFG.cam_zoom
	var viewport: SubViewport = $WorldViewport
	terrain_view.install(grid, descriptors, Vector2(viewport.size) / (2.0 * camera.zoom) + Vector2.ONE * CFG.cam_seam_margin)
	var silhouette_viewport: SubViewport = $TerrainViewport
	_silhouette.install(grid, descriptors,
			Vector2(silhouette_viewport.size) / (2.0 * camera.zoom) + Vector2.ONE * CFG.cam_seam_margin)
	_silhouette.modulate = Color.BLACK
	_silhouette.set_water_visible(false)
	_screen.set_terrain_mask_image(_terrain_mask(grid), (grid[0] as Array).size(), grid.size())
	var size := Vector2(grid[0].size(), grid.size()) * TerrainView.CELL
	_world.bind($WorldViewport/Canvas, size, _ui_canvas)
	_screen.attach_glow(_world.glow_pass())
	pause.mount(mode != MatchFrame.Mode.SOLO)
	if mode != MatchFrame.Mode.SOLO:
		pvp_hud = PvpHud.new()
		pvp_hud.mode = mode
		add_child(pvp_hud)
	if radar:
		_radar = Minimap.new(grid, size)
		add_child(_radar)
	if clock != null:
		_mount_watch(clock)

func present(delta: float, frame: MatchFrame) -> void:
	if frame.hit_ratio > 0.0:
		_screen.flash_hit(clampf(frame.hit_ratio * 2.0, 0.5, 1.0))
	_screen.set_downed(frame.downed)
	_screen.set_health_ratio(frame.health, frame.max_health)
	_hud.present(frame, delta)
	var film: ShaderMaterial
	if frame.clock != null:
		film = _present_clock(frame.clock, frame.now, delta)
	terrain_view.patch(frame.wall_changes)
	terrain_view.present(frame.now, film)
	_silhouette.patch(frame.wall_changes)
	_silhouette.present(frame.now, film)
	var grain_target := Vector2.ZERO
	if _mode == MatchFrame.Mode.SOLO:
		var clock := frame.clock
		Sfx.pitch_mult = clampf(1.0 + TimeParams.LOAN_PITCH_RANGE * clock.loan_depth
				+ (0.12 if clock.haste else -0.15 if clock.rewind else 0.0), 0.7, 1.8)
		var offset := watch.get_global_rect().get_center() - get_viewport().get_visible_rect().size * 0.5
		grain_target = camera.get_screen_center_position() + offset / camera.zoom
	_world.present(frame, grain_target)
	if _radar != null:
		_radar.present(frame)

func _mount_watch(clock: MatchFrame.Clock) -> void:
	watch = WatchHud.new(clock)
	watch.position = Vector2(24, 124)
	_hud.add_child(watch)
	var solo := _mode == MatchFrame.Mode.SOLO
	_symbol = UiFactory.label("◁ ◁", 64 if solo else 48, TIME_REWIND if solo else UiFactory.C_TEXT)
	_symbol.set_anchors_preset(Control.PRESET_CENTER if solo else Control.PRESET_CENTER_TOP)
	_symbol.grow_horizontal = Control.GROW_DIRECTION_BOTH
	if solo:
		_symbol.grow_vertical = Control.GROW_DIRECTION_BOTH
		_symbol.add_theme_constant_override("outline_size", 8)
		_symbol.add_theme_color_override("font_outline_color", Color8(10, 12, 16, 200))
	else:
		_symbol.offset_top = 60.0
		_symbol.offset_bottom = 60.0
		_film = ShaderMaterial.new()
		_film.shader = FILM
	_hud.add_child(_symbol)
	_symbol.hide()

func _present_clock(clock: MatchFrame.Clock, now: float, delta: float) -> ShaderMaterial:
	var solo := _mode == MatchFrame.Mode.SOLO
	var coverage := _screen.advance_time(delta, clock.rewind, clock.haste, clock.loan_depth, solo)
	watch.present(clock, delta)
	_symbol.visible = clock.rewind or (solo and clock.haste)
	if not solo:
		_film.set_shader_parameter("coverage", coverage)
		return _film if coverage > 0.0 else null
	if _symbol.visible:
		_symbol.text = "◁ ◁" if clock.rewind else "▶ ▶"
		_symbol.add_theme_color_override("font_color", TIME_REWIND if clock.rewind else TIME_HASTE)
		var pulse := sin(now * (9.0 if clock.rewind else 5.0))
		_symbol.modulate.a = 0.75 + 0.25 * pulse if clock.rewind else 0.8 + 0.2 * pulse
	return null

func _exit_tree() -> void:
	if _mode == MatchFrame.Mode.SOLO:
		Sfx.pitch_mult = 1.0


## 地形光照掩码:1 像素 = 1 格;R=实心,G=材质类/255,A=1。与 main 的 mask 格式一致。
func _terrain_mask(grid: Array[Array]) -> Image:
	var rows := grid.size()
	var cols: int = (grid[0] as Array).size()
	var img := Image.create(cols, rows, false, Image.FORMAT_RGBA8)
	for y in rows:
		for x in cols:
			var value: int = grid[y][x]
			var tex := Terrain.texture(value)
			if tex != 0 and TileDefs.type_id_of(tex) == TileDefs.TYPE_WALL:
				img.set_pixel(x, y, Color(1.0, float(TileDefs.material_id(tex)) / 255.0, 0.0, 1.0))
			else:
				img.set_pixel(x, y, Color(0.0, 0.0, 0.0, 1.0))
	return img
