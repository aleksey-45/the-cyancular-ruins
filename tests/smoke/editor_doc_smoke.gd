extends SceneTree

# 编辑器文档模型 EditorDoc 守卫(`-s`,headless,不实例化 autoload)。
# 守护 core/editor/editor_doc.gd:环面归一化 / Bresenham / 4 邻接油漆桶 / 稀疏撤销栈 / 颜色层 u32 路径 /
# 信号 / 校验与编码接线。契约 = .tmp/editor-p2-contract.md §2。
#
# 去掉什么会红:
#   ① new_map 建出的 7 层形状(0-2 tex、3 color、4-6 null)或尺寸不对 ⇒ 红。
#   ② set_cells 不做 posmod 环面归一化 / 返回的不是实际改动数(重复格、写同值仍计数)⇒ 红。
#   ③ paint_line 不按 Bresenham 取点 / 不含两端 ⇒ 红。
#   ④ flood_fill 按 8 邻接 / 越墙扩散 / 不跨环面接缝 ⇒ 红。
#   ⑤ 颜色层(3-6)读写的不是 rgba(u32)/ 不为 null 的颜色层按需建层 / 缺席纹理层被凭空补 ⇒ 红。
#   ⑥ undo/redo 不回到 before/after、不发 changed、改图后 dirty 不置位 ⇒ 红。
#   ⑦ begin_stroke/end_stroke 不把连续两笔并成 1 条 undo / 空笔画产生条目 ⇒ 红。
#   ⑧ undo_capacity 调小后不丢最旧 ⇒ 红。
#   ⑨ load_map 不清空 undo/redo、不清 dirty、不发 structure_changed ⇒ 红。
#   ⑩ validate/to_bytes 与 EditorValidate/EditorCodec 的接线断了(编码→解码回不来)⇒ 红。
# ★ 期望值按子格坐标手推(地图 4×3 格 ⇒ 16×12 子格),不复用被测函数的返回值自证。

const EXPECTED_CHECKS := 93

var _fails: Array[String] = []
var _checks := 0
var _changed_count := 0
var _last_layer := -1
var _last_idxs := PackedInt32Array()
var _structure_count := 0


func _chk(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_fails.append(msg)


func _initialize() -> void:
	# ★ 空载守卫(仓规):load() 失败还往下走会在 null 上抛错,而 `-s` 抛错走不到 quit() ⇒ 进程永久挂起。
	for p in [
		"res://core/editor/editor_doc.gd",
		"res://core/editor/editor_map.gd",
		"res://core/editor/editor_desc.gd",
		"res://core/editor/editor_validate.gd",
		"res://core/editor/editor_codec.gd",
	]:
		if load(p) == null:
			print("EDITOR DOC SMOKE FAILED: load(%s) 为 null(-s 空载守卫:不 quit 会挂死)" % p)
			quit(1)
			return

	_test_new_map()
	_test_set_cells_torus()
	_test_paint_line()
	_test_flood_fill()
	_test_color_layers()
	_test_undo_redo()
	_test_stroke()
	_test_undo_capacity()
	_test_load_map()
	_test_validate_bytes()

	# ══ 判词闸 ══
	if _checks < EXPECTED_CHECKS:
		print("EDITOR DOC SMOKE FAILED: 只跑了 %d 条 < %d(脚本中途中止)" % [_checks, EXPECTED_CHECKS])
		quit(1)
		return
	if not _fails.is_empty():
		print("EDITOR DOC SMOKE FAILED (%d/%d):" % [_fails.size(), EXPECTED_CHECKS])
		for f in _fails:
			print("  - " + f)
		quit(1)
		return
	print(("EDITOR DOC SMOKE: OK(%d 条断言):7 层建图 · 环面归一化 · Bresenham 直线 · 4 邻接/接缝油漆桶 · "
			+ "颜色层 u32 · undo/redo 往返 · 笔画合并 · 栈上限 · load_map 清栈 · validate/to_bytes 接线") % _checks)
	quit(0)


# ══ ① new_map:尺寸 / 7 层默认形状 / 干净态 ══
func _test_new_map() -> void:
	var doc := _fresh(4, 3)
	_chk(doc.sub_size() == Vector2i(16, 12), "① sub_size 应 = 16×12(实得 %s)" % doc.sub_size())
	_chk(int(doc.map.get("sub_cols", 0)) == 16 and int(doc.map.get("sub_rows", 0)) == 12,
			"① map.sub_cols/sub_rows 应 = 16/12(实得 %s/%s)"
					% [doc.map.get("sub_cols", -1), doc.map.get("sub_rows", -1)])
	var layers: Array = doc.map.get("layers", [])
	_chk(layers.size() == 7, "① layers 应恒 7 项(实得 %d)" % layers.size())
	var shape_ok := layers.size() == 7
	for L in [0, 1, 2]:
		if shape_ok:
			var ld = layers[L]
			shape_ok = ld != null and String((ld as Dictionary).get("kind", "")) == "tex" \
					and ((ld as Dictionary)["desc"] as PackedInt32Array).size() == 192
	_chk(shape_ok, "① 层 0-2 应是 192 子格的 tex 层(实得 %s)" % _layers_brief(layers))
	var color_ok := layers.size() == 7
	for L in [3, 4, 5, 6]:
		if color_ok:
			var ld = layers[L]
			if L == 3:
				color_ok = ld != null and String((ld as Dictionary).get("kind", "")) == "color" \
						and ((ld as Dictionary)["rgba"] as PackedInt32Array).size() == 192
			else:
				color_ok = ld == null
	_chk(color_ok, "① 默认应只有层 3 分配、层 4-6 为 null(实得 %s)" % _layers_brief(layers))
	_chk(String(doc.map.get("name", "")) == "t", "① name 应 = t(实得 %s)" % doc.map.get("name"))
	_chk(doc.dirty == false and doc.undo_count() == 0 and not doc.can_undo() and not doc.can_redo(),
			"① 新图应是干净态(dirty=%s undo=%d)" % [doc.dirty, doc.undo_count()])
	_chk(doc.active_layer == 1, "① active_layer 默认应 = 1(实得 %d)" % doc.active_layer)


# ══ ② set_cells:环面回绕 + 实际改动数(去重 / 写同值不计数)══
func _test_set_cells_torus() -> void:
	var doc := _fresh()
	var d1 := EditorDesc.neutral_desc(6)
	var d2 := EditorDesc.neutral_desc(7)
	var d3 := EditorDesc.neutral_desc(8)
	var wrap_ret := doc.set_cells(_cells([Vector2i(-1, 0)]), d1)
	_chk(wrap_ret == 1, "② (sx=-1,sy=0) 应改 1 格(实得 %d)" % wrap_ret)
	_chk(doc.get_subcell(15, 0) == d1 and doc.get_subcell(-1, 0) == d1,
			"② (sx=-1) 应落到最后一列 15 且读回同一格")
	var wrap_ret2 := doc.set_cells(_cells([Vector2i(16, 0)]), d2)
	_chk(wrap_ret2 == 1, "② (sx=sub_cols=16) 应改 1 格(实得 %d)" % wrap_ret2)
	_chk(doc.get_subcell(0, 0) == d2 and doc.get_subcell(16, 0) == d2,
			"② (sx=16) 应落回第 0 列且读回同一格")
	_chk(doc.set_cells(_cells([Vector2i(0, -1)]), d1) == 1 and doc.get_subcell(0, 11) == d1,
			"② (sy=-1) 应落到最后一行 11")
	var up_ret := doc.set_cells(_cells([Vector2i(0, 12)]), d3)
	_chk(up_ret == 1 and doc.get_subcell(0, 0) == d3, "② (sy=12) 应落回第 0 行(实得返回 %d)" % up_ret)
	# 同批重复格去重:(15,0) 与 (-1,0) 是同一格,只应改 1 格并压 1 条 undo
	var dup_ret := doc.set_cells(_cells([Vector2i(15, 0), Vector2i(-1, 0)]), d2)
	_chk(dup_ret == 1, "② 同批重复格应去重(应改 1 格,实得 %d)" % dup_ret)
	var undo0 := doc.undo_count()
	var emit0 := _changed_count
	var same_ret := doc.set_cells(_cells([Vector2i(0, 0)]), d3)
	_chk(same_ret == 0, "② 写相同值应返回 0")
	_chk(doc.undo_count() == undo0 and _changed_count == emit0,
			"② 0 改动不应 push undo / 发 changed(undo %d→%d, changed %d→%d)"
					% [undo0, doc.undo_count(), emit0, _changed_count])
	_chk(doc.set_cells(_cells([Vector2i(5, 5), Vector2i(5, 5), Vector2i(5, 6)]), d1) == 2,
			"② 批量应返回实际改动数 2(去重 + 跳过空气格)")


# ══ ③ paint_line:两端含 + Bresenham 中间点 + 环面端点 ══
func _test_paint_line() -> void:
	var doc := _fresh()
	var d := EditorDesc.neutral_desc(6)
	var d2 := EditorDesc.neutral_desc(7)
	var d3 := EditorDesc.neutral_desc(8)
	var d4 := EditorDesc.neutral_desc(9)
	_chk(doc.paint_line(Vector2i(0, 0), Vector2i(3, 0), d) == 4, "③ 水平线 (0,0)-(3,0) 应 4 格")
	var horiz_ok := true
	for x in 4:
		if doc.get_subcell(x, 0) != d:
			horiz_ok = false
	_chk(horiz_ok and doc.get_subcell(0, 0) == d and doc.get_subcell(3, 0) == d, "③ 水平线两端与中间都应被写")
	_chk(doc.paint_line(Vector2i(0, 0), Vector2i(3, 0), d) == 0, "③ 重画同一条线应返回 0")
	# 对角线:5 格全在对角线上
	_chk(doc.paint_line(Vector2i(0, 0), Vector2i(4, 4), d2) == 5, "③ 对角线 (0,0)-(4,4) 应 5 格")
	var diag_ok := true
	for k in 5:
		if doc.get_subcell(k, k) != d2:
			diag_ok = false
	_chk(diag_ok, "③ 对角线 5 格都应被写(含两端)")
	# 手推 Bresenham (6,0)-(10,2):dx=4 dy=2 ⇒ 中间点 = (7,0),(8,1),(9,1)
	_chk(doc.paint_line(Vector2i(6, 0), Vector2i(10, 2), d3) == 5, "③ 斜线 (6,0)-(10,2) 应 5 格")
	_chk(doc.get_subcell(6, 0) == d3 and doc.get_subcell(7, 0) == d3 \
			and doc.get_subcell(8, 1) == d3 and doc.get_subcell(9, 1) == d3 \
			and doc.get_subcell(10, 2) == d3,
			"③ Bresenham 中间点应 = (7,0)(8,1)(9,1)(手推),实得 [%d,%d,%d,%d,%d]"
					% [doc.get_subcell(6, 0), doc.get_subcell(7, 0), doc.get_subcell(8, 1),
							doc.get_subcell(9, 1), doc.get_subcell(10, 2)])
	# 环面端点:(-1,0) → 归一化 15;(1,0) 就 1
	_chk(doc.paint_line(Vector2i(-1, 0), Vector2i(1, 0), d4) == 3 \
			and doc.get_subcell(15, 0) == d4 and doc.get_subcell(0, 0) == d4 \
			and doc.get_subcell(1, 0) == d4,
			"③ 环面端点直线 (sx=-1)-(sx=1) 应写 15/0/1 三格")
	_chk(doc.paint_line(Vector2i(2, 11), Vector2i(2, 12), d4) == 2 \
			and doc.get_subcell(2, 11) == d4 and doc.get_subcell(2, 0) == d4,
			"③ 环面端点直线 (sy=11)-(sy=12) 应写 11/0 两格")


# ══ ④ flood_fill:4 邻接 + 边界不越 + 环面接缝连通 ══
func _test_flood_fill() -> void:
	var wall := EditorDesc.neutral_desc(6)
	var fill := EditorDesc.neutral_desc(7)
	# (a) 封闭矩形墙 (2,2)-(8,7) 边框;内部 5×4 = 20 格,墙外一格都不许填
	var doc := _fresh()
	var border: Array[Vector2i] = []
	for sx in range(2, 9):
		border.append(Vector2i(sx, 2))
		border.append(Vector2i(sx, 7))
	for sy in range(3, 7):
		border.append(Vector2i(2, sy))
		border.append(Vector2i(8, sy))
	_chk(doc.set_cells(border, wall) == 22, "④ 前提:7×6 矩形边框应写 22 格")
	var fill_ret := doc.flood_fill(Vector2i(5, 4), fill)
	_chk(fill_ret == 20, "④ 桶应只填内部 5×4=20 格(实得 %d)" % fill_ret)
	_chk(doc.get_subcell(5, 4) == fill and doc.get_subcell(3, 3) == fill and doc.get_subcell(7, 6) == fill,
			"④ 墙内应被填")
	_chk(doc.get_subcell(10, 4) == 0 and doc.get_subcell(1, 4) == 0 and doc.get_subcell(5, 9) == 0,
			"④ 墙外另一侧不应被填")
	_chk(doc.get_subcell(8, 4) == wall and doc.get_subcell(4, 2) == wall and doc.get_subcell(2, 6) == wall,
			"④ 墙本身不应被填")
	# (b/c) 整图铺 wall,只留 4 个空气格:(5,5)/(6,6) 对角、(15,6)/(0,6) 环面相邻
	var doc2 := _fresh()
	var all: Array[Vector2i] = []
	for sy in 12:
		for sx in 16:
			all.append(Vector2i(sx, sy))
	_chk(doc2.set_cells(all, wall) == 192, "④ 前提:整图 192 子格应全改")
	_chk(doc2.set_cells(_cells([Vector2i(5, 5), Vector2i(6, 6), Vector2i(15, 6), Vector2i(0, 6)]), 0) == 4,
			"④ 前提:应留 4 个空气格")
	var diag_ret := doc2.flood_fill(Vector2i(5, 5), fill)
	_chk(diag_ret == 1, "④ 4 邻接:只对角相邻的空气格不应连通(应 1 格,实得 %d)" % diag_ret)
	_chk(doc2.get_subcell(6, 6) == 0, "④ 对角空气格应保持 0(8 邻接实现会把这里填掉)")
	var seam_ret := doc2.flood_fill(Vector2i(15, 6), fill)
	_chk(seam_ret == 2, "④ 环面接缝:左右边缘两格应连通(应 2 格,实得 %d)" % seam_ret)
	_chk(doc2.get_subcell(0, 6) == fill and doc2.get_subcell(15, 6) == fill, "④ 接缝对侧空气格应被填")


# ══ ⑤ 颜色层:u32 rgba 读写 / 按需建层 / 缺纹理层不补 ══
func _test_color_layers() -> void:
	var doc := _fresh()
	doc.active_layer = 4
	_chk(doc.map["layers"][4] == null, "⑤ 前提:层 4 新建时为 null")
	_chk(doc.get_subcell(0, 0) == 0, "⑤ 缺席颜色层读取应 = 0")
	var s0 := _structure_count
	var c := 0xFF336699
	var color_ret := doc.set_cells(_cells([Vector2i(0, 0), Vector2i(1, 0)]), c)
	_chk(color_ret == 2, "⑤ 颜色层应改 2 格(实得 %d)" % color_ret)
	var ld = doc.map["layers"][4]
	var shape_ok := ld != null and String((ld as Dictionary).get("kind", "")) == "color"
	var rgba := PackedInt32Array()
	if shape_ok:
		rgba = (ld as Dictionary).get("rgba", PackedInt32Array())
	_chk(shape_ok and rgba.size() == 192, "⑤ ensure_layer 应按需建 192 子格的 color 层(实得 %s)"
			% _layers_brief(doc.map["layers"]))
	_chk(doc.get_subcell(0, 0) == c and doc.sample(1, 0) == c,
			"⑤ get_subcell/sample 应返回 u32 颜色 0x%X(实得 0x%X/0x%X)"
					% [c, doc.get_subcell(0, 0), doc.sample(1, 0)])
	_chk(doc.get_subcell(16, 0) == c, "⑤ 颜色层读取也应环面归一化(16→0)")
	_chk(rgba.size() > 0 and rgba[0] == -13408615,
			"⑤ 层内应存同一批位的有符号读数 0xFF336699 = -13408615(实得 %d)"
					% (rgba[0] if rgba.size() > 0 else 0))
	_chk(_structure_count > s0, "⑤ 颜色层按需建层应发 structure_changed")
	doc.active_layer = 6
	_chk(doc.set_cells(_cells([Vector2i(0, 0)]), 0) == 0 and doc.map["layers"][6] == null,
			"⑤ 写 0 到缺席颜色层不应建层")
	# 纹理层缺席:无操作、不凭空补层
	var sparse: Dictionary = EditorMap.create_map("s", 2, 2)
	sparse["layers"][0] = null
	doc.load_map(sparse)
	doc.active_layer = 0
	_chk(doc.set_cells(_cells([Vector2i(0, 0)]), EditorDesc.neutral_desc(6)) == 0
			and sparse["layers"][0] == null,
			"⑤ 纹理层缺席应无操作、不凭空补空层")
	_chk(doc.get_subcell(0, 0) == 0 and doc.flood_fill(Vector2i(0, 0), EditorDesc.neutral_desc(6)) == 0,
			"⑤ 缺席纹理层读取/油漆桶应 = 0")


# ══ ⑥ undo/redo:往返 + 信号 + dirty ══
func _test_undo_redo() -> void:
	var doc := _fresh()
	var d := EditorDesc.neutral_desc(6)
	var e0 := _changed_count
	_chk(doc.set_cells(_cells([Vector2i(2, 2)]), d) == 1, "⑥ 写入 1 格应返回 1")
	_chk(doc.dirty, "⑥ 改图后 dirty 应 = true")
	_chk(doc.can_undo() and doc.undo_count() == 1 and not doc.can_redo(), "⑥ 应可 undo、redo 为空")
	_chk(_changed_count == e0 + 1 and _last_layer == 1 and _last_idxs == PackedInt32Array([34]),
			"⑥ set_cells 应发 changed(层 1, idx 2*16+2=34)(实得层 %d, idxs %s)"
					% [_last_layer, _last_idxs])
	_chk(doc.undo() == true, "⑥ undo 应返回 true")
	_chk(doc.get_subcell(2, 2) == 0 and doc.dirty, "⑥ undo 应回原值 0 且 dirty 保持 true")
	_chk(not doc.can_undo() and doc.can_redo() and doc.undo_count() == 0, "⑥ undo 后应迁移到 redo 栈")
	_chk(_changed_count == e0 + 2 and _last_layer == 1 and _last_idxs == PackedInt32Array([34]),
			"⑥ undo 应发 changed(层 1, idx 34)")
	_chk(doc.redo() == true, "⑥ redo 应返回 true")
	_chk(doc.get_subcell(2, 2) == d and doc.undo_count() == 1 and not doc.can_redo(),
			"⑥ redo 应回新值、再次可 undo")
	_chk(_changed_count == e0 + 3, "⑥ redo 应再发一次 changed(实得 +%d)" % (_changed_count - e0 - 2))
	_chk(doc.undo() and doc.get_subcell(2, 2) == 0 and not doc.undo(),
			"⑥ 再 undo 回 0 后栈空,再 undo 应 false")
	# 切层后 undo 必须回**条目自己那层**:写回错层会把另一层的数组整个覆盖掉
	var doc3 := _fresh()
	var cc := 0x10203040
	doc3.active_layer = 4
	doc3.set_cells(_cells([Vector2i(4, 2)]), cc)
	doc3.active_layer = 1
	doc3.set_cells(_cells([Vector2i(4, 2)]), d)
	doc3.active_layer = 4                        # 用户切到颜色层再按 Ctrl+Z
	var undo_ok := doc3.undo()
	_chk(undo_ok and int((doc3.map["layers"][1] as Dictionary)["desc"][36]) == 0,
			"⑥ 切层后 undo 应回原纹理层(层 1 的 idx 36 应恢复 0)")
	_chk(int((doc3.map["layers"][4] as Dictionary)["rgba"][36]) == cc,
			"⑥ 切层后 undo 不应覆盖颜色层的 rgba")


# ══ ⑦ begin_stroke/end_stroke:连续两笔并 1 条、空笔画不产生条目 ══
func _test_stroke() -> void:
	var doc := _fresh()
	var d := EditorDesc.neutral_desc(6)
	var e0 := _changed_count
	doc.begin_stroke()
	_chk(doc.set_cells(_cells([Vector2i(1, 1)]), d) == 1, "⑦ 笔画第 1 笔应改 1 格")
	_chk(doc.set_cells(_cells([Vector2i(2, 1)]), d) == 1, "⑦ 笔画第 2 笔应改 1 格")
	_chk(doc.undo_count() == 0, "⑦ 笔画进行中不应落 undo 条目(实得 %d)" % doc.undo_count())
	_chk(_changed_count == e0 + 2, "⑦ 两笔应各发一次 changed(实得 +%d)" % (_changed_count - e0))
	doc.end_stroke()
	_chk(doc.undo_count() == 1, "⑦ 两次 set_cells 应只产生 1 条 undo(实得 %d)" % doc.undo_count())
	_chk(doc.undo() and doc.get_subcell(1, 1) == 0 and doc.get_subcell(2, 1) == 0,
			"⑦ 一条 undo 应同时回退两笔")
	_chk(doc.redo() and doc.get_subcell(1, 1) == d and doc.get_subcell(2, 1) == d,
			"⑦ redo 应同时恢复两笔")
	var u0 := doc.undo_count()
	doc.begin_stroke()
	doc.end_stroke()
	_chk(doc.undo_count() == u0, "⑦ 空笔画不应产生 undo 条目")
	doc.begin_stroke()
	doc.set_cells(_cells([Vector2i(1, 1)]), d)   # 写同值 = 0 改动
	doc.end_stroke()
	_chk(doc.undo_count() == u0, "⑦ 笔画内 0 改动的笔不应产生条目")
	# 同一格在笔画里改两次:undo 回笔画前的值、redo 回笔画最终值
	var doc2 := _fresh()
	var d7 := EditorDesc.neutral_desc(7)
	doc2.begin_stroke()
	doc2.set_cells(_cells([Vector2i(3, 3)]), d)
	doc2.set_cells(_cells([Vector2i(3, 3)]), d7)
	doc2.end_stroke()
	_chk(doc2.undo_count() == 1, "⑦ 同格改两次的笔画应仍只有 1 条 undo")
	_chk(doc2.undo() and doc2.get_subcell(3, 3) == 0, "⑦ 同格改两次 undo 应回笔画前的值 0")
	_chk(doc2.redo() and doc2.get_subcell(3, 3) == d7, "⑦ 同格改两次 redo 应回笔画最终值")


# ══ ⑧ 撤销栈上限:undo_capacity 调小后丢最旧 ══
func _test_undo_capacity() -> void:
	var doc := _fresh()
	doc.undo_capacity = 3
	var d := EditorDesc.neutral_desc(6)
	var changed_total := 0
	for i in 5:
		changed_total += doc.set_cells(_cells([Vector2i(i, 0)]), d)
	_chk(changed_total == 5, "⑧ 5 次单格改图应共改 5 格(实得 %d)" % changed_total)
	_chk(doc.undo_count() == 3, "⑧ undo_capacity=3 时 undo_count 应 = 3(实得 %d)" % doc.undo_count())
	var undos := 0
	while doc.undo():
		undos += 1
	_chk(undos == 3 and not doc.can_undo(), "⑧ 应只能撤销 3 次(实得 %d 次)" % undos)
	_chk(doc.get_subcell(0, 0) == d and doc.get_subcell(1, 0) == d, "⑧ 最旧两条被丢:cell0/cell1 保持新值")
	_chk(doc.get_subcell(2, 0) == 0 and doc.get_subcell(3, 0) == 0 and doc.get_subcell(4, 0) == 0,
			"⑧ 最近三条应被撤销回 0")


# ══ ⑨ load_map:清 undo/redo、dirty=false、structure_changed ══
func _test_load_map() -> void:
	var doc := _fresh()
	var d := EditorDesc.neutral_desc(6)
	doc.set_cells(_cells([Vector2i(0, 0)]), d)
	doc.undo()
	_chk(doc.can_redo(), "⑨ 前提:undo 后 redo 栈应非空")
	var s0 := _structure_count
	var m: Dictionary = EditorMap.create_map("loaded", 5, 4)
	doc.load_map(m)
	_chk(_structure_count > s0, "⑨ load_map 应发 structure_changed(实得 +%d)" % (_structure_count - s0))
	_chk(String(doc.map.get("name", "")) == "loaded" and int(doc.map.get("sub_cols", 0)) == 20,
			"⑨ load_map 应装入同一份地图字典(实得 name=%s sub_cols=%s)"
					% [doc.map.get("name"), doc.map.get("sub_cols")])
	_chk(doc.sub_size() == Vector2i(20, 16), "⑨ 装入后 sub_size 应 = 20×16(实得 %s)" % doc.sub_size())
	_chk(doc.dirty == false, "⑨ load_map 后 dirty 应 = false")
	_chk(doc.undo_count() == 0 and not doc.can_undo() and not doc.can_redo(),
			"⑨ load_map 应清空 undo/redo(undo=%d can_undo=%s can_redo=%s)"
					% [doc.undo_count(), doc.can_undo(), doc.can_redo()])


# ══ ⑩ validate / to_bytes:干净地图 errors 空、编码可被 EditorCodec 解回 ══
func _test_validate_bytes() -> void:
	var doc := _fresh(4, 3)
	var d := EditorDesc.neutral_desc(6)
	doc.set_cells(_cells([Vector2i(0, 0)]), d)
	var rep: Dictionary = doc.validate()
	var errors: Array = rep.get("errors", [])
	_chk(errors.is_empty(), "⑩ 干净地图 validate 应无 errors(实得 %s)" % [errors])
	var enc: Dictionary = doc.to_bytes({"compress": false})
	var ok := bool(enc.get("ok", false))
	_chk(ok, "⑩ to_bytes(compress:false) 应 ok(实得 error=%s)" % String(enc.get("error", "")))
	var bytes: PackedByteArray = enc.get("bytes", PackedByteArray())
	_chk(ok and bytes.size() > 0, "⑩ to_bytes 应产出非空字节(实得 %d)" % bytes.size())
	var dec := EditorCodec.decode_map(bytes)
	var dec_ok := bool(dec.get("ok", false))
	_chk(dec_ok, "⑩ EditorCodec.decode_map 应能读回(实得 error=%s)" % String(dec.get("error", "")))
	var back: Dictionary = dec.get("map", {})
	_chk(dec_ok and int(back.get("sub_cols", 0)) == 16 and int(back.get("sub_rows", 0)) == 12,
			"⑩ 回读尺寸应 = 16×12(实得 %s×%s)"
					% [back.get("sub_cols", -1), back.get("sub_rows", -1)])
	var back_desc := PackedInt32Array()
	var blayers: Array = back.get("layers", [])
	if blayers.size() == 7 and blayers[1] != null:
		back_desc = (blayers[1] as Dictionary).get("desc", PackedInt32Array())
	_chk(back_desc.size() == 192 and back_desc.size() > 0 and back_desc[0] == d,
			"⑩ 回读场景层第 0 格应是写入的 desc(实得 %s)" % _desc0(back_desc))
	var enc2 := doc.to_bytes()
	_chk(bool(enc2.get("ok", false)) \
			and bool(EditorCodec.decode_map(enc2.get("bytes", PackedByteArray())).get("ok", false)),
			"⑩ 默认压缩 to_bytes 也应能读回")


# ── 工具 ────────────────────────────────────────────────────────────────────

func _fresh(cells_w: int = 4, cells_h: int = 3, map_name: String = "t") -> EditorDoc:
	var doc := EditorDoc.new()
	_watch(doc)
	doc.new_map(map_name, cells_w, cells_h)
	return doc


func _watch(doc: EditorDoc) -> void:
	doc.changed.connect(_on_changed)
	doc.structure_changed.connect(_on_structure)


func _on_changed(layer: int, subcells: PackedInt32Array) -> void:
	_changed_count += 1
	_last_layer = layer
	_last_idxs = subcells


func _on_structure() -> void:
	_structure_count += 1


func _cells(list: Array) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for p in list:
		out.append(p)
	return out


func _layers_brief(layers: Array) -> String:
	var parts: PackedStringArray = []
	for L in layers.size():
		var ld = layers[L]
		if ld == null:
			parts.append("null")
			continue
		var d: Dictionary = ld
		var key := "desc" if String(d.get("kind", "")) == "tex" else "rgba"
		parts.append("%s:%d" % [d.get("kind"), (d.get(key, PackedInt32Array()) as PackedInt32Array).size()])
	return "[" + ", ".join(parts) + "]"


func _desc0(a: PackedInt32Array) -> String:
	return "空" if a.is_empty() else "desc[0]=%d" % a[0]
