class_name Minimap
extends CanvasLayer

# 小地图(可选视觉):以玩家为中心的圆形视野。地形由 ui/minimap_circle.gdshader 画圆(圆外直接 discard),敌人点只在圆内(世界距离 <= RANGE_CELLS 格)才显示;由 pvp_client / royale_game / team_game 按设置挂载。
# ★ 环面:地形靠采样器 repeat_enable 免费回绕;敌人距离走 toroidal_delta_px 的最短向量 —— 玩家在接缝附近时地图另一头的敌人其实就在身边,直接相减会判成"很远"而误藏。

const RADIUS_PX := 140.0    # 圆在屏幕上的半径(像素)
# 圆覆盖的世界半径(格)。★ 调"圆形范围"只改这一行:它不改变圆在屏幕上的大小,只改圆里的缩放(每格像素 = RADIUS_PX / RANGE_CELLS,当前 2.8px/格)。
# 标定参照:屏幕能看到 46×36 格、1v1 两出生点环面最短距离 34 格;50 → 半径 3200 世界像素 ≈ 2.2 个屏宽,是"雷达"而非"缩略图"。
const RANGE_CELLS := 50.0
const PX_PER_CELL := RADIUS_PX / RANGE_CELLS
const EDGE := 24.0          # 圆的外接方框距屏幕**右**边缘
# 距屏幕下边缘的留白。★ 必须比 EDGE 大得多 —— 右下角是延迟条(PingWrap 锚在离下边 24px 处、向上生长),而小地图 layer 131 画在 PvpHud(130) 之上 ⇒ 旧缩略图碰不到它,换成 280×280 的圆会盖住延迟数字。
# ★ 这个数是算出来的不是拍的:延迟条 font_size 32、锚在离下边 24px 向上生长,实测其矩形上沿 y=1367、左沿 x=1784;圆心 (1756, 1300-EDGE_BOTTOM)、半径 140
#   ⇒ "不压到"要求 28² + (1367-cy)² > 140² ⇒ EDGE_BOTTOM > 70.17;用户要 70(恰好差 0.2px 擦到),取 72 留 1.5px 余量。★ 改延迟条字号/文案/锚点或改 RADIUS_PX 都必须重算这个数;零守卫(原 tests/manual/minimap_circle_probe 已删·2026-10-09)。
const EDGE_BOTTOM := 72.0
const RING_PX := 4.0        # 圆内缘描边宽度(2026-09-17:2 → 4,用户要求"加粗")
const RING_SELF_PX := 4.0   # "我"那个点的白描边宽度(四边各 4px ⇒ 点 8×8、描边框 16×16)

const SHADER_PATH := "res://ui/hud/minimap_circle.gdshader"
const SELF_COLOR := Color(0.6, 0.95, 1.0)
const ENEMY_COLOR := Color(1.0, 0.4, 0.35)

var _local_provider: Callable = Callable()   # () -> Vector2 本地玩家世界坐标
var _enemy_provider: Callable = Callable()   # () -> Vector2 对手世界坐标(INF=无)
# 多目标模式(大乱斗):others_provider () -> Array[Vector2],按需扩点位池
var _others_provider: Callable = Callable()
# 多目标模式(3v3)的可选颜色提供器:() -> Array[Color],与 _others_provider 的返回同序。★ 可选:1v1 / 大乱斗不传 ⇒ 默认 Callable() = 不回填颜色、点位保持 ENEMY_COLOR,两者行为逐字不变。
var _color_provider: Callable = Callable()
# 3v3 的"我"那个点:队色提供器 () -> Color,可选第四参。★ 必须是每帧求值的 Callable 而不是建点时定下的 Color:队色由 match_sync 下发、比小地图建立晚;不传 ⇒ 自己那个点走 SELF_COLOR,1v1 / 大乱斗行为逐字不变。
var _self_color_provider: Callable = Callable()
# 自己那个点的白描边。★ 同队同色时颜色本身分不出"我"与队友,故需要一个与颜色正交的维度 —— 去掉它就等于没修;1v1 / 大乱斗不显示它。
var _ring_self: ColorRect
var _mat: ShaderMaterial = null
var _rect_pos := Vector2.ZERO
var _dot_self: ColorRect
var _dot_enemy: ColorRect
var _other_dots: Array[ColorRect] = []


func setup(local_provider: Callable, enemy_provider: Callable) -> void:
	_local_provider = local_provider
	_enemy_provider = enemy_provider


# 多目标版(大乱斗 N 人 / 3v3 六人):others_provider 返回全部对手世界坐标数组。★★ 四个参数全部必填:两个颜色提供器原先带默认值 ⇒ "谁给这些点上色"在调用点上是隐式的,
# 而大乱斗的答案曾经是"没人给"(恒 ENEMY_COLOR),那个状态与"写了新模式但忘了传"长得一模一样;现在每个调用点都必须说出来(真要恒 ENEMY_COLOR 就显式传 Callable())。
# ★ color_provider 返回与 others 一一对应的颜色数组。★★ 两个提供器必须共用同一套过滤,不只是"同序":按下标取色时"某个副本已 queue_free、尚未从表里摘掉"那个窗口会让两个数组错位一格,而不报错。
func setup_multi(local_provider: Callable, others_provider: Callable,
		color_provider: Callable, self_color_provider: Callable) -> void:
	_local_provider = local_provider
	_others_provider = others_provider
	_color_provider = color_provider
	_self_color_provider = self_color_provider


func _ready() -> void:
	layer = 131   # 盖在 PvpHud(130) 之上、不影响输入
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		set_process(false)
		return
	var cols: int = grid[0].size()
	var rows: int = grid.size()

	# 地形底图:墙=亮灰,水=蓝,空气=深色半透明(1 像素 = 1 格,着色器按 PX_PER_CELL 放大)
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

	_rect_pos = Vector2(1920.0 - EDGE - RADIUS_PX * 2.0, 1440.0 - EDGE_BOTTOM - RADIUS_PX * 2.0)

	_mat = ShaderMaterial.new()
	_mat.shader = load(SHADER_PATH)
	_mat.set_shader_parameter("map_tex", ImageTexture.create_from_image(img))
	_mat.set_shader_parameter("map_size", Vector2(float(cols), float(rows)))
	_mat.set_shader_parameter("px_per_cell", PX_PER_CELL)
	_mat.set_shader_parameter("radius", RADIUS_PX)
	_mat.set_shader_parameter("ring", RING_PX)

	var view := ColorRect.new()
	view.name = "Circle"
	view.material = _mat
	view.position = _rect_pos
	view.size = Vector2(RADIUS_PX, RADIUS_PX) * 2.0
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(view)

	# ★ 描边先建、点后建:Godot 的绘制顺序 = 子节点顺序,后建的在上层 ⇒ 点压在框上。
	_ring_self = _make_dot(Color(1.0, 1.0, 1.0, 1.0))
	_ring_self.size = Vector2(8, 8) + Vector2(RING_SELF_PX, RING_SELF_PX) * 2.0
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
	var p := Vector2.INF
	if _local_provider.is_valid():
		p = _local_provider.call()
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	if not p.is_finite() or w <= 0.0 or h <= 0.0:
		_dot_self.visible = false
		_ring_self.visible = false
		_dot_enemy.visible = false
		for d in _other_dots:
			d.visible = false
		return
	var canonical := MazeGenerator.wrap_to_range(p, w, h)
	_mat.set_shader_parameter("center_cell", canonical / float(GameParameters.TILE_SIZE))

	_dot_self.visible = true
	_dot_self.position = _circle_center() - _dot_self.size * 0.5
	# ★ 3v3(有自色提供器):自己的点 = 队色(与身体 / 头顶 ID 同源)+ 一圈白描边;1v1 / 大乱斗不传它 ⇒ use_team_self 为假 ⇒ 走 SELF_COLOR,行为逐字不变。
	var use_team_self := _self_color_provider.is_valid()
	if use_team_self:
		_dot_self.color = _self_color_provider.call()
		_ring_self.visible = true
		_ring_self.position = _circle_center() - _ring_self.size * 0.5
	else:
		_ring_self.visible = false

	if _others_provider.is_valid():
		# 多目标(大乱斗 / 3v3):按需扩池,显隐随设置 + 范围
		var others: Array = _others_provider.call()
		# ★ 队色每帧回填(不是建点时定色):match_sync 到得比小地图晚,建点时还拿不到队色。
		var cols: Array = _color_provider.call() if _color_provider.is_valid() else []
		while _other_dots.size() < others.size():
			_other_dots.append(_make_dot(ENEMY_COLOR))
		for i in range(_other_dots.size()):
			if i < cols.size():
				(_other_dots[i] as ColorRect).color = cols[i]
			_place_enemy_dot(_other_dots[i], others[i] if i < others.size() else Vector2.INF, p, w, h)
		return
	if _dot_enemy != null and _enemy_provider.is_valid():
		_place_enemy_dot(_dot_enemy, _enemy_provider.call(), p, w, h)


func _circle_center() -> Vector2:
	return _rect_pos + Vector2(RADIUS_PX, RADIUS_PX)


# 敌人点:环面最短向量 → 圆心偏移;超出半径(即世界距离 > RANGE_CELLS 格)不显示。
func _place_enemy_dot(dot: ColorRect, enemy: Vector2, player: Vector2, w: float, h: float) -> void:
	if not Settings.pvp_minimap_show_enemy or not enemy.is_finite():
		dot.visible = false
		return
	# ★ 参数顺序:toroidal_delta_px(a, b, …) 返回 a→b,故是 (玩家, 敌人)
	var d := GridPathfinder.toroidal_delta_px(player, enemy, w, h)   # 世界像素
	var s := d / float(GameParameters.TILE_SIZE) * PX_PER_CELL       # 圆心 → 该点的屏幕像素
	if s.length() > RADIUS_PX:
		dot.visible = false
		return
	dot.visible = true
	dot.position = _circle_center() + s - dot.size * 0.5
