extends Node

# P2 画布场景探针:真实例化 editor_canvas_probe.tscn 里的 EditorCanvas(Control,800×600),
# 造一张 8×8 格小图(场景层放 3 个不同描述符、背景色层放一块纯红),断言画布离屏视口、
# 相机、层可见/压暗、鼠标→子格与新描述符刷新。
# 去掉什么它才会红:
#   ① 不建离屏纹理 / 尺寸 != canvas ⇒ 纹理断言红;
#   ② screen_to_subcell 不 floor 或漏 origin ⇒ 手算 3 点红;
#   ③ 缩放不以鼠标为锚 ⇒ 锚点子格变了红;
#   ④ 不判 layer_visible / active 不恒可见 ⇒ 层可见断言红;
#   ⑤ 非 active 层不压暗到 0.45 ⇒ 混合像素期望值红;
#   ⑥ 新 desc 不重建图集 ⇒ descs() 缺新描述符 + 该格仍是底色红;
#   ⑦ 纹理层没 blit 图集 ⇒ 纹理格像素全是底色红。
# 判据 = 判词行 + 条数闸;退出码只是陪衬。

const EXPECTED_CHECKS := 27
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

	_finish()


func _on_pointer_down(sub: Vector2i, _button: int, _shift: bool, _ctrl: bool) -> void:
	_pointer_sub = sub


func _view_image() -> Image:
	var tex := _canvas.view_texture()
	if tex == null:
		return null
	return tex.get_image()


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
	if _checks < EXPECTED_CHECKS:
		print("EDITOR CANVAS PROBE: FAIL | 只跑了 %d 条 < %d(脚本中途中止)" % [_checks, EXPECTED_CHECKS])
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
