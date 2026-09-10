class_name Minimap
extends CanvasLayer

# 小地图(可选视觉,实验分支 KikuchiHeinr):地形静态底图(格子 2px)+ 玩家/敌人实时位置点。
# 由 pvp_client 按设置挂载;敌人点显隐由子选项控制。位置点用 wrap_to_range 归 canonical,
# 底图即 canonical [0,MAP) 的等比缩放。

const CELL_PX := 2.0        # 每格像素
const EDGE := 24.0          # 距屏幕右/下边缘

var _map_px := Vector2.ZERO
var _dot_self: ColorRect
var _dot_enemy: ColorRect
var _local_provider: Callable = Callable()   # () -> Vector2 本地玩家世界坐标
var _enemy_provider: Callable = Callable()   # () -> Vector2 对手世界坐标(INF=无)
# 多目标模式(大乱斗):others_provider () -> Array[Vector2],按需扩点位池
var _others_provider: Callable = Callable()
var _other_dots: Array[ColorRect] = []

const SELF_COLOR := Color(0.6, 0.95, 1.0)
const ENEMY_COLOR := Color(1.0, 0.4, 0.35)


func setup(local_provider: Callable, enemy_provider: Callable) -> void:
	_local_provider = local_provider
	_enemy_provider = enemy_provider


# 大乱斗多目标版:others_provider 返回全部对手世界坐标数组
func setup_multi(local_provider: Callable, others_provider: Callable) -> void:
	_local_provider = local_provider
	_others_provider = others_provider


func _ready() -> void:
	layer = 131   # 盖在 PvpHud(130) 之上、不影响输入
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		set_process(false)
		return
	var cols: int = grid[0].size()
	var rows: int = grid.size()
	_map_px = Vector2(cols, rows) * CELL_PX

	# 地形底图:墙=亮灰,水=蓝,空气=深色半透明(像素风 filter_nearest)
	var img := Image.create(cols, rows, false, Image.FORMAT_RGBA8)
	for y in range(rows):
		for x in range(cols):
			var v: int = grid[y][x]
			if v == MazeGenerator.EMPTY:
				img.set_pixel(x, y, Color(0.05, 0.09, 0.13, 0.55))
			elif Water.is_liquid(MazeGenerator.texture_of(v)):
				img.set_pixel(x, y, Color(0.15, 0.38, 0.85, 0.85))
			else:
				img.set_pixel(x, y, Color(0.62, 0.68, 0.75, 0.95))
	var map_rect := TextureRect.new()
	map_rect.texture = ImageTexture.create_from_image(img)
	map_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	map_rect.stretch_mode = TextureRect.STRETCH_SCALE
	map_rect.position = Vector2(1920.0 - EDGE - _map_px.x, 1440.0 - EDGE - _map_px.y)
	map_rect.size = _map_px
	map_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(map_rect)

	_dot_self = _make_dot(SELF_COLOR)
	_dot_enemy = _make_dot(ENEMY_COLOR)


func _make_dot(color: Color) -> ColorRect:
	var d := ColorRect.new()
	d.color = color
	d.size = Vector2(8, 8)
	d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	d.visible = false
	add_child(d)
	return d


func _process(_delta: float) -> void:
	if _dot_self == null:
		return
	if _local_provider.is_valid():
		var p: Vector2 = _local_provider.call()
		if p.is_finite():
			_dot_self.visible = true
			_dot_self.position = _world_to_map(p) - _dot_self.size * 0.5
	if _others_provider.is_valid():
		# 多目标(大乱斗):按需扩池,显隐随设置
		var others: Array = _others_provider.call()
		while _other_dots.size() < others.size():
			_other_dots.append(_make_dot(ENEMY_COLOR))
		for i in range(_other_dots.size()):
			var dot := _other_dots[i]
			var show := Settings.pvp_minimap_show_enemy and i < others.size() \
					and (others[i] as Vector2).is_finite()
			dot.visible = show
			if show:
				dot.position = _world_to_map(others[i]) - dot.size * 0.5
		return
	if _dot_enemy != null and _enemy_provider.is_valid():
		var e: Vector2 = _enemy_provider.call()
		var show := Settings.pvp_minimap_show_enemy and e.is_finite()
		_dot_enemy.visible = show
		if show:
			_dot_enemy.position = _world_to_map(e) - _dot_enemy.size * 0.5


# 世界坐标(可能是接缝副本)→ 小地图像素:先归 canonical,再按地图尺寸等比缩放。
func _world_to_map(world: Vector2) -> Vector2:
	var c := MazeGenerator.wrap_to_range(world, GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	var nx := c.x / maxf(GameParameters.MAP_WIDTH, 1.0)
	var ny := c.y / maxf(GameParameters.MAP_HEIGHT, 1.0)
	return Vector2(1920.0 - EDGE - _map_px.x, 1440.0 - EDGE - _map_px.y) + Vector2(nx, ny) * _map_px
