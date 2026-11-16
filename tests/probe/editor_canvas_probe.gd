extends Node

# P2 画布场景探针:真实例化 editor_canvas_probe.tscn 里的 EditorCanvas(Control,800×600),
# 造一张 8×8 格小图(场景层放 3 个不同描述符、背景色层放一块纯红),断言画布离屏视口、
# 相机、层可见/压暗、鼠标→子格与新描述符刷新;以及 T2 后置项:脏区刷新必须与全量逐像素一致
#(含跨接缝的环面副本)、view_image() 副本语义、选区框与 meta 标记几何。
# 去掉什么它才会红:
#   ① 不建离屏纹理 / 尺寸 != canvas ⇒ 纹理断言红;
#   ② screen_to_subcell 不 floor 或漏 origin ⇒ 手算 3 点红;
#   ③ 缩放不以鼠标为锚 ⇒ 锚点子格变了红;
#   ④ 不判 layer_visible / active 不恒可见 ⇒ 层可见断言红;
#   ⑤ 非 active 层不压暗到 0.45 ⇒ 混合像素期望值红;
#   ⑥ 新 desc 不重建图集 ⇒ descs() 缺新描述符 + 该格仍是底色红;
#   ⑦ 纹理层没 blit 图集 ⇒ 纹理格像素全是底色红;
#   ⑧ 无 doc / 空图 refresh() 崩 ⇒ 条数闸/纹理断言红;
#   ⑨ 脏区刷新漏环面副本或与全量不一致 ⇒ get_data() 逐字节比较红(⑪/⑪b/⑫);
#   ⑩ view_image() 不返回副本 ⇒ 改返回值污染画布断言红;
#   ⑪ 选区屏幕矩形算错/清不掉 ⇒ ⑬ 组红;
#   ⑫ meta 标记漏类型/标签/锚点错/开关无效 ⇒ ⑭ 组红;
#   ⑬ 手形拖动不平移 / 平移时发 pointer_* ⇒ ⑰ 组红;
#   ⑭ 移动工具不发 selection_move_finished 或 delta 算错 ⇒ ⑱ 组红;
#   ⑮ meta 标记命中测试/拖拽落点(格坐标)错 ⇒ ⑲ 组红。
# 判据 = 判词行 + 条数闸;退出码只是陪衬。像素判据统一走 view_image()(纹理走 update() 上传,
# view_texture().get_image() 是旧的)。

const EXPECTED_CHECKS := 51
const CANVAS_W := 800
const CANVAS_H := 600
const SUB := 32                     # 8 格 × 4 子格 = 32
const SUB_PX := 16                  # 默认 zoom = 16px/子格
const BG := Color("2f4256")         # = TerrainAtlas.SKY_COLOR,画布底色

var _fails: Array[String] = []
var _checks := 0
var _canvas: EditorCanvas = null
var _doc: EditorDoc = null
var _pointer_sub := Vector2i(-9999, -9999)
var _pointer_hits := 0
var _last_sel_delta := Vector2i(999, 999)
var _last_meta: Dictionary = {}


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)
		print("  ✗ " + msg)


func _ready() -> void:
	await get_tree().process_frame
	_canvas = get_node_or_null("Canvas") as EditorCanvas
	_chk(_canvas != null, "① 场景里的 EditorCanvas 子节点缺失(期望 1 个)")
	if _canvas == null:
		_finish()
		return
	_canvas.size = Vector2(CANVAS_W, CANVAS_H)

	# ── 造 8×8 格地图 ────────────────────────────────────────────────
	var map := EditorMap.create_map("canvas_probe", 8, 8)
	_chk(not map.is_empty(), "① EditorMap.create_map(\"canvas_probe\", 8, 8) 返回空字典")
	if map.is_empty():
		_finish()
		return
	var layers: Array = map["layers"]
	var scene_desc: PackedInt32Array = layers[1]["desc"]
	scene_desc[0] = EditorDesc.neutral_desc(1)                        # 子格 (0,0)
	scene_desc[1] = EditorDesc.neutral_desc(2)                        # 子格 (1,0)
	scene_desc[1 * SUB + 2] = EditorDesc.pack_desc(3, 6, 5, 5, 7)     # 子格 (2,1) 辅码变体
	layers[1]["desc"] = scene_desc
	var bg_rgba: PackedInt32Array = layers[3]["rgba"]
	bg_rgba[12 * SUB + 12] = 0xFF0000FF                               # 子格 (12,12) 不透明纯红
	layers[3]["rgba"] = bg_rgba

	_doc = EditorDoc.new()
	if _doc == null or not _doc.has_method("load_map"):
		_chk(false, "① EditorDoc 还没有 load_map(p2-doc 未落地)")
		_finish()
		return
	_doc.load_map(map)
	_doc.active_layer = 1
	_canvas.set_doc(_doc)
	_canvas.set_camera(Vector2.ZERO, float(SUB_PX))
	_canvas.set_active_layer(1)
	_canvas.refresh()

	# ① 离屏视口纹理
	var tex: Texture2D = _canvas.view_texture()
	_chk(tex != null, "① refresh() 后 view_texture() 为 null(期望非空)")
	_chk(tex != null and tex.get_size() == Vector2(CANVAS_W, CANVAS_H),
			"① 视口纹理尺寸必须等于 canvas 尺寸 800×600(实得 %s)" % [str(tex.get_size()) if tex != null else "null"])

	# ② screen_to_subcell 手算 3 点(默认 origin=(0,0), zoom=16)
	_chk(_canvas.screen_to_subcell(Vector2(0, 0)) == Vector2i(0, 0),
			"② screen_to_subcell(0,0) 期望 (0,0) 实得 %s" % str(_canvas.screen_to_subcell(Vector2(0, 0))))
	_chk(_canvas.screen_to_subcell(Vector2(16, 16)) == Vector2i(1, 1),
			"② screen_to_subcell(16,16) 期望 (1,1) 实得 %s" % str(_canvas.screen_to_subcell(Vector2(16, 16))))
	_chk(_canvas.screen_to_subcell(Vector2(32, 48)) == Vector2i(2, 3),
			"② screen_to_subcell(32,48) 期望 (2,3) 实得 %s" % str(_canvas.screen_to_subcell(Vector2(32, 48))))
	_chk(_canvas.subcell_to_screen(Vector2i(1, 1)) == Vector2(16, 16),
			"② subcell_to_screen(1,1) 期望 (16,16) 实得 %s" % str(_canvas.subcell_to_screen(Vector2i(1, 1))))

	# ③ 缩放:默认档 + 放大一档 + 鼠标锚点子格不变
	_chk(is_equal_approx(_canvas.zoom, 16.0), "③ 默认 zoom 期望 16.0 实得 %f" % _canvas.zoom)
	_canvas.zoom_in()
	_chk(is_equal_approx(_canvas.zoom, 24.0), "③ zoom_in() 后期望 24.0(下一档) 实得 %f" % _canvas.zoom)
	_canvas.set_camera(Vector2.ZERO, float(SUB_PX))
	var anchor := Vector2(401, 302)
	var before_sub := _canvas.screen_to_subcell(anchor)
	_canvas.zoom_at_screen(anchor, 1)
	var after_sub := _canvas.screen_to_subcell(anchor)
	_chk(before_sub == after_sub,
			"③ 以鼠标 (401,302) 为锚放大后该点子格必须不变(前 %s / 后 %s)" % [str(before_sub), str(after_sub)])

	# ④ 层可见性(active 层恒可见)
	_canvas.set_camera(Vector2.ZERO, float(SUB_PX))
	_canvas.set_layer_visible(3, false)
	_chk(not _canvas.layer_visible(3), "④ set_layer_visible(3,false) 后 layer_visible(3) 期望 false")
	var img := _view_image()
	_chk(img != null and _near(img.get_pixel(200, 200), BG, 2),
			"④ 隐藏层 3 后子格(12,12)像素应回到底色 %s(实得 %s)"
			% [str(BG), str(img.get_pixel(200, 200)) if img != null else "null"])
	_canvas.set_layer_visible(3, true)
	_chk(_canvas.layer_visible(3), "④ set_layer_visible(3,true) 后 layer_visible(3) 期望 true")
	_canvas.set_layer_visible(1, false)
	_chk(_canvas.layer_visible(1), "④ active 层(1)打了叉也必须恒可见(layer_visible(1) 期望 true)")
	_canvas.set_layer_visible(1, true)

	# ⑤ 颜色层渲染:active 时不透明纯红;非 active 时压暗到 0.45
	var red := Color8(255, 0, 0, 255)
	_canvas.set_active_layer(3)
	_canvas.refresh()
	img = _view_image()
	_chk(img != null and img.get_pixel(200, 200).is_equal_approx(red),
			"⑤ active 颜色层(3)在子格(12,12)必须是不透明纯红 %s(实得 %s)"
			% [str(red), str(img.get_pixel(200, 200)) if img != null else "null"])
	_canvas.set_active_layer(1)
	_canvas.refresh()
	img = _view_image()
	var dim_expect := Color8(141, 36, 47, 255)   # sky 与 45% 红按 alpha=115 混合的理论值
	_chk(img != null and _near(img.get_pixel(200, 200), dim_expect, 3),
			"⑤ 非 active 颜色层(3)必须压暗到 0.45 混合 ≈ %s(实得 %s)"
			% [str(dim_expect), str(img.get_pixel(200, 200)) if img != null else "null"])

	# ⑥ 纹理层确实从图集 blit 出来(3 个描述符格子至少各 != 底色)
	_chk(img != null and _any_not_bg(img, [Vector2i(8, 8), Vector2i(24, 8), Vector2i(40, 24)]),
			"⑥ 场景层 3 个纹理格子全是底色(图集没 blit 上去?)")

	# ⑦ 鼠标左键 → pointer_down(子格翻译)
	_canvas.set_camera(Vector2.ZERO, float(SUB_PX))
	_canvas.pointer_down.connect(_on_pointer_down)
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = Vector2(16, 16)
	_canvas._gui_input(ev)
	var ev_up := InputEventMouseButton.new()
	ev_up.button_index = MOUSE_BUTTON_LEFT
	ev_up.pressed = false
	ev_up.position = Vector2(16, 16)
	_canvas._gui_input(ev_up)
	_canvas.pointer_down.disconnect(_on_pointer_down)
	_chk(_pointer_sub == Vector2i(1, 1),
			"⑦ 左键在 (16,16) 按下应发 pointer_down((1,1),…)(实得 %s)" % str(_pointer_sub))

	# ⑧ 新 desc(图集里没有的 hue 变体)→ 图集重建 + 刷新不报错、纹理尺寸不变
	var new_desc := EditorDesc.pack_desc(1, 2, 5, 5, 7)
	_chk(not _canvas.descs().has(new_desc), "⑧ 前置:新描述符 0x%08X 不能已在图集里" % new_desc)
	var changed := _doc.set_cells([Vector2i(20, 20)], new_desc)
	_chk(changed > 0 and _doc.get_subcell(20, 20) == new_desc,
			"⑧ 前置:EditorDoc.set_cells 未落下新描述符(改动数 %d)" % changed)
	_canvas.refresh()
	_chk(_canvas.descs().has(new_desc),
			"⑧ 新 desc 出现后 descs() 必须包含 0x%08X(实得 %d 个描述符)" % [new_desc, _canvas.descs().size()])
	tex = _canvas.view_texture()
	_chk(tex != null and tex.get_size() == Vector2(CANVAS_W, CANVAS_H),
			"⑧ 新 desc 刷新后视口纹理尺寸必须仍是 800×600(实得 %s)" % [str(tex.get_size()) if tex != null else "null"])
	img = _view_image()
	_chk(img != null and not _near(img.get_pixel(328, 328), BG, 2),
			"⑧ 新 desc 的格子(20,20)像素仍是底色(图集没重建?)")
	_chk(img != null and not _near(img.get_pixel(328, 328), img.get_pixel(8, 8), 2),
			"⑧ 新 desc(tex1 的 hue 变体)像素必须不同于中性 desc(1) 像素(否则 blit 回落成中性行、变体没生效)")

	# ⑨ 未设 doc 时 refresh() 必须安全(空载守卫;去掉 `_doc != null` 判据会崩)
	var bare := EditorCanvas.new()
	add_child(bare)
	bare.size = Vector2(64, 64)
	bare.refresh()
	var bare_tex: Texture2D = bare.view_texture()
	_chk(bare_tex != null and bare_tex.get_size() == Vector2(64, 64),
			"⑨ 未设 doc 的 refresh() 应安全产出 64×64 视口纹理(实得 %s)"
			% [str(bare_tex.get_size()) if bare_tex != null else "null"])

	# ⑩ 空图(全空气、4-6 层为 null)也不许崩
	var empty_doc := EditorDoc.new()
	empty_doc.new_map("empty", 2, 2)
	bare.set_doc(empty_doc)
	bare.refresh()
	bare_tex = bare.view_texture()
	_chk(bare_tex != null and bare_tex.get_size() == Vector2(64, 64) and bare.descs().is_empty(),
			"⑩ 空图(无任何描述符)refresh() 应安全且尺寸不变(实得 %s / descs=%d)"
			% [str(bare_tex.get_size()) if bare_tex != null else "null", bare.descs().size()])

	# ⑪ 脏区刷新:doc.changed 只刷变更子格的 bbox,结果必须与全量 refresh() 逐像素一致
	_canvas.set_camera(Vector2.ZERO, float(SUB_PX))
	_canvas.set_active_layer(1)
	_doc.active_layer = 1
	_canvas.refresh()
	var img_a := _view_image()
	var paint_desc: int = _canvas.descs()[0]      # 已在图集里的 desc ⇒ 不触发图集重建,走 refresh_region
	var stats_before := _canvas.refresh_counters()
	var changed_cells := _doc.set_cells([Vector2i(30, 30)], paint_desc)
	var img_b := _view_image()
	var stats_after := _canvas.refresh_counters()
	_canvas.refresh()
	var img_c := _view_image()
	_chk(changed_cells > 0 and img_b != null and img_c != null and img_b.get_data() == img_c.get_data(),
			"⑪ changed 后的脏区刷新必须与全量 refresh() 逐像素一致(改动数 %d)" % changed_cells)
	_chk(int(stats_after["region"]) == int(stats_before["region"]) + 1
			and int(stats_after["full"]) == int(stats_before["full"]),
			"⑪ doc.changed 必须走 refresh_region 而非退回全量 refresh(region %d→%d / full %d→%d)"
			% [int(stats_before["region"]), int(stats_after["region"]),
			int(stats_before["full"]), int(stats_after["full"])])
	_chk(img_b != null and img_a != null and not _near(img_b.get_pixel(488, 488), img_a.get_pixel(488, 488), 0),
			"⑪ 变过的子格(30,30)像素必须变化")
	_chk(img_b != null and img_a != null and _near(img_b.get_pixel(8, 8), img_a.get_pixel(8, 8), 0),
			"⑪ 未变格子的像素必须保持原样(脏区不能乱刷)")
	var copy_img := _canvas.view_image()
	if copy_img != null:
		copy_img.set_pixel(0, 0, Color8(255, 0, 255, 255))
	_chk(not _near(_canvas.view_image().get_pixel(0, 0), Color8(255, 0, 255, 255), 0),
			"⑪ view_image() 必须返回副本(改它不能污染画布内部视口图)")

	# ⑪b 颜色层脏区刷新(走颜色层的脏块重放路径)
	_canvas.set_active_layer(3)
	_doc.active_layer = 3
	_canvas.refresh()
	var img_ac := _view_image()
	_doc.set_cells([Vector2i(24, 24)], 0x7F00FFFF)      # 半透明青
	var img_bc := _view_image()
	_canvas.refresh()
	var img_cc := _view_image()
	_chk(img_bc != null and img_cc != null and img_bc.get_data() == img_cc.get_data(),
			"⑪b 颜色层 changed 的脏区刷新也必须与全量 refresh() 逐像素一致")
	_chk(img_bc != null and img_ac != null and not _near(img_bc.get_pixel(392, 392), img_ac.get_pixel(392, 392), 0),
			"⑪b 颜色层变过的子格(24,24)像素必须变化")

	# ⑫ 跨接缝:改 x=0 一整列 —— 地图 32 子格 = 512px < 画布 800px,右侧还有一份环面副本
	_doc.active_layer = 1
	_canvas.set_active_layer(1)
	_canvas.refresh()
	var img_a2 := _view_image()
	var col_cells: Array[Vector2i] = []
	for cy in range(0, SUB):
		col_cells.append(Vector2i(0, cy))
	_doc.set_cells(col_cells, paint_desc)
	var img_b2 := _view_image()
	_canvas.refresh()
	var img_c2 := _view_image()
	_chk(img_b2 != null and img_c2 != null and img_b2.get_data() == img_c2.get_data(),
			"⑫ 跨接缝 dirty 的脏区刷新必须与全量 refresh() 逐像素一致")
	var seam_shift := SUB * SUB_PX                     # 512px:第二份环面副本的 x 偏移
	_chk(img_b2 != null and img_a2 != null
			and not _near(img_b2.get_pixel(8, 24), img_a2.get_pixel(8, 24), 0)
			and not _near(img_b2.get_pixel(8 + seam_shift, 24), img_a2.get_pixel(8 + seam_shift, 24), 0),
			"⑫ x=0 列在两份环面副本(x=8 与 x=%d,子格 y=1)都必须被重画" % (8 + seam_shift))

	# ⑬ 选区:屏幕矩形几何 + 幂等 + 清空(只画在 _draw 叠加层,不动视口像素)
	_canvas.set_camera(Vector2.ZERO, float(SUB_PX))
	_canvas.set_selection(Rect2i(2, 2, 4, 3))
	_chk(_canvas.selection_screen_rect() == Rect2(Vector2(32, 32), Vector2(64, 48)),
			"⑬ 选区屏幕矩形期望 pos(32,32) size(64,48)(实得 %s)" % str(_canvas.selection_screen_rect()))
	_canvas.refresh()
	var sel_view_a := _view_image()
	_canvas.set_selection(Rect2i(2, 2, 4, 3))
	_canvas.refresh()
	var sel_view_b := _view_image()
	_chk(sel_view_a != null and sel_view_b != null and sel_view_a.get_data() == sel_view_b.get_data(),
			"⑬ set_selection 必须幂等:重复设置 + refresh 后视口像素不变")
	_canvas.set_selection(Rect2i())
	_chk(_canvas.selection_screen_rect().size == Vector2.ZERO,
			"⑬ set_selection(Rect2i()) 必须清空选区")

	# ⑭ meta 标记:1 player / 2 respawn(side1,side2) / 1 enemy 的标签与锚点
	#   T1(EditorDoc meta API)已落地就用 doc API;没落地就直接写 map(画布只读 map,口径同契约 §2)。
	var meta_api := _doc.has_method("add_player") and _doc.has_method("add_respawn") \
			and _doc.has_method("add_enemy") and _doc.has_method("clear_meta")
	if meta_api:
		_doc.clear_meta("all")
		_doc.add_player(Vector2i(1, 1))
		_doc.add_respawn(1, Vector2i(2, 2))
		_doc.add_respawn(2, Vector2i(3, 2))
		_doc.add_enemy("slime", Vector2i(4, 4))
	else:
		var mp: Dictionary = _doc.map
		(mp["players"] as Array).clear()
		(mp["respawns"] as Array).clear()
		(mp["enemies"] as Array).clear()
		(mp["players"] as Array).append({"x": 1, "y": 1})
		(mp["respawns"] as Array).append({"side": 1, "x": 2, "y": 2})
		(mp["respawns"] as Array).append({"side": 2, "x": 3, "y": 2})
		(mp["enemies"] as Array).append({"type": "slime", "x": 4, "y": 4})
	_canvas.refresh()
	var markers := _canvas.meta_markers()
	_chk(markers.size() == 4, "⑭ 1 player + 2 respawn + 1 enemy 应有 4 个标记(实得 %d)" % markers.size())
	var labels := {}
	for m: Dictionary in markers:
		labels[String(m["kind"]) + ":" + String(m["label"])] = true
	_chk(labels.has("player:P1") and labels.has("respawn:R1") and labels.has("respawn:R2")
			and labels.has("enemy:S"), "⑭ 标记标签期望 P1/R1/R2/S(实得 %s)" % str(labels.keys()))
	var player_pos := Vector2.ZERO
	for m: Dictionary in markers:
		if String(m["kind"]) == "player":
			player_pos = m["pos"]
	_chk(player_pos == Vector2(96, 96), "⑭ 出生点标记锚点 = 格 (1,1) 中心 → 屏幕 (96,96)(实得 %s)" % str(player_pos))
	var meta_tex := _canvas.view_texture()
	_chk(meta_tex != null and meta_tex.get_size() == Vector2(CANVAS_W, CANVAS_H),
			"⑭ 加 meta 后视口纹理尺寸不变(实得 %s)" % [str(meta_tex.get_size()) if meta_tex != null else "null"])
	_canvas.set_meta_visible(false)
	_chk(_canvas.meta_markers().is_empty(), "⑭ set_meta_visible(false) 后标记列表应为空")
	_canvas.set_meta_visible(true)
	_chk(_canvas.meta_markers().size() == 4, "⑭ set_meta_visible(true) 后标记恢复")

	# ⑰ 手形工具:左键拖动 = 平移,且**不发 pointer_*** (不然手形会顺手画一笔)
	_canvas.set_camera(Vector2.ZERO, float(SUB_PX))
	_canvas.set_pan_tool(true)
	_pointer_hits = 0
	_canvas.pointer_down.connect(_on_any_pointer)
	var origin_before := _canvas.origin
	_click_at(Vector2(100, 100), true)
	_drag_to(Vector2(140, 120), Vector2(40, 20))
	_click_at(Vector2(140, 120), false)
	_canvas.pointer_down.disconnect(_on_any_pointer)
	var origin_after := _canvas.origin
	_chk(absf(origin_after.x - (origin_before.x - 40.0 / float(SUB_PX))) < 0.01
			and absf(origin_after.y - (origin_before.y - 20.0 / float(SUB_PX))) < 0.01
			and _pointer_hits == 0,
			"⑰ 手形拖动应平移 origin -= (2.5,1.25) 且不发 pointer_down(Δ=%s, hits=%d)"
			% [str(origin_after - origin_before), _pointer_hits])
	_canvas.set_pan_tool(false)

	# ⑱ 移动工具:拖选区 → 发 selection_move_finished(delta)(写 doc 由工具层做,见 doc smoke/scene probe)
	_canvas.set_camera(Vector2.ZERO, float(SUB_PX))
	_doc.active_layer = 1
	_canvas.set_active_layer(1)
	_doc.clear_meta("all")
	var move_desc := EditorDesc.neutral_desc(6)
	_doc.set_cells([Vector2i(3, 3)], move_desc)
	_doc.set_selection(Rect2i(2, 2, 4, 4))
	_canvas.set_selection(_doc.selection)
	_canvas.set_move_tool(true)
	_last_sel_delta = Vector2i(999, 999)
	_canvas.selection_move_finished.connect(_on_sel_move)
	# 选区屏幕矩形 = (32,32,64,64);按在 (64,64) 拖到 (96,80) ⇒ Δ 子格 (2,1)
	_click_at(Vector2(64, 64), true)
	_drag_to(Vector2(96, 80))
	_click_at(Vector2(96, 80), false)
	_canvas.selection_move_finished.disconnect(_on_sel_move)
	var move_delta := _last_sel_delta

	# ⑱b 画布 clamp:选区贴右边界时继续往右拖 ⇒ 发出的 delta = 边界可移动量(选框不许出图)
	_doc.set_selection(Rect2i(24, 20, 4, 4))
	_canvas.set_selection(_doc.selection)
	_last_sel_delta = Vector2i(999, 999)
	_canvas.selection_move_finished.connect(_on_sel_move)
	# 选区屏幕矩形 = (384,320,64,64);按 (416,352) 拖到 (700,360)(远超右边界)
	_click_at(Vector2(416, 352), true)
	_drag_to(Vector2(700, 360))
	_click_at(Vector2(700, 360), false)
	_canvas.selection_move_finished.disconnect(_on_sel_move)
	_chk(move_delta == Vector2i(2, 1) and _last_sel_delta == Vector2i(4, 0),
			"⑱ 移动 delta 应为图内 (2,1)、贴右边界拖出时应夹到 (4,0)(实得 %s / %s)"
			% [str(move_delta), str(_last_sel_delta)])
	_canvas.set_move_tool(false)

	# ⑲ 移动工具:meta 命中 → 发 meta_drag_finished(kind,index,格坐标);写 doc 由工具层做
	_canvas.set_camera(Vector2.ZERO, float(SUB_PX))
	_doc.clear_meta("all")
	_doc.add_player(Vector2i(1, 1))
	_doc.add_player(Vector2i(6, 6))       # index 1:必须证明发的是这一条的 index
	_doc.add_respawn(1, Vector2i(2, 2))
	_doc.add_enemy("slime", Vector2i(4, 4))
	_canvas.refresh()
	_canvas.set_move_tool(true)
	_last_meta = {}
	_canvas.meta_drag_finished.connect(_on_meta_drag)
	# 第 2 个出生点锚点 = 格 (6,6) 中心 → 屏幕 (416,416);拖到 (224,224) ⇒ 格 (3,3)
	_click_at(Vector2(416, 416), true)
	_drag_to(Vector2(224, 224))
	_click_at(Vector2(224, 224), false)
	_canvas.meta_drag_finished.disconnect(_on_meta_drag)
	var player_emit := _last_meta
	# 复活点(2,2) 中心 = 屏幕 (160,160) → 拖到 (96,96) ⇒ 格 (1,1)
	_last_meta = {}
	_canvas.meta_drag_finished.connect(_on_meta_drag)
	_click_at(Vector2(160, 160), true)
	_drag_to(Vector2(96, 96))
	_click_at(Vector2(96, 96), false)
	_canvas.meta_drag_finished.disconnect(_on_meta_drag)
	_chk(String(player_emit.get("kind", "")) == "player" and int(player_emit.get("index", -1)) == 1
			and player_emit.get("cell", Vector2i.ZERO) == Vector2i(3, 3)
			and String(_last_meta.get("kind", "")) == "respawn"
			and int(_last_meta.get("index", -1)) == 0
			and _last_meta.get("cell", Vector2i.ZERO) == Vector2i(1, 1),
			"⑲ meta 命中应发 player#1→(3,3) 与 respawn#0→(1,1)(实得 %s / %s)"
			% [str(player_emit), str(_last_meta)])
	_canvas.set_move_tool(false)


	# ⑮ 叠加层 _draw(网格+选区虚线框+meta 标记)必须在 headless 下真跑通且可重跑
	_canvas.set_selection(Rect2i(1, 1, 3, 3))
	_canvas.queue_redraw()
	await get_tree().process_frame
	var draws_1 := _canvas.get_draw_calls()
	_canvas.set_selection(Rect2i(0, 0, 2, 4))
	_canvas.queue_redraw()
	await get_tree().process_frame
	_chk(draws_1 >= 1 and _canvas.get_draw_calls() > draws_1,
			"⑮ 选区+meta 叠加层 _draw 必须真跑且可重跑(draw calls %d→%d)"
			% [draws_1, _canvas.get_draw_calls()])

	# ⑯ 小图(1 格 = 64px)在 256px 画布上会平铺出多份环面副本:脏区必须逐份重画
	#   用颜色层(整格不透明)做变更,保证每份副本的像素都真的变了(纹理象限可能自带透明)。
	bare.size = Vector2(256, 192)
	var ring_doc := EditorDoc.new()
	ring_doc.new_map("ring", 1, 1)
	ring_doc.active_layer = 3
	bare.set_doc(ring_doc)
	bare.set_camera(Vector2.ZERO, float(SUB_PX))
	bare.set_active_layer(3)
	bare.refresh()
	var ring_a := bare.view_image()
	var ring_changed := ring_doc.set_cells([Vector2i(1, 1)], 0xFF00FFAA)   # 不透明品红
	var ring_b := bare.view_image()
	bare.refresh()
	var ring_c := bare.view_image()
	_chk(ring_changed > 0 and ring_b != null and ring_c != null and ring_b.get_data() == ring_c.get_data(),
			"⑯ 小图脏区在屏幕上平铺多份环面副本时,脏区刷新必须与全量 refresh() 逐像素一致")
	# 子格 (1,1) 中心 = 屏幕 (24,24);kx=ky=2 的副本在 (24+2*64, 24+2*64) = (152,152)
	_chk(ring_b != null and ring_a != null
			and not _near(ring_b.get_pixel(152, 152), ring_a.get_pixel(152, 152), 0),
			"⑯ kx=ky=2 的环面副本(屏幕 152,152)也必须被重画")

	_finish()


func _on_pointer_down(sub: Vector2i, _button: int, _shift: bool, _ctrl: bool) -> void:
	_pointer_sub = sub


# ── ⑰/⑱/⑲:手形平移 / 拖选区 / 拖 meta 的合成输入 ──────────────────────

func _on_any_pointer(_sub: Vector2i, _button: int, _shift: bool, _ctrl: bool) -> void:
	_pointer_hits += 1


# 画布只发几何信号:这里只记录(写 doc 归工具层/doc smoke 管)。
func _on_sel_move(delta: Vector2i) -> void:
	_last_sel_delta = delta


func _on_meta_drag(kind: String, index: int, cell: Vector2i) -> void:
	_last_meta = {"kind": kind, "index": index, "cell": cell}


func _click_at(pos: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = pos
	_canvas._gui_input(ev)


func _drag_to(pos: Vector2, relative: Vector2 = Vector2.ZERO) -> void:
	var mm := InputEventMouseMotion.new()
	mm.position = pos
	mm.relative = relative
	_canvas._gui_input(mm)


func _view_image() -> Image:
	return _canvas.view_image()


func _near(c: Color, want: Color, tol: int) -> bool:
	return absi(roundi(c.r * 255.0) - roundi(want.r * 255.0)) <= tol \
			and absi(roundi(c.g * 255.0) - roundi(want.g * 255.0)) <= tol \
			and absi(roundi(c.b * 255.0) - roundi(want.b * 255.0)) <= tol \
			and absi(roundi(c.a * 255.0) - roundi(want.a * 255.0)) <= tol


func _any_not_bg(img: Image, points: Array) -> bool:
	for p: Vector2i in points:
		if not _near(img.get_pixel(p.x, p.y), BG, 2):
			return true
	return false


func _finish() -> void:
	# 条数闸 = 恰好相等:少了 = 脚本中途中止(断言被静默跳过);多了 = 忘更新 EXPECTED_CHECKS。
	if _checks != EXPECTED_CHECKS:
		if _checks < EXPECTED_CHECKS:
			print("EDITOR CANVAS PROBE: FAIL | 只跑了 %d 条 < %d(脚本中途中止)"
					% [_checks, EXPECTED_CHECKS])
		else:
			print("EDITOR CANVAS PROBE: FAIL | 跑了 %d 条 > %d(EXPECTED_CHECKS 忘了加)"
					% [_checks, EXPECTED_CHECKS])
		get_tree().quit(1)
		return
	if not _fails.is_empty():
		print("EDITOR CANVAS PROBE: FAIL(%d/%d)" % [_fails.size(), EXPECTED_CHECKS])
		for f in _fails:
			print("  - " + f)
		get_tree().quit(1)
		return
	print("EDITOR CANVAS PROBE: ALL-OK(%d 条断言)" % _checks)
	get_tree().quit(0)
