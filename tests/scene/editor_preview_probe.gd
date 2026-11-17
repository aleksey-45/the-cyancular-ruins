extends Node

# T3 EditorPreview 场景探针(`bash .tmp/run_scene.sh tests/scene/editor_preview_probe.tscn 180`)。
# 实例化 scenes/editor/editor_preview.gd(无 class_name,用 load),给 640×480,喂一张 8×8 格的图
# (三层纹理 + 层 3 颜色),用 stats()/相机/节点状态做断言。
#
# ★ 像素不作为判据:本探针在 --headless(dummy 渲染)下跑,SubViewport 不出真实像素;
#   这里只钉「结构对了、相机数值对了、切换/重铺不崩」,画面观感需非 headless 人工看。
# 去掉什么会红(逐组):
#   ① setup 不建视口/图层/后处理 ⇒ stats.ready / tiles / bg_layers / post 红;
#   ② 瓦片铺错(层序/坐标/air 判断)⇒ tiles 数不等于手算 773 红;
#   ③ 相机口径错(漏 *16 或 *0.5)⇒ 默认 position / set_camera 后 position、zoom 红;
#   ④ set_active 不隐藏或不停止更新 ⇒ 显隐与 viewport update_mode 红;
#   ⑤ refresh 不幂等(每次重建计数器/随机化)⇒ 二次 refresh 后 stats 或相机变化红;
#   ⑥ doc.changed 不接 ⇒ 改一格后 SceneLayer 瓦片坐标不变红;structure_changed 不接 ⇒ 换图后仍 773 红;
#   ⑦ Display 没贴 PreviewViewport 纹理 ⇒ 红。
# ★ 期望值来自契约 §3 的公式/瓦片坐标口径与本文件手算(构成图),不复用被测函数的返回值。

const EXPECTED_CHECKS := 21
const PREVIEW_SCRIPT := "res://scenes/editor/editor_preview.gd"
const VIEW_SIZE := Vector2(640, 480)

var _fails: Array[String] = []
var _checks := 0


func _chk(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_fails.append(msg)
		print("  ✗ " + msg)


func _ready() -> void:
	# ★ 空载守卫:load() 为 null 还往下走会抛错,场景探针的 async _ready 就再也走不到 quit。
	for p in [
		PREVIEW_SCRIPT,
		"res://core/present/post_process.gd",
		"res://core/present/parallax_bg.gd",
		"res://core/editor/editor_doc.gd",
		"res://core/sim/terrain_atlas.gd",
	]:
		if load(p) == null:
			print("EDITOR PREVIEW PROBE: FAIL | load(%s) 为 null(空载守卫)" % p)
			get_tree().quit(1)
			return
	var script := load(PREVIEW_SCRIPT)

	var doc := EditorDoc.new()
	doc.new_map("preview_probe", 8, 8)
	_fill_map(doc)

	var preview = script.new()
	preview.name = "Preview"
	preview.size = VIEW_SIZE
	add_child(preview)                              # 先入树(PostProcess 的 _ready 需要视口已在树里)
	await get_tree().process_frame
	preview.setup(doc)
	await get_tree().process_frame
	await get_tree().process_frame

	# ══ ① setup 后结构统计 ══
	var st: Dictionary = preview.stats()
	_chk(bool(st.get("ready", false)), "① setup 后 stats().ready 应为 true(实得 %s)" % str(st))
	_chk(int(st.get("tiles", 0)) > 0, "① stats().tiles 应 > 0(实得 %s)" % st.get("tiles", 0))
	# 手算:front 每 7 子格 1 个 = 147;scene 左半 16 列 × 32 行 = 512;back 每 9 子格 1 个 = 114。
	_chk(int(st.get("tiles", -1)) == 773,
			"① 三层瓦片数应 = 147+512+114 = 773(实得 %s)" % st.get("tiles", -1))
	_chk(int(st.get("bg_layers", 0)) >= 1,
			"② 层 3 有颜色 ⇒ stats().bg_layers 应 >= 1(实得 %s)" % st.get("bg_layers", 0))
	_chk(bool(st.get("post", false)), "③ stats().post 应为 true(实得 %s)" % st.get("post", false))

	var display := preview.get_node_or_null("Display") as TextureRect
	_chk(display != null and display.texture != null,
			"④ Display(TextureRect) 应贴 PreviewViewport 的纹理(实得 display=%s)" % str(display))

	# ══ ② 相机口径:默认 origin=0 / zoom=16 ⇒ Camera2D.zoom=1、position=视口中心 ══
	var cam := preview.get_node_or_null("WorldViewport/Camera2D") as Camera2D
	_chk(cam != null, "⑤ WorldViewport/Camera2D 应存在(实得 null)")
	if cam != null:
		_chk(cam.zoom.is_equal_approx(Vector2(1.0, 1.0)),
				"⑤ 默认 zoom=16 ⇒ Camera2D.zoom 应 = (1,1)(实得 %s)" % str(cam.zoom))
		_chk(cam.position.is_equal_approx(Vector2(320.0, 240.0)),
				"⑤ 默认 origin=0 ⇒ Camera2D.position 应 = 视口中心 (320,240)(实得 %s)" % str(cam.position))

		# ══ ③ set_camera(origin=(2,1) 子格, zoom=24 px/子格) ══
		preview.set_camera(Vector2(2.0, 1.0), 24.0)
		var z := 24.0 / 16.0
		var want_pos := Vector2(2.0 * 16.0 + VIEW_SIZE.x * 0.5 / z, 1.0 * 16.0 + VIEW_SIZE.y * 0.5 / z)
		_chk(cam.zoom.is_equal_approx(Vector2(z, z)),
				"⑥ set_camera(zoom=24) ⇒ Camera2D.zoom 应 = (1.5,1.5)(实得 %s)" % str(cam.zoom))
		_chk(cam.position.is_equal_approx(want_pos),
				"⑥ set_camera(origin=(2,1),zoom=24) ⇒ position 应 = %s(实得 %s)"
						% [str(want_pos), str(cam.position)])

	# ══ ④ set_active(false/true):显隐 + 停止/恢复视口更新,且不崩 ══
	preview.set_active(false)
	_chk(not preview.visible, "⑦ set_active(false) 后预览应隐藏(实得 visible=true)")
	var world_vp := preview.get_node_or_null("WorldViewport") as SubViewport
	_chk(world_vp != null and world_vp.render_target_update_mode == SubViewport.UPDATE_DISABLED,
			"⑦ 隐藏后世界视口应停止更新(实得 mode=%s)"
					% (world_vp.render_target_update_mode if world_vp != null else "null"))
	preview.set_active(true)
	_chk(preview.visible, "⑦ set_active(true) 后预览应重新显示(实得 visible=false)")
	_chk(world_vp != null and world_vp.render_target_update_mode == SubViewport.UPDATE_ALWAYS,
			"⑦ 重新显示后世界视口应恢复每帧更新(实得 mode=%s)"
					% (world_vp.render_target_update_mode if world_vp != null else "null"))

	# ══ ⑤ 二次 refresh 幂等:stats 与相机都不许变 ══
	var before: Dictionary = preview.stats()
	var cam_pos_before := cam.position if cam != null else Vector2.ZERO
	var cam_zoom_before := cam.zoom if cam != null else Vector2.ZERO
	preview.refresh()
	preview.refresh()
	await get_tree().process_frame
	var after: Dictionary = preview.stats()
	_chk(before == after, "⑧ 二次 refresh 后 stats 应不变(前 %s / 后 %s)" % [str(before), str(after)])
	var cam_same := true
	if cam != null:
		cam_same = cam.position.is_equal_approx(cam_pos_before) and cam.zoom.is_equal_approx(cam_zoom_before)
	_chk(cam_same, "⑧ refresh 不应改相机(期望 pos=%s zoom=%s)" % [str(cam_pos_before), str(cam_zoom_before)])

	# ══ ⑥ doc.changed 接线:改一格场景层 ⇒ SceneLayer 对应瓦片坐标跟着变(增量)══
	doc.active_layer = 1
	var changed := doc.set_cells([Vector2i(5, 3)], EditorDesc.neutral_desc(1))
	_chk(changed == 1, "⑨ 前提:doc.set_cells 应改动 1 格(实得 %d)" % changed)
	await get_tree().process_frame
	await get_tree().process_frame
	var scene_layer := preview.get_node_or_null("WorldViewport/SceneLayer") as TileMapLayer
	# 期望:图集行 = 排序后 descs [neutral(1)=7972, brick=28586, neutral(9)=40740] 里 neutral(1) 的行 0;
	#       象限列 = (sy%4)*4 + (sx%4) = (3%4)*4 + (5%4) = 13。
	_chk(scene_layer != null and scene_layer.get_cell_atlas_coords(Vector2i(5, 3)) == Vector2i(13, 0),
			"⑨ 改一格后 SceneLayer(5,3) 瓦片应 = (13,0)(实得 %s)"
					% (str(scene_layer.get_cell_atlas_coords(Vector2i(5, 3))) if scene_layer != null else "null"))
	_chk(int(preview.stats().get("tiles", -1)) == 773,
			"⑨ 改的是非空→非空格子 ⇒ tiles 应仍是 773(实得 %s)" % preview.stats().get("tiles", -1))

	# ══ ⑦ structure_changed 接线:换一张 10×10 空图 ⇒ 下一帧重铺成 0 瓦片且不崩 ══
	doc.new_map("preview_probe_2", 10, 10)
	await get_tree().process_frame
	await get_tree().process_frame
	var st2: Dictionary = preview.stats()
	_chk(bool(st2.get("ready", false)) and int(st2.get("tiles", -1)) == 0,
			"⑩ structure_changed 后新空图应重铺为 0 瓦片(实得 %s)" % str(st2))

	# ══ 判词闸 ══
	if _checks < EXPECTED_CHECKS:
		print("EDITOR PREVIEW PROBE: FAIL | 只跑了 %d 条 < %d(脚本中途中止)" % [_checks, EXPECTED_CHECKS])
		get_tree().quit(1)
		return
	if not _fails.is_empty():
		print("EDITOR PREVIEW PROBE: FAIL(%d/%d)" % [_fails.size(), EXPECTED_CHECKS])
		for f in _fails:
			print("  - " + f)
		get_tree().quit(1)
		return
	print("EDITOR PREVIEW PROBE: ALL-OK(%d 条断言):结构统计(773 瓦片/背景 1 层/post)· 相机口径 · "
			% _checks + "显隐切换 · refresh 幂等 · doc 信号接线")
	get_tree().quit(0)


# 8×8 格 = 32×32 子格;层 0 前景 / 层 1 场景 / 层 2 后景 / 层 3 颜色(背景 100%)。
func _fill_map(doc: EditorDoc) -> void:
	var map: Dictionary = doc.map
	var sub_cols := int(map["sub_cols"])          # 32
	var sub_rows := int(map["sub_rows"])          # 32
	var n := sub_cols * sub_rows                  # 1024
	var layers: Array = map["layers"]

	var front: PackedInt32Array = (layers[0] as Dictionary)["desc"]
	for i in n:
		if i % 7 == 0:
			front[i] = EditorDesc.neutral_desc(1)
	(layers[0] as Dictionary)["desc"] = front

	var scene: PackedInt32Array = (layers[1] as Dictionary)["desc"]
	var brick := EditorDesc.pack_desc(6, 2, 5, 6, 7)
	for sy in sub_rows:
		var base := sy * sub_cols
		for sx in sub_cols:
			if sx < sub_cols / 2:                 # 左半 16 列
				scene[base + sx] = brick
	(layers[1] as Dictionary)["desc"] = scene

	var back: PackedInt32Array = (layers[2] as Dictionary)["desc"]
	for i in n:
		if i % 9 == 0:
			back[i] = EditorDesc.neutral_desc(9)
	(layers[2] as Dictionary)["desc"] = back

	var bg: PackedInt32Array = (layers[3] as Dictionary)["rgba"]
	for i in n:
		bg[i] = 0x102030FF if i % 2 == 0 else 0x40506080
	(layers[3] as Dictionary)["rgba"] = bg
