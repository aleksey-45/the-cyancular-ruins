class_name MatchView
extends Node

const TCFG: TimeConfig = preload("res://core/config/time_config.tres")

const CFG: PlayerConfig = preload("res://core/config/player_config.tres")

const TIME_REWIND := Color(0.86, 0.90, 0.95, 0.55)
const TIME_HASTE := Color8(168, 96, 216)
const BACKGROUND_SCROLL := [0.8, 0.6, 0.4, 0.2]

@onready var terrain_view: TerrainView = $WorldViewport/Terrain
@onready var feedback: CombatFeedback = $Feedback
@onready var pause: PauseMenu = $Pause
var pvp_hud: PvpHud
var watch: WatchHud

var _world: WorldView
@onready var camera: MatchCamera = $WorldViewport/Camera
@onready var _viewport: SubViewport = $WorldViewport
@onready var _canvas: WorldCanvas = $WorldViewport/Canvas
@onready var _hud: Hud = $Hud
@onready var _screen: PostProcess = $PostProcess
var _radar: Minimap
var _symbol: Label
var _time_of_day: Label
var _mode: MatchFrame.Mode
var _presented_at := -1.0
var _intro: RunIntro
var _intro_time := -1.0
var _intro_downed := false
var _death_saved := false
var _water_state := Vector2.ZERO
var _intro_walls := PackedByteArray()

func mount(world: WorldView, map: Dictionary,
		mode: MatchFrame.Mode, clock: MatchFrame.Clock, radar: bool) -> void:
	_mode = mode
	_world = world
	_mount_battlefield(map)
	_world.bind(_canvas, Vector2(map.size * CyrmMap.CELL_SIZE))
	pause.mount(mode != MatchFrame.Mode.SOLO)
	if mode == MatchFrame.Mode.SOLO:
		_time_of_day = UiFactory.label("", 40)
		_time_of_day.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_time_of_day.add_theme_constant_override("outline_size", 6)
		UiFactory.place(_hud, _time_of_day, Rect2(-88, 16, 176, 54), Vector2(0.5, 0))
	else:
		pvp_hud = PvpHud.new()
		pvp_hud.mode = mode
		add_child(pvp_hud)
	if radar:
		_radar = Minimap.new(map)
		add_child(_radar)
	if clock != null:
		_mount_watch(clock)

func _mount_battlefield(map: Dictionary) -> void:
	camera.zoom = Vector2.ONE * CFG.cam_zoom
	var margin := Vector2(_viewport.size) / (2.0 * camera.zoom) + Vector2.ONE * CFG.cam_seam_margin
	_mount_backgrounds(_viewport, map, margin)
	terrain_view.install(map, margin)

func mount_intro(intro: RunIntro) -> void:
	_mount_battlefield(intro.map)
	_intro_walls = intro.walls
	_hud.hide()
	feedback.hide()
	feedback.set_process(false)
	pause.set_process_unhandled_input(false)
	_screen.set_process(false)
	_screen.set_process_unhandled_input(false)
	var hint := UiFactory.label("Esc / 空格 跳过", 28)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hint.add_theme_constant_override("outline_size", 6)
	UiFactory.place(_screen, hint, Rect2(-252, -70, 224, 44), Vector2.ONE)

func show_intro_frame(frame: Array, textures: Array[Texture2D]) -> void:
	var walls: PackedByteArray = frame[RunIntro.Frame.WALLS]
	terrain_view.show_walls(_intro_walls, walls)
	_intro_walls = walls
	var water: Vector2 = frame[RunIntro.Frame.WATER]
	terrain_view.present(water.x, water.y)
	camera.position = frame[RunIntro.Frame.CAMERA]
	camera.force_update_scroll()
	_canvas.show_display(frame[RunIntro.Frame.DRAW], textures)
	_screen.show_display(frame[RunIntro.Frame.POST])

func present_intro_effect(elapsed: float, duration: float) -> void:
	var fade := smoothstep(0.0, 0.1, elapsed) * smoothstep(0.0, 0.12, duration - elapsed)
	_screen.set_intro_rewind(elapsed, fade * lerpf(0.35, 1.0, elapsed / duration))

func set_battle_visible(shown: bool) -> void:
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if shown else SubViewport.UPDATE_DISABLED
	_hud.visible = shown
	feedback.visible = shown
	_screen.visible = shown
	_screen.set_process(shown)
	_screen.set_process_unhandled_input(shown)
	pause.set_process_unhandled_input(shown)

func begin_intro_capture(map: Dictionary) -> void:
	_intro = RunIntro.new(map)
	_intro_time = -1.0
	_intro_downed = false
	_death_saved = false
	RenderingServer.frame_pre_draw.connect(capture_intro_frame)

func capture_intro_frame(force := false) -> void:
	if _intro == null or _intro_time < 0.0 or _death_saved:
		return
	if not force and get_tree().paused:
		return
	_intro.append([_intro_time, _intro.walls, camera.position, _water_state, _screen.display_state(),
		_canvas.display_state(_intro.texture_index)])
	if _intro_downed:
		_death_saved = true
		_intro.save()

func end_intro_capture(save := false) -> void:
	if _intro == null:
		return
	if save and not _death_saved:
		if not get_tree().paused:
			capture_intro_frame(true)
		if not _death_saved and not _intro.frames.is_empty():
			_intro.save()
	RenderingServer.frame_pre_draw.disconnect(capture_intro_frame)
	_intro = null

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
		# 纹理周期与滚动速度同比缩放，镜头绕地图一圈后仍落在同一像素。
		sprite.scale = plane.scroll_scale * CyrmMap.CELL_SIZE
		var border := (margin / sprite.scale).ceil()
		sprite.region_rect = Rect2(-border, Vector2(map.size) + 2 * border)
		sprite.position = -border * sprite.scale
		plane.add_child(sprite)
		viewport.add_child(plane)

func present(delta: float, frame: MatchFrame) -> void:
	if frame.now == _presented_at:
		return
	_presented_at = frame.now
	_apply_cues(frame)
	if frame.round != null:
		pvp_hud.show_round(frame.round)
	if frame.hit_ratio > 0.0:
		_screen.flash_hit(clampf(frame.hit_ratio * 2.0, 0.5, 1.0))
	_screen.set_downed(frame.downed)
	_screen.set_health_ratio(frame.health, frame.max_health)
	_hud.present(frame, delta)
	var coverage := _present_clock(frame.clock, frame.now, delta) if frame.clock else 0.0
	terrain_view.patch(frame.wall_changes)
	terrain_view.present(frame.now, coverage)
	var grain_target := Vector2.ZERO
	if _mode == MatchFrame.Mode.SOLO:
		_time_of_day.text = Daylight.time_text(frame.day_minute)
		var clock := frame.clock
		Sfx.pitch_mult = clampf(1.0 + TCFG.LOAN_PITCH_RANGE * clock.loan_depth
				+ (0.12 if clock.haste else -0.15 if clock.rewind else 0.0), 0.7, 1.8)
		var offset := watch.get_global_rect().get_center() - get_viewport().get_visible_rect().size * 0.5
		grain_target = camera.get_screen_center_position() + offset / camera.zoom
	_world.present(frame, grain_target)
	if _radar != null:
		_radar.present(frame)
	if _intro != null:
		_intro.patch_walls(frame.wall_changes)
		_water_state = Vector2(frame.now, coverage)
		if _intro_time < 0.0:
			_intro_time = 0.0
		elif not _intro_downed or not frame.downed:
			_intro_time += delta
		_intro_downed = frame.downed
		if not _intro_downed:
			_death_saved = false

func _apply_cues(frame: MatchFrame) -> void:
	camera.hit(frame.hit_ratio)
	for cue: Array in frame.cues:
		match cue[0]:
			"reset": _world.reset()
			"clear_motion": _world.clear_motion(cue[1])
			"motion": _world.motion(cue[1], cue[2], frame.now, cue[3])
			"splash": _world.splash(cue[1], cue[2], frame.now)
			"debris": _world.debris(cue[1], cue[2], frame.now)
			"number": _world.hit(cue[1], cue[2], cue[3], cue[4])
			"sound": Sfx.play(cue[1])
			"hit": feedback.show_hit()
			"kill": feedback.show_kill(cue[1])
			"streak_reset": feedback.reset_streak()
			"grain": _world.grain(cue[1], frame.now, TCFG.ELITE_GRAIN_DELAY_TICKS * ActorStep.DT)
			"grain_received": watch.tremble()
			"loan_locked": watch.flash_locked()
			"fire":
				_world.fire(cue[1], cue[2], frame.now)
				Sfx.play(WeaponRegistry.definition(cue[2])["shot_sound"])
				if cue[3]:
					camera.fire(cue[2])
			"blast":
				_world.blast(cue[1], frame.now)
				var distance: float = frame.focus.distance_to(GridPathfinder.anchor_to_nearest(cue[1], frame.focus, _world._size))
				camera.blast(distance, WeaponRegistry.blast_definition(cue[2])["radius"])

func _mount_watch(clock: MatchFrame.Clock) -> void:
	watch = WatchHud.new(clock)
	watch.position = Vector2(24, 124)
	_hud.add_child(watch)
	var solo := _mode == MatchFrame.Mode.SOLO
	_symbol = UiDesign.label("◁ ◁", UiDesign.T_H2 * 2 if solo else UiDesign.T_H1,
			TIME_REWIND if solo else UiDesign.C_TEXT)
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

func _present_clock(clock: MatchFrame.Clock, now: float, delta: float) -> float:
	var solo := _mode == MatchFrame.Mode.SOLO
	var coverage := _screen.advance_time(delta, clock.rewind, clock.haste, clock.loan_depth, solo)
	watch.present(clock, delta)
	_symbol.visible = clock.rewind or (solo and clock.haste)
	if not solo:
		return coverage
	if _symbol.visible:
		_symbol.text = "◁ ◁" if clock.rewind else "▶ ▶"
		_symbol.add_theme_color_override("font_color", TIME_REWIND if clock.rewind else TIME_HASTE)
		var pulse := sin(now * (9.0 if clock.rewind else 5.0))
		_symbol.modulate.a = 0.75 + 0.25 * pulse if clock.rewind else 0.8 + 0.2 * pulse
	return 0.0

func _exit_tree() -> void:
	end_intro_capture()
	if _world != null and _mode == MatchFrame.Mode.SOLO:
		Sfx.pitch_mult = 1.0
