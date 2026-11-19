class_name EditorCanvas
extends Control

# P2 编辑器画布:把 EditorDoc 的地图渲染成一张与 canvas 等大的离屏图像(视口离屏层),并把鼠标事件
# 翻译成子格坐标。**不实现工具语义** —— 工具在 editor_root.gd,本文件只发 pointer_* 事件。
# 契约见 docs/systems/editor/editor-godot.md §3。
# ★ 本脚本进客户端导出包 ⇒ 禁止 RegEx(裁剪模板 module_regex_enabled=false);本文件不需要正则。
#
# 渲染:层号倒序(背景 25% → 前景)合成到 RGBA8 Image;纹理层用 TerrainAtlas 的 16px 象限制图集
#   (象限列 = (sy%4)*4 + (sx%4),行 = row_of[desc];按 zoom 先整张 INTERPOLATE_NEAREST 缩放一次,
#   再逐子格 blend),颜色层按子格填 rgba(u32),空气露出 SKY_COLOR。非 active 层 alpha 调低。
# 相机:origin = 画布左上角对应的世界子格坐标(可负/小数;渲染按 posmod 取环面样本),
#   zoom = 每子格屏幕像素(默认 16,档位 ZOOM_STEPS)。滚轮以鼠标为锚缩放,中键/空格拖动平移;
#   center_on_subcell 把指定子格放到画布中心(不改 zoom),minimap_rect 给出右上角小地图的屏幕矩形。
#
# 脏区刷新(T2 后置项):doc.changed 只把变更子格的包围盒交给 refresh_region —— 它把 bbox
#   按 ±sub_cols/±sub_rows 平移到各环面副本、与画布求交,只重画这些屏幕块(块内仍按全量
#   的层序/坐标公式重放),结果与整张 refresh() 逐像素一致(场景探针逐字节比较)。bbox 面积
#   超过半图或图集因新 desc 重建(图集行号全变)时退回全量 refresh()。
# 叠加层(不进视口图):选区虚线框 + meta 标记(出生点 P1/P2…、复活点 R1 深绿 / R2 深橙、
#   敌人红点+类型首字母);标记按屏幕像素大小画,不随 zoom 变大。另有:meta 放置模式抑制画刷框、
#   渐变预览(虚线 + 两端点,a/b 异色;只画不写 doc)、右上角小地图(地图范围 / meta 小点 /
#   当前视口矩形;右键小地图 = 把点击子格居中,不发 pointer_*)。
#
# 去掉什么它才会红(tests/scene/editor_canvas_probe.gd 逐条守):
#   ① 不建离屏纹理 / 尺寸错 ⇒ view_texture 断言红;
#   ② screen_to_subcell 不用 floor 或漏 origin ⇒ 手算 3 点红;
#   ③ 缩放不以鼠标为锚 ⇒ 锚点子格变了红;
#   ④ 不判 layer_visible / active 不恒可见 ⇒ 层可见性与隐藏后像素红;
#   ⑤ 不重标 alpha(非 active 层)⇒ 颜色像素不是 0.45 混合红;
#   ⑥ 纹理层不 blit 图集 ⇒ 纹理格全是底色红;
#   ⑦ 左键没翻译成子格事件 ⇒ pointer_down 断言红;
#   ⑧ 新 desc 不重建图集 / blit 回落中性行 ⇒ descs() 缺项或变体像素同色红;
#   ⑨ 无 doc / 空图 refresh() 崩或产不出纹理 ⇒ 条数闸 + 纹理断言红;
#   ⑩ 脏区刷新漏环面副本 / 与全量不一致 ⇒ 逐字节比较红(跨接缝组);
#   ⑪ 选区/meta 标记几何错或 view_image 不返回副本 ⇒ 对应断言红。
#   ⑫ 手形工具/空格拖不平移,或平移时仍发 pointer_* ⇒ 手形断言红;
#   ⑬ 移动工具拖选区不算 delta / 不夹地图边界 / 不发 finished ⇒ 移动断言红;
#   ⑭ meta 标记命中测试错 / 拖拽不跟鼠标 / 落点不是格坐标 ⇒ meta 拖拽断言红。
#   ⑮ meta 放置模式标志/光标失效,或该模式吞掉/丢失 pointer_* ⇒ ⑳ 组红;
#   ⑯ 渐变预览写进视口图(不是纯叠加层)或 active/clear 开关失灵 ⇒ ㉑ 组红;
#   ⑰ 小地图 rect 越界或空图非零、右键不跳转或误发 pointer_*、center_on_subcell 不居中
#      ⇒ ㉒/㉓/㉔ 组红。
# class_name 行已由 Lead 预注册:别改(全局类缓存按名字解析)。

const OVERLAY_SCRIPT := preload("res://scenes/editor/editor_canvas_overlay.gd")
const IMAGE_SCRIPT := preload("res://scenes/editor/editor_canvas_image.gd")
const VIEW_SCRIPT := preload("res://scenes/editor/canvas_view.gd")

var _overlay = OVERLAY_SCRIPT.new()    # 叠加层绘制(不持状态,画时读本对象)
var _image = IMAGE_SCRIPT.new()        # 图集/层合成(操作本对象的 _atlas_* 缓存)
var _view = VIEW_SCRIPT.new()          # 视图变换(缩放/平移/坐标换算;相机状态仍在本对象)

const ZOOM_STEPS := [4.0, 8.0, 12.0, 16.0, 24.0, 32.0, 48.0, 64.0]
const ZOOM_DEFAULT := 16.0
const INACTIVE_ALPHA := 0.45        # 非 active 层被压暗到多少(契约 §4)
const QUAD_COLS := 16               # TerrainAtlas 图集列数 = 4×4 象限
const QUAD_TILE := 16               # TerrainAtlas 图集每象限像素(16px = 1 子格)
const SUB_PER_CELL := 4             # 1 格 = 4×4 子格(与 EditorConstants.SUB_PER_CELL 一致)
const BG_COLOR := Color("2f4256")   # = TerrainAtlas.SKY_COLOR,空气露出的底色
const GRID_COLOR := Color(1.0, 1.0, 1.0, 0.07)
const SEAM_COLOR := Color(0.35, 0.95, 1.0, 0.35)   # 环面接缝(地图 0 边)高亮
const ERASER_COLOR := Color(1.0, 0.35, 0.35, 1.0)
const BRUSH_MAX_CELLS := 32

# 叠加层(选区 / meta 标记)一律屏幕像素尺寸,不随 zoom 变。
const SELECTION_LINE_COLOR := Color(0.85, 0.98, 1.0, 0.95)
const SELECTION_FILL_COLOR := Color(0.30, 0.90, 1.0, 0.12)
const META_PLAYER_COLOR := Color(0.20, 0.90, 1.0, 1.0)      # 出生点 = 青方块
const META_RESPAWN1_COLOR := Color(0.06, 0.35, 0.08, 1.0)   # 复活点侧 1 = 深绿
const META_RESPAWN2_COLOR := Color(0.55, 0.30, 0.02, 1.0)   # 复活点侧 2 = 深橙
const META_ENEMY_COLOR := Color(1.0, 0.25, 0.25, 1.0)       # 敌人 = 红点
const META_FONT_SIZE := 10
const META_ENEMY_RADIUS := 6.0
const META_SQUARE := 10.0
const META_HIT_RADIUS := 14.0       # 移动工具命中 meta 标记的半径(屏幕 px;标记本身只有 10px)
const META_ENEMY_HIT_MAX := 30.0    # 敌人贴图比红点大:命中半径按贴图宽的一半夹上限,拖起来才不别扭

# 渐变预览:虚线 + 两端点(a/b 异色)。只画在 _draw 叠加层,不进视口图、不写 doc。
const GRADIENT_LINE_COLOR := Color(0.75, 0.95, 1.0, 0.85)
const GRADIENT_A_COLOR := Color(0.20, 0.90, 1.0, 1.0)
const GRADIENT_B_COLOR := Color(1.0, 0.62, 0.18, 1.0)
const GRADIENT_DOT_RADIUS := 5.0
# 小地图:画布内右上角,margin 12;最大 180×120,按地图宽高比缩放;空图 = 零尺寸。
const MINIMAP_MARGIN := 12.0
const MINIMAP_MAX_W := 180.0
const MINIMAP_MAX_H := 120.0
const MINIMAP_BG_COLOR := Color(0.02, 0.05, 0.08, 0.72)
const MINIMAP_BORDER_COLOR := Color(0.55, 0.95, 1.0, 0.50)
const MINIMAP_VIEW_COLOR := Color(1.0, 1.0, 1.0, 0.65)
const MINIMAP_META_RADIUS := 1.2
const MINIMAP_ENEMY_ALPHA := 0.55      # 敌人点很多(一张图 60+):压暗压小,小地图不抢画布主视口

signal pointer_down(sub: Vector2i, button: int, shift: bool, ctrl: bool)
signal pointer_drag(sub: Vector2i)
signal pointer_up(sub: Vector2i)
signal cursor_moved(sub: Vector2i)
signal zoom_changed(zoom: float)
# 移动工具:画布只负责「拖了几格」的几何与预览,真正写 doc 在 editor_tools(工具层)。
signal selection_move_started()
signal selection_move_finished(delta_sub: Vector2i)
signal meta_drag_started(kind: String, index: int)
signal meta_drag_finished(kind: String, index: int, cell: Vector2i)
# 移动工具下「单击出生点标记(没拖动)」= 从该点试玩当前地图(由 editor_root 接)。
signal player_playtest_requested(cell: Vector2i)

# 相机只读口(origin/zoom 由本文件维护;外部用 zoom_in/zoom_out/set_zoom/set_camera/fit_to_map/pan_pixels)。
var zoom: float:
	get:
		return _zoom
var origin: Vector2:
	get:
		return _origin

var _doc: EditorDoc = null
var _zoom := ZOOM_DEFAULT
var _origin := Vector2.ZERO
var _active_layer := 1
var _layer_visible: Array[bool] = [true, true, true, true, true, true, true]
var _brush_cells := 1
var _preview_desc := 0
var _preview_color := Color(1.0, 1.0, 1.0, 1.0)   # 颜色层(3-6)的画刷框颜色(工具层喂当前画笔色)
var _hover_sub := Vector2i.ZERO
var _has_hover := false

var _left_down := false
var _panning := false
var _space_held := false
var _pan_tool := false                 # 手形工具:左键直接平移(不落笔、不发 pointer_*)
var _move_tool := false                # 移动工具:拖选区内容 / 拖 meta 标记
var _moving_selection := false
var _move_origin_sub := Vector2i.ZERO
var _move_delta := Vector2i.ZERO
var _dragging_meta: Dictionary = {}    # 空 = 没在拖;否则 {kind, index, ...}
var _mouse_pos := Vector2.ZERO

var _view_tex: ImageTexture = null
var _view_img: Image = null                     # 视口图唯一真源(view_image() 拷贝它,脏区就地改它)
var _full_refreshes := 0                        # 刷新计数器:场景探针守「changed 必须走脏区」
var _region_refreshes := 0
var _draw_calls := 0                            # _draw 完成次数(探针守叠加层真跑通且幂等)

var _selection := Rect2i()                      # 子格矩形;size<=0 = 无选区(只画在 _draw 叠加层)
var _meta_visible := true                       # meta 标记开关(默认显示)
var _enemy_art_cache: Dictionary = {}           # 敌人 id → {tex, size, offset}(idle 贴图,见 enemy_art())
var _meta_mode_active := false                  # meta 放置模式:抑制画刷框 + 手形光标(不改 pointer_*)
var _gradient_active := false                   # 渐变预览:纯叠加层(不改 doc / 视口图)
var _gradient_a := Vector2i.ZERO
var _gradient_b := Vector2i.ZERO

var _atlas_img: Image = null
var _atlas_row_of := {}
var _atlas_descs: Array[int] = []
var _atlas_scaled: Image = null
var _atlas_scaled_dim: Image = null
var _atlas_scaled_cell := 0        # _atlas_scaled 里一个子格占几像素(== int(zoom))
var _color_stamps := {}


func _init() -> void:
	_view.bind(self)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_CROSS
	clip_contents = true
	if not resized.is_connected(_on_resized):
		resized.connect(_on_resized)
	refresh()


# ── 公开 API(editor_root 与场景探针消费)────────────────────────────

func set_doc(doc: EditorDoc) -> void:
	if _doc != null:
		if _doc.changed.is_connected(_on_doc_changed):
			_doc.changed.disconnect(_on_doc_changed)
		if _doc.structure_changed.is_connected(_on_doc_structure_changed):
			_doc.structure_changed.disconnect(_on_doc_structure_changed)
		if _doc.has_signal("meta_changed") and _doc.is_connected("meta_changed", _on_doc_meta_changed):
			_doc.disconnect("meta_changed", _on_doc_meta_changed)
	_doc = doc
	_selection = Rect2i()
	_atlas_img = null
	_atlas_row_of = {}
	_atlas_descs.clear()
	_atlas_scaled = null
	_atlas_scaled_dim = null
	_atlas_scaled_cell = 0
	if _doc != null:
		_doc.changed.connect(_on_doc_changed)
		_doc.structure_changed.connect(_on_doc_structure_changed)
		# meta_changed 由 T1(EditorDoc 后置项)提供;老版本 doc 没有该信号时降级为「刷新画布即重绘」。
		if _doc.has_signal("meta_changed"):
			_doc.connect("meta_changed", _on_doc_meta_changed)
		_active_layer = clampi(int(_doc.active_layer), 0, EditorConstants.LAYER_COUNT - 1)
		_image.ensure_atlas(self, true)
	refresh()


func view_texture() -> Texture2D:
	return _view_tex


## 当前图集里的描述符(去重排序;新 desc 出现后应包含它)。
func descs() -> Array[int]:
	return _atlas_descs.duplicate()


func set_active_layer(layer: int) -> void:
	var v := clampi(layer, 0, EditorConstants.LAYER_COUNT - 1)
	if v == _active_layer:
		return
	_active_layer = v
	refresh()


func get_active_layer() -> int:
	return _active_layer


func set_layer_visible(layer: int, vis: bool) -> void:
	if layer < 0 or layer >= EditorConstants.LAYER_COUNT:
		return
	if _layer_visible[layer] == vis:
		return
	_layer_visible[layer] = vis
	if layer != _active_layer:
		refresh()


## active 层恒可见(面板上打了叉也只是图例,不挡正在编辑的那层)。
func layer_visible(layer: int) -> bool:
	if layer < 0 or layer >= EditorConstants.LAYER_COUNT:
		return false
	if layer == _active_layer:
		return true
	return _layer_visible[layer]


func set_brush_preview(size_cells: int) -> void:
	_brush_cells = clampi(size_cells, 1, BRUSH_MAX_CELLS)
	queue_redraw()


func set_preview_desc(desc: int) -> void:
	_preview_desc = desc
	queue_redraw()


## 颜色层(3-6)的画刷框颜色:工具层喂当前画笔颜色(纹理层仍走 _preview_desc 的 tint)。
func set_preview_color(c: Color) -> void:
	_preview_color = c
	queue_redraw()


# 手形工具:左键+拖动 = 平移(任何工具下按住空格 / 中键拖也平移)。
func set_pan_tool(on: bool) -> void:
	_pan_tool = on
	if not on:
		_panning = false
	_refresh_cursor()
	queue_redraw()


func is_pan_tool() -> bool:
	return _pan_tool


# 移动工具:拖选区内容 / 拖 meta 标记;松手才写 doc(由工具层落点)。
func set_move_tool(on: bool) -> void:
	_move_tool = on
	if not on:
		_moving_selection = false
		_dragging_meta = {}
		_move_delta = Vector2i.ZERO
	_refresh_cursor()
	queue_redraw()


func is_move_tool() -> bool:
	return _move_tool


# meta 放置模式:面板点「放出生点/复活点/敌人」时打开 —— 抑制画刷框、光标变手形;
# 只影响叠加层与光标,**不改变 pointer_* 事件**(落点仍由工具层按 pointer_down 处理)。
func set_meta_mode_active(on: bool) -> void:
	if _meta_mode_active == on:
		return
	_meta_mode_active = on
	_refresh_cursor()
	queue_redraw()


func is_meta_mode_active() -> bool:
	return _meta_mode_active


# 渐变预览(只画不写):a/b 是子格坐标;on=false 等价于清空但保留端点(便于工具层复用)。
func set_gradient_preview(a_sub: Vector2i, b_sub: Vector2i, on: bool = true) -> void:
	_gradient_a = a_sub
	_gradient_b = b_sub
	_gradient_active = on
	queue_redraw()


func clear_gradient_preview() -> void:
	_gradient_active = false
	queue_redraw()


func gradient_preview_active() -> bool:
	return _gradient_active


# 屏幕坐标命中的 meta 标记(空字典 = 没命中)。只有移动工具会用它做拖拽。
func meta_marker_at(pos: Vector2) -> Dictionary:
	for m: Dictionary in meta_markers():
		var marker_pos: Vector2 = m["pos"]
		if marker_pos.distance_to(pos) <= _marker_hit_radius(m):
			return m
	return {}


# 命中半径:敌人贴图比红点大得多,按贴图宽度给(上限防拖一只鸟时框住邻近点)。
func _marker_hit_radius(m: Dictionary) -> float:
	if String(m.get("kind", "")) == "enemy":
		var art := enemy_art(String(m.get("type", "")))
		if not art.is_empty():
			var half: float = (art["size"] as Vector2).x * _zoom / float(EditorConstants.SUB_PX) * 0.5
			return clampf(half * 0.7, META_HIT_RADIUS, META_ENEMY_HIT_MAX)
	return META_HIT_RADIUS


# 敌人 idle 贴图:从游戏同一份敌人场景取默认动画首帧 + 根缩放,编辑器里看到的就是游戏里出生那一帧。
# 按 id 缓存;未知 id / 场景坏 ⇒ 空字典,调用方回退红点。
func enemy_art(type_id: String) -> Dictionary:
	if _enemy_art_cache.has(type_id):
		return _enemy_art_cache[type_id]
	var art: Dictionary = {}
	if type_id != "":
		if EnemySpawner.TYPES.is_empty():
			EnemySpawner.load_types()
		var scene_path := String(EnemySpawner.TYPES.get(type_id, ""))
		if scene_path != "":
			var packed := load(scene_path) as PackedScene
			if packed != null:
				var inst := packed.instantiate() as Node2D
				if inst != null:
					var spr := inst.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
					if spr != null and spr.sprite_frames != null \
							and spr.sprite_frames.get_animation_names().size() > 0:
						var anim := spr.animation
						if not spr.sprite_frames.has_animation(anim):
							anim = spr.sprite_frames.get_animation_names()[0]
						var tex := spr.sprite_frames.get_frame_texture(anim, 0)
						if tex != null:
							var xf := inst.transform * spr.transform
							var s := xf.get_scale()
							art = {"tex": tex, "size": tex.get_size() * s,
									"offset": xf.origin + spr.offset * s}
					inst.free()
	_enemy_art_cache[type_id] = art
	return art


# ── 选区 / meta 标记 / 视口图读取(叠加层,都不进视口图)────────────────

## 设置选区(子格矩形;w/h<=0 或空 Rect2i() = 清空)。只影响 _draw 叠加层。
func set_selection(sub_rect: Rect2i) -> void:
	_selection = _norm_rect(sub_rect)
	queue_redraw()


func get_selection() -> Rect2i:
	return _selection


## 选区在屏幕上的矩形(px);无选区返回 size 为 0 的 Rect2。
func selection_screen_rect() -> Rect2:
	if _selection.size.x <= 0 or _selection.size.y <= 0:
		return Rect2()
	return Rect2(subcell_to_screen(_selection.position), Vector2(_selection.size) * _zoom)


## 显示/隐藏 meta 标记(默认显示)。
func set_meta_visible(on: bool) -> void:
	_meta_visible = on
	queue_redraw()


func get_meta_visible() -> bool:
	return _meta_visible


## 当前视口图的一份拷贝(像素判据/截图用;改它不影响画布内部状态)。
## ★ 用这个而不是 view_texture().get_image():纹理走 update() 上传后 CPU 侧 image_storage 是旧的。
func view_image() -> Image:
	if _view_img == null:
		return null
	return _view_img.duplicate()


## meta 标记列表(屏幕 px,固定像素大小)。空数组 = 没有 meta 或标记被隐藏。
## 元素:{kind:"player"|"respawn"|"enemy", index:int, label:String, pos:Vector2, side:int,
##        cell:Vector2i, type:String(仅敌人)}
## index = 该标记在对应 map 数组(players/respawns/enemies)里的下标 ⇒ 移动工具拖拽时能回写同一条。
func meta_markers() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not _meta_visible or _doc == null:
		return out
	var map: Dictionary = _doc.map
	if map.is_empty():
		return out
	var players: Array = map.get("players", [])
	for i in players.size():
		var p: Variant = players[i]
		if not (p is Dictionary):
			continue
		var pd: Dictionary = p
		var pc := Vector2i(int(pd.get("x", 0)), int(pd.get("y", 0)))
		out.append({"kind": "player", "index": i, "label": "P%d" % (i + 1), "side": 0,
				"cell": pc, "type": "", "pos": _cell_center_screen(pc)})
	var respawns: Array = map.get("respawns", [])
	for i in respawns.size():
		var r: Variant = respawns[i]
		if not (r is Dictionary):
			continue
		var rd: Dictionary = r
		var side := int(rd.get("side", 0))
		var rc := Vector2i(int(rd.get("x", 0)), int(rd.get("y", 0)))
		out.append({"kind": "respawn", "index": i, "label": "R%d" % side, "side": side,
				"cell": rc, "type": "", "pos": _cell_center_screen(rc)})
	var enemies: Array = map.get("enemies", [])
	for i in enemies.size():
		var e: Variant = enemies[i]
		if not (e is Dictionary):
			continue
		var ed: Dictionary = e
		var t := String(ed.get("type", ""))
		var ec := Vector2i(int(ed.get("x", 0)), int(ed.get("y", 0)))
		out.append({"kind": "enemy", "index": i, "label": t.substr(0, 1).to_upper() if t != "" else "?",
				"side": 0, "cell": ec, "type": t, "pos": _cell_center_screen(ec)})
	return out


## 格坐标 → 格中心在屏幕上的像素位置(标记锚点)。
func _cell_center_screen(cell: Vector2i) -> Vector2:
	return _view._cell_center_screen(cell)


# ── 相机 ──────────────────────────────────────────────────────────────

## 屏幕(画布内)坐标 → 世界子格。可能为负/超出地图;环面归一化由调用方(EditorDoc)做。
func screen_to_subcell(pos: Vector2) -> Vector2i:
	return _view.screen_to_subcell(pos)


func subcell_to_screen(sub: Vector2i) -> Vector2:
	return _view.subcell_to_screen(sub)


## 小地图的屏幕矩形(画布内右上角,margin 12;最大 180×120,按地图宽高比缩放)。
## 空图(无 doc / 地图尺寸为 0)或画布太小放不下时返回零尺寸 Rect2。
func minimap_rect() -> Rect2:
	var sub := _sub_size()
	var inner := Vector2(size) - Vector2(MINIMAP_MARGIN, MINIMAP_MARGIN) * 2.0
	if sub.x <= 0 or sub.y <= 0 or inner.x <= 0.0 or inner.y <= 0.0:
		return Rect2()
	var max_w := minf(MINIMAP_MAX_W, inner.x)
	var max_h := minf(MINIMAP_MAX_H, inner.y)
	if max_w <= 0.0 or max_h <= 0.0:
		return Rect2()
	# 先按宽撑满再按高收;极端宽高比时两轴都夹到 >=1px(非空图不允许零尺寸)。
	var w := max_w
	var h := w * float(sub.y) / float(sub.x)
	if h > max_h:
		h = max_h
		w = h * float(sub.x) / float(sub.y)
	w = clampf(w, 1.0, max_w)
	h = clampf(h, 1.0, max_h)
	return Rect2(Vector2(size.x - MINIMAP_MARGIN - w, MINIMAP_MARGIN), Vector2(w, h))


## 以屏幕点为锚缩放到下一个/上一个档位(direction = +1 放大 / -1 缩小)。
## 锚点下的子格保持不变(screen_to_subcell(at) 前后相等)。
func zoom_at_screen(at: Vector2, direction: int) -> void:
	_view.zoom_at_screen(at, direction)


func zoom_in() -> void:
	_view.zoom_in()


func zoom_out() -> void:
	_view.zoom_out()


## 直接设档位(贴到最近档);锚点 = 画布中心。
func set_zoom(value: float) -> void:
	_view.set_zoom(value)


## 重置相机(origin = 世界子格,zoom 贴到最近档);主要给场景探针/root 复位用。
func set_camera(new_origin: Vector2, new_zoom: float) -> void:
	_view.set_camera(new_origin, new_zoom)


func pan_pixels(delta: Vector2) -> void:
	_view.pan_pixels(delta)


## 把该世界子格放到画布中心(不改 zoom;负坐标/越界按原值平移,环面由渲染的 posmod 处理)。
func center_on_subcell(sub: Vector2i) -> void:
	_view.center_on_subcell(sub)


## 让整张地图尽量大地放进画布并居中;空图复位到默认档 + 原点。
func fit_to_map() -> void:
	_view.fit_to_map()


# ── 刷新:全量 / 脏区 ─────────────────────────────────────────────────

func refresh() -> void:
	_full_refreshes += 1
	_render_full()
	_publish_view()


## 刷新计数器(场景探针守「doc.changed 必须走脏区刷新」;正常 UI 不使用)。
func refresh_counters() -> Dictionary:
	return {"full": _full_refreshes, "region": _region_refreshes}


## _draw 完成次数(场景探针守叠加层绘制路径真跑通;正常 UI 不使用)。
func get_draw_calls() -> int:
	return _draw_calls


## 只重画该子格矩形在**可见屏幕**上的部分(含环面副本)。结果必须与整张 refresh() 逐像素一致:
## 块内仍按「填底色 → 层号倒序重放」的同一套公式,只是限制在脏块上。
func refresh_region(sub_rect: Rect2i) -> void:
	var sub := _sub_size()
	if _doc == null or _view_img == null or sub.x <= 0 or sub.y <= 0:
		refresh()
		return
	var r := _norm_rect(sub_rect)
	if r.size.x <= 0 or r.size.y <= 0:
		return
	var regions := _region_screen_rects(r, sub)
	if regions.is_empty():
		return
	if _atlas_img == null:
		_image.ensure_atlas(self, true)
	_image.ensure_scaled_atlas(self)
	_color_stamps.clear()
	_region_refreshes += 1
	for reg in regions:
		_redraw_screen_region(reg, sub)
	_publish_view()


## 脏矩形在世界坐标里的所有环面副本(按 sub_cols/sub_rows 平移),各自投影到屏幕后与画布求交。
## ★ k 的上下界按「画布可见世界范围」动态算,不能写死 ±1:小图(地图比画布小)时同一份脏区
##   会在屏幕上平铺出很多份(例如 1 格图 64px 在 256px 画布上有 4 份),漏一份就与全量不一致。
func _region_screen_rects(r: Rect2i, sub: Vector2i) -> Array[Rect2i]:
	var out: Array[Rect2i] = []
	var w := _view_img.get_width()
	var h := _view_img.get_height()
	var kx_lo := floori((_origin.x - float(r.position.x) - float(r.size.x)) / float(sub.x))
	var kx_hi := ceili((_origin.x + float(w) / _zoom - float(r.position.x)) / float(sub.x))
	var ky_lo := floori((_origin.y - float(r.position.y) - float(r.size.y)) / float(sub.y))
	var ky_hi := ceili((_origin.y + float(h) / _zoom - float(r.position.y)) / float(sub.y))
	for ky: int in range(ky_lo, ky_hi + 1):
		for kx: int in range(kx_lo, kx_hi + 1):
			var wx := r.position.x + kx * sub.x
			var wy := r.position.y + ky * sub.y
			var x0 := clampi(roundi((float(wx) - _origin.x) * _zoom), 0, w)
			var y0 := clampi(roundi((float(wy) - _origin.y) * _zoom), 0, h)
			var x1 := clampi(roundi((float(wx + r.size.x) - _origin.x) * _zoom), 0, w)
			var y1 := clampi(roundi((float(wy + r.size.y) - _origin.y) * _zoom), 0, h)
			if x1 > x0 and y1 > y0:
				out.append(Rect2i(x0, y0, x1 - x0, y1 - y0))
	return out


## 重画一块屏幕矩形:建同尺寸临时图(填底色),按全量同款公式重放覆盖它的子格,再拷回视口图。
func _redraw_screen_region(reg: Rect2i, sub: Vector2i) -> void:
	var temp := Image.create(reg.size.x, reg.size.y, false, Image.FORMAT_RGBA8)
	temp.fill(BG_COLOR)
	# 屏幕像素 → 世界子格;round 与 floor 在块边界可能差 1 格 ⇒ 四周各扩 1 格保证覆盖。
	var wx0 := floori(_origin.x + float(reg.position.x) / _zoom) - 1
	var wy0 := floori(_origin.y + float(reg.position.y) / _zoom) - 1
	var wx1 := floori(_origin.x + float(reg.position.x + reg.size.x) / _zoom) + 1
	var wy1 := floori(_origin.y + float(reg.position.y + reg.size.y) / _zoom) + 1
	_image.paint_layers(self, temp, sub, Rect2i(wx0, wy0, wx1 - wx0 + 1, wy1 - wy0 + 1), -reg.position)
	_view_img.blit_rect(temp, Rect2i(Vector2i.ZERO, reg.size), reg.position)


func _render_full() -> void:
	var w := maxi(1, int(round(size.x)))
	var h := maxi(1, int(round(size.y)))
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(BG_COLOR)
	var sub := _sub_size()
	if _doc != null and sub.x > 0 and sub.y > 0:
		if _atlas_img == null:
			_image.ensure_atlas(self, true)
		_image.ensure_scaled_atlas(self)
		_color_stamps.clear()
		_image.paint_layers(self, img, sub, _visible_sub_rect(), Vector2i.ZERO)
	_view_img = img


## 把视口图发布成纹理。★ 用 update() 而不是每次重建 RID:像素判据请走 view_image()
## (update() 不刷新 ImageTexture 的 CPU 侧 image_storage,get_image() 会读到旧像素)。
func _publish_view() -> void:
	if _view_img == null:
		return
	var want := Vector2(_view_img.get_width(), _view_img.get_height())
	if _view_tex == null or _view_tex.get_size() != want:
		_view_tex = ImageTexture.create_from_image(_view_img)
	else:
		_view_tex.update(_view_img)
	queue_redraw()


func _sub_size() -> Vector2i:
	return _view._sub_size()


func _visible_sub_rect() -> Rect2i:
	return _view._visible_sub_rect()


## 负宽/负高的 Rect2i 归一成「左上角 + 正尺寸」;0 尺寸保持 0(调用方按无选区/无脏区处理)。
static func _norm_rect(r: Rect2i) -> Rect2i:
	var x0 := mini(r.position.x, r.position.x + r.size.x)
	var y0 := mini(r.position.y, r.position.y + r.size.y)
	return Rect2i(x0, y0, absi(r.size.x), absi(r.size.y))


func _on_doc_changed(layer: int, subcells: PackedInt32Array) -> void:
	var sub := _sub_size()
	if _doc == null or sub.x <= 0 or sub.y <= 0:
		refresh()
		return
	# 出现新 desc ⇒ 图集重建后**所有行号都可能平移** ⇒ 必须全量刷新(不能只刷脏区)。
	if _image.refresh_atlas_for(self, layer, subcells):
		refresh()
		return
	# changed 的 subcells 是已归一化 idx ⇒ 直接 min/max 得包围盒(环面绕回由 refresh_region 平移副本处理)。
	var min_x := sub.x
	var min_y := sub.y
	var max_x := -1
	var max_y := -1
	var n := sub.x * sub.y
	for raw_idx in subcells:
		var idx := int(raw_idx)
		if idx < 0 or idx >= n:
			continue
		var cx := idx % sub.x
		var cy := idx / sub.x
		min_x = mini(min_x, cx)
		max_x = maxi(max_x, cx)
		min_y = mini(min_y, cy)
		max_y = maxi(max_y, cy)
	if max_x < 0 or max_y < 0:
		refresh()
		return
	var bbox := Rect2i(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)
	# bbox 面积 > 整图 1/2(跨接缝的大笔画/全选清除)⇒ 区域重画不比全量便宜,退回全量。
	if bbox.size.x * bbox.size.y * 2 > sub.x * sub.y:
		refresh()
	else:
		refresh_region(bbox)


func _on_doc_structure_changed() -> void:
	_image.ensure_atlas(self, true)
	refresh()


## meta(出生点/复活点/敌人)只影响 _draw 叠加层,视口图不变 ⇒ 只请求重绘。
func _on_doc_meta_changed() -> void:
	queue_redraw()


func _on_resized() -> void:
	refresh()


# ── 绘制:视口纹理 + 网格 + 画刷框 ────────────────────────────────────

func _draw() -> void:
	if _view_tex != null and size.x > 0.0 and size.y > 0.0:
		draw_texture_rect(_view_tex, Rect2(Vector2.ZERO, size), false)
	_overlay.draw_grid(self)
	_overlay.draw_selection(self)
	_overlay.draw_move_preview(self)
	_overlay.draw_meta(self)
	_overlay.draw_gradient_preview(self)
	_overlay.draw_brush(self)
	_overlay.draw_minimap(self)
	_draw_calls += 1


# 移动工具命中测试(鼠标是否悬在可拖目标上):meta 标记优先,其次选区内部。
func _over_move_target(pos: Vector2) -> bool:
	if not meta_marker_at(pos).is_empty():
		return true
	return _doc != null and _doc.has_selection() and selection_screen_rect().has_point(pos)


# 光标:手形/空格 = 抓手;移动工具悬在可拖目标 = 移动十字;其余工具 = 十字准星。
func _refresh_cursor() -> void:
	# meta 放置模式 = 手形(指向可放置处);平移类优先于它(空格/中键拖仍平移)。
	if _pan_tool or _space_held:
		mouse_default_cursor_shape = Control.CURSOR_DRAG
	elif _meta_mode_active:
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	elif _move_tool:
		if _moving_selection or not _dragging_meta.is_empty() or (_has_hover and _over_move_target(_mouse_pos)):
			mouse_default_cursor_shape = Control.CURSOR_MOVE
		else:
			mouse_default_cursor_shape = Control.CURSOR_ARROW
	else:
		mouse_default_cursor_shape = Control.CURSOR_CROSS


## 小地图内点击位置 → 地图子格(夹在地图范围内)。
func _minimap_to_subcell(pos: Vector2) -> Vector2i:
	var sub := _sub_size()
	var r := minimap_rect()
	if sub.x <= 0 or sub.y <= 0 or r.size.x <= 0.0 or r.size.y <= 0.0:
		return Vector2i.ZERO
	var fx := clampf((pos.x - r.position.x) / r.size.x, 0.0, 0.999999)
	var fy := clampf((pos.y - r.position.y) / r.size.y, 0.0, 0.999999)
	return Vector2i(clampi(int(fx * float(sub.x)), 0, sub.x - 1),
			clampi(int(fy * float(sub.y)), 0, sub.y - 1))


# ── 输入:鼠标 → 子格事件 + 相机操作 ─────────────────────────────────

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_gui_mouse_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_gui_mouse_motion(event as InputEventMouseMotion)
	elif event is InputEventKey:
		var k := event as InputEventKey
		if k.keycode == KEY_SPACE:
			_space_held = k.pressed
			if not _space_held:
				_panning = false
			_refresh_cursor()
			queue_redraw()


func _gui_mouse_button(mb: InputEventMouseButton) -> void:
	match mb.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			if mb.pressed:
				zoom_at_screen(mb.position, 1)
		MOUSE_BUTTON_WHEEL_DOWN:
			if mb.pressed:
				zoom_at_screen(mb.position, -1)
		MOUSE_BUTTON_LEFT:
			_update_hover(mb.position)
			if mb.pressed:
				grab_focus()
				if _space_held or _pan_tool:
					_panning = true
					_refresh_cursor()
				elif _move_tool:
					_begin_move(mb.position)
				else:
					_left_down = true
					pointer_down.emit(screen_to_subcell(mb.position), mb.button_index,
							mb.shift_pressed, mb.ctrl_pressed)
			else:
				if _panning:
					_panning = false
				elif _move_tool and (_moving_selection or not _dragging_meta.is_empty()):
					_end_move(mb.position)
				elif _left_down:
					_left_down = false
					pointer_up.emit(screen_to_subcell(mb.position))
				_refresh_cursor()
		MOUSE_BUTTON_MIDDLE:
			_update_hover(mb.position)
			_panning = mb.pressed
			if mb.pressed:
				grab_focus()
			_refresh_cursor()
		MOUSE_BUTTON_RIGHT:
			# 右键只做小地图跳转:命中小地图 ⇒ 换算成子格并居中(不发 pointer_*、不落笔);
			# 右键在画布其它地方保持无动作(也不改 hover / 相机)。
			if mb.pressed:
				var mr := minimap_rect()
				if mr.size.x > 0.0 and mr.size.y > 0.0 and mr.has_point(mb.position):
					grab_focus()
					center_on_subcell(_minimap_to_subcell(mb.position))
	if not _panning:
		queue_redraw()


func _gui_mouse_motion(mm: InputEventMouseMotion) -> void:
	_update_hover(mm.position)
	if _panning:
		_origin -= mm.relative / _zoom
		refresh()
		return
	var sub := screen_to_subcell(mm.position)
	if _move_tool:
		if _moving_selection:
			_move_delta = _clamped_move_delta(sub)
		cursor_moved.emit(sub)
		_refresh_cursor()
		queue_redraw()
		return
	if _left_down:
		pointer_drag.emit(sub)
	cursor_moved.emit(sub)
	queue_redraw()


func _update_hover(pos: Vector2) -> void:
	_hover_sub = screen_to_subcell(pos)
	_mouse_pos = pos
	_has_hover = true


# ── 移动工具:拖选区 / 拖 meta(画布只算几何,doc 写入在 editor_tools)─────────

func _begin_move(pos: Vector2) -> void:
	var marker := meta_marker_at(pos)
	if not marker.is_empty():
		_dragging_meta = marker
		_refresh_cursor()
		meta_drag_started.emit(String(marker["kind"]), int(marker["index"]))
		queue_redraw()
		return
	if _doc == null or not _doc.has_selection():
		return
	if not selection_screen_rect().has_point(pos):
		return
	_moving_selection = true
	_move_origin_sub = screen_to_subcell(pos)
	_move_delta = Vector2i.ZERO
	_refresh_cursor()
	selection_move_started.emit()
	queue_redraw()


func _end_move(pos: Vector2) -> void:
	if not _dragging_meta.is_empty():
		var m := _dragging_meta
		_dragging_meta = {}
		var cell := _cell_at(pos)
		_refresh_cursor()
		queue_redraw()
		meta_drag_finished.emit(String(m["kind"]), int(m["index"]), cell)
		# 单击(没拖动)出生点 = 从这一点试玩:拖拽仍然是移动出生点,两者靠「落点是否同一格」区分。
		if String(m["kind"]) == "player" and cell == (m.get("cell", Vector2i(-1, -1)) as Vector2i):
			player_playtest_requested.emit(cell)
		return
	if _moving_selection:
		_moving_selection = false
		var delta := _clamped_move_delta(screen_to_subcell(pos))
		_move_delta = Vector2i.ZERO
		_refresh_cursor()
		queue_redraw()
		selection_move_finished.emit(delta)


func _cell_at(pos: Vector2) -> Vector2i:
	var sub := screen_to_subcell(pos)
	return Vector2i(floori(float(sub.x) / EditorConstants.SUB_PER_CELL),
			floori(float(sub.y) / EditorConstants.SUB_PER_CELL))


# 拖动距离 clamp:选区块不许被拖出图外(画布先夹一次,doc 端仍会再校验)。
func _clamped_move_delta(pointer_sub: Vector2i) -> Vector2i:
	if _doc == null or not _doc.has_selection():
		return Vector2i.ZERO
	var raw := pointer_sub - _move_origin_sub
	var sel := _doc.selection
	var sz := _sub_size()
	return Vector2i(
			clampi(raw.x, -sel.position.x, sz.x - sel.position.x - sel.size.x),
			clampi(raw.y, -sel.position.y, sz.y - sel.position.y - sel.size.y))


# ── 档位小工具 ───────────────────────────────────────────────────────

func _apply_zoom(new_zoom: float, at: Vector2) -> void:
	_view._apply_zoom(new_zoom, at)
