class_name MatchView
extends Node

const TIME_REWIND := Color(0.86, 0.90, 0.95, 0.55)
const TIME_HASTE := Color8(168, 96, 216)
const FILM := preload("res://core/present/time_film.gdshader")

var terrain_view: TerrainView
var feedback: CombatFeedback
var pause: PauseMenu
var pvp_hud: PvpHud
var watch: WatchHud

var _world: WorldView
var _camera: Camera2D
var _hud: Hud
var _screen: PostProcess
var _radar: Minimap
var _symbol: Label
var _film: ShaderMaterial
var _mode: MatchFrame.Mode

func _init(world: WorldView) -> void:
	_world = world

func mount(viewport: SubViewport, grid: Array[Array], descriptors: PackedInt32Array,
		mode: MatchFrame.Mode, clock: MatchFrame.Clock, radar: bool) -> void:
	_mode = mode
	RenderingServer.set_default_clear_color(TerrainAtlas.SKY_COLOR)
	var zoom := PlayerParams.cam_zoom
	_camera = Camera2D.new()
	_camera.zoom = Vector2.ONE * zoom
	viewport.add_child(_camera)
	terrain_view = TerrainView.new()
	viewport.add_child(terrain_view)
	terrain_view.install(grid, descriptors, Vector2(viewport.size) / (2.0 * zoom) + Vector2.ONE * PlayerParams.cam_seam_margin)
	var size := Vector2(grid[0].size(), grid.size()) * TerrainView.CELL
	_world.attach(viewport, size)
	_screen = PostProcess.new()
	_screen.world_viewport = viewport
	add_child(_screen)
	_hud = Hud.new()
	add_child(_hud)
	feedback = CombatFeedback.new()
	add_child(feedback)
	pause = PauseMenu.new(mode != MatchFrame.Mode.SOLO)
	add_child(pause)
	pause.paused_frame.connect(present.bind(null))
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
	if pvp_hud != null:
		pvp_hud.present(delta)
	if frame != null:
		_camera.position = frame.camera_at
		if frame.hit_ratio > 0.0:
			_screen.flash_hit(clampf(frame.hit_ratio * 2.0, 0.5, 1.0))
		_screen.set_downed(frame.downed)
		_screen.set_health_ratio(frame.health, frame.max_health)
	_screen.present(delta)
	feedback.present(delta)
	if frame == null:
		return
	_hud.present(frame, delta)
	var film: ShaderMaterial
	if frame.clock != null:
		film = _present_clock(frame.clock, frame.now, delta)
	terrain_view.patch(frame.wall_changes)
	terrain_view.present(frame.now, film)
	var grain_target := Vector2.ZERO
	if _mode == MatchFrame.Mode.SOLO:
		var clock := frame.clock
		Sfx.pitch_mult = clampf(1.0 + TimeParams.LOAN_PITCH_RANGE * clock.loan_depth
				+ (0.12 if clock.haste else -0.15 if clock.rewind else 0.0), 0.7, 1.8)
		var offset := watch.get_global_rect().get_center() - get_viewport().get_visible_rect().size * 0.5
		grain_target = _camera.get_screen_center_position() + offset / _camera.zoom
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
