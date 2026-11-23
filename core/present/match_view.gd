class_name MatchView
extends Node

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
@onready var _hud: Hud = $Hud
@onready var _screen: PostProcess = $PostProcess
var _radar: Minimap
var _symbol: Label
var _time_of_day: Label
var _mode: MatchFrame.Mode

func mount(world: WorldView, map: Dictionary,
		mode: MatchFrame.Mode, clock: MatchFrame.Clock, radar: bool) -> void:
	_mode = mode
	_world = world
	camera.zoom = Vector2.ONE * CFG.cam_zoom
	var viewport: SubViewport = $WorldViewport
	var margin := Vector2(viewport.size) / (2.0 * camera.zoom) + Vector2.ONE * CFG.cam_seam_margin
	_mount_backgrounds(viewport, map, margin)
	terrain_view.install(map, margin)
	var size := Vector2(map.size * CyrmMap.CELL_SIZE)
	_world.bind($WorldViewport/Canvas, size)
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
	# 时间模式符号(◁◁/▶▶)只用 v2 的 UiDesign.label + 字号 token,不再走旧 UiFactory:
	# 32×2=64(单人中央巨字)/ T_H1=48(联机顶部),两者都在像素字体 16 倍数网格上。
	# 不新增 TimeSymbolHud 文件:本符号只有"文字 + 颜色 + 呼吸透明度"三件事,再包一层组件没有收益。
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
	if _mode == MatchFrame.Mode.SOLO:
		Sfx.pitch_mult = 1.0
