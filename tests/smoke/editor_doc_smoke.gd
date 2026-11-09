extends SceneTree

# 编辑器文档模型 EditorDoc 守卫(`-s`,headless,不实例化 autoload)。
# 守护 core/editor/editor_doc.gd:环面归一化 / Bresenham / 4 邻接油漆桶 / 稀疏撤销栈 / 颜色层 u32 路径 /
# 信号 / 校验与编码接线;P2 后置项:选区 / 剪贴板(纹理↔颜色互斥) / 镜像 / 颜色层渐变 / meta 可视化编辑。
# 契约 = docs/eng/editor-godot.md §4 + .tmp/p2-extras-contract.md §1。
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
#   ⑪ 选区不裁剪到图内 / w/h<=0 不清空 / load_map 不清选区(或误清剪贴板)⇒ 红。
#   ⑫ 复制粘贴不按子格搬运 / 纹理↔颜色交叉粘贴不拒 / 剪切不产生恰好一条 undo 或不置 0 /
#      粘贴不环面回绕 / 同类重粘不返回 0 ⇒ 红。
#   ⑬ 镜像不按「目标写源」且先读后写 / 两次镜像不回原图 / 无变化产生 undo / 非法轴不拒 ⇒ 红。
#   ⑭ 渐变 t 公式错 / 逐通道不四舍五入 / 非颜色层不拒 / clip_selection 越过选区 / 不是恰好一条 undo ⇒ 红。
#   ⑮ meta 不入 undo / 发错信号(应为 meta_changed 而非 changed)/ undo/redo 不还原 /
#      snapshot 与 map 共享引用 / clear_meta 计数或 kind 语义错 ⇒ 红。
# ★ 期望值按子格坐标手推(地图 4×3 格 ⇒ 16×12 子格),不复用被测函数的返回值自证。

const EXPECTED_CHECKS := 183

var _fails: Array[String] = []
var _checks := 0
var _changed_count := 0
var _meta_count := 0
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
	_test_selection()
	_test_clipboard()
	_test_mirror()
	_test_gradient()
	_test_meta()

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
			+ "颜色层 u32 · undo/redo 往返 · 笔画合并 · 栈上限 · load_map 清栈 · validate/to_bytes 接线 · "
			+ "选区裁剪 · 剪贴板类型互斥 · 镜像 · 颜色层渐变 · meta 快照/undo") % _checks)
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


# ══ ⑪ 选区:裁剪到图内 / 清空 / load_map 清选区但保留剪贴板 ══
func _test_selection() -> void:
	var doc := _fresh()                     # 4×3 格 = 16×12 子格
	_chk(not doc.has_selection() and doc.selection_size() == Vector2i.ZERO,
			"⑪ 新图应无选区(has=%s size=%s)" % [doc.has_selection(), doc.selection_size()])
	doc.set_selection(Rect2i(2, 3, 5, 4))
	_chk(doc.selection == Rect2i(2, 3, 5, 4) and doc.has_selection(),
			"⑪ 图内选区应原样保存(实得 %s)" % doc.selection)
	_chk(doc.selection_size() == Vector2i(5, 4), "⑪ selection_size 应 = 5×4(实得 %s)" % doc.selection_size())
	# 越界一律「裁剪」,不回绕:回绕会让同一块选区出现两份,画布无法画虚框
	doc.set_selection(Rect2i(-2, -3, 5, 4))
	_chk(doc.selection == Rect2i(0, 0, 3, 1),
			"⑪ 左上越界选区应裁到 (0,0,3,1)(实得 %s)" % doc.selection)
	doc.set_selection(Rect2i(14, 10, 10, 10))
	_chk(doc.selection == Rect2i(14, 10, 2, 2),
			"⑪ 右下越界选区应裁到 (14,10,2,2)(实得 %s)" % doc.selection)
	doc.set_selection(Rect2i(20, 20, 2, 2))
	_chk(not doc.has_selection(), "⑪ 完全在图外的选区应清空(实得 %s)" % doc.selection)
	doc.set_selection(Rect2i(3, 3, 0, 4))
	_chk(not doc.has_selection(), "⑪ w<=0 的选区应清空(实得 %s)" % doc.selection)
	doc.set_selection(Rect2i(3, 3, 4, 4))
	doc.clear_selection()
	_chk(not doc.has_selection() and doc.selection_size() == Vector2i.ZERO,
			"⑪ clear_selection 应清空")
	# load_map:清选区、保留剪贴板(跨图粘贴是合理用法)
	doc.set_selection(Rect2i(1, 1, 2, 2))
	doc.copy_selection()
	_chk(not doc.clipboard.is_empty(), "⑪ 前提:复制后剪贴板应非空")
	doc.load_map(EditorMap.create_map("sel2", 5, 4))
	_chk(not doc.has_selection(), "⑪ load_map 应清空选区")
	_chk(not doc.clipboard.is_empty() and int(doc.clipboard.get("w", 0)) == 2
			and int(doc.clipboard.get("h", 0)) == 2,
			"⑪ load_map 应保留剪贴板(实得 %s)" % [doc.clipboard])


# ══ ⑫ 剪贴板:复制/粘贴逐子格相等、环面回绕、纹理↔颜色互斥、剪切一条 undo ══
func _test_clipboard() -> void:
	var doc := _fresh()
	var d1 := EditorDesc.neutral_desc(6)
	var d2 := EditorDesc.neutral_desc(7)
	var d3 := EditorDesc.neutral_desc(8)
	var d4 := EditorDesc.neutral_desc(9)
	var d5 := EditorDesc.neutral_desc(10)
	var d6 := EditorDesc.neutral_desc(11)
	# 3×2 源区(手推:行主序 values[0]=d1 … values[5]=d6)
	doc.set_cells(_cells([Vector2i(0, 0)]), d1)
	doc.set_cells(_cells([Vector2i(1, 0)]), d2)
	doc.set_cells(_cells([Vector2i(2, 0)]), d3)
	doc.set_cells(_cells([Vector2i(0, 1)]), d4)
	doc.set_cells(_cells([Vector2i(1, 1)]), d5)
	doc.set_cells(_cells([Vector2i(2, 1)]), d6)
	doc.set_selection(Rect2i(0, 0, 3, 2))
	var copied := doc.copy_selection()
	_chk(bool(copied.get("ok", false)) and int(copied.get("w", 0)) == 3
			and int(copied.get("h", 0)) == 2 and int(copied.get("count", 0)) == 6,
			"⑫ copy_selection 应 ok 且 3×2/count=6(实得 %s)" % [copied])
	var clip_vals: PackedInt32Array = doc.clipboard.get("values", PackedInt32Array())
	_chk(String(doc.clipboard.get("kind", "")) == "tex" and clip_vals.size() == 6
			and clip_vals[0] == d1 and clip_vals[5] == d6,
			"⑫ 剪贴板应是 tex 3×2 且逐子格值正确(实得 kind=%s size=%d)"
					% [doc.clipboard.get("kind"), clip_vals.size()])
	var undo_before := doc.undo_count()
	var pasted := doc.paste_clipboard(Vector2i(2, 2))   # 格 (2,2) ⇒ 子格 (8,8)
	_chk(bool(pasted.get("ok", false)) and int(pasted.get("count", 0)) == 6,
			"⑫ 粘到空格应改 6 格(实得 %s)" % [pasted])
	var paste_ok := true
	for y in 2:
		for x in 3:
			if doc.get_subcell(8 + x, 8 + y) != doc.get_subcell(x, y):
				paste_ok = false
	_chk(paste_ok and doc.get_subcell(8, 8) == d1 and doc.get_subcell(10, 9) == d6,
			"⑫ 粘贴区逐子格应与源区相等")
	_chk(doc.undo_count() == undo_before + 1, "⑫ 粘贴应恰好一条 undo(实得 %d→%d)"
			% [undo_before, doc.undo_count()])
	var again := doc.paste_clipboard(Vector2i(2, 2))
	_chk(bool(again.get("ok", false)) and int(again.get("count", 0)) == 0
			and doc.undo_count() == undo_before + 1,
			"⑫ 同内容重粘应 count=0 且不产生条目(实得 %s)" % [again])
	# 纹理 → 颜色层:拒绝且 error 提到类型
	doc.active_layer = 4
	var bad1 := doc.paste_clipboard(Vector2i(0, 0))
	_chk(not bool(bad1.get("ok", true)) and String(bad1.get("error", "")).contains("纹理")
			and String(bad1.get("error", "")).contains("类型"),
			"⑫ 纹理剪贴板粘到颜色层应 ok:false 且 error 提到纹理/类型(实得 %s)" % [bad1])
	# 颜色 → 纹理层:反向同样拒绝
	var doc2 := _fresh()
	doc2.active_layer = 4
	var cc := 0x11223344
	_chk(doc2.set_cells(_cells([Vector2i(0, 0), Vector2i(1, 0)]), cc) == 2,
			"⑫ 前提:颜色层写 2 格")
	doc2.set_selection(Rect2i(0, 0, 2, 1))
	var ccopied := doc2.copy_selection()
	_chk(String(doc2.clipboard.get("kind", "")) == "color" and int(ccopied.get("count", 0)) == 2,
			"⑫ 颜色层复制应 kind=color/count=2(实得 %s)" % [ccopied])
	doc2.active_layer = 1
	var bad2 := doc2.paste_clipboard(Vector2i(1, 1))
	_chk(not bool(bad2.get("ok", true)) and String(bad2.get("error", "")).contains("颜色"),
			"⑫ 颜色剪贴板粘到纹理层应 ok:false 且 error 提到颜色(实得 %s)" % [bad2])
	doc2.active_layer = 4
	var cok := doc2.paste_clipboard(Vector2i(1, 1))
	_chk(bool(cok.get("ok", false)) and doc2.get_subcell(4, 4) == cc,
			"⑫ 颜色剪贴板粘回颜色层应成功且逐格相等(实得 %s)" % [cok])
	# 剪切 = 复制 + 置 0 + 恰好一条 undo;区外不动
	var doc3 := _fresh()
	var e1 := EditorDesc.neutral_desc(6)
	var e2 := EditorDesc.neutral_desc(7)
	doc3.set_cells(_cells([Vector2i(1, 1), Vector2i(2, 1)]), e1)
	doc3.set_cells(_cells([Vector2i(1, 2)]), e2)
	doc3.set_selection(Rect2i(1, 1, 2, 1))
	var cut_undo_before := doc3.undo_count()
	var cut_changed_before := _changed_count
	var cut := doc3.cut_selection()
	_chk(bool(cut.get("ok", false)) and int(cut.get("count", 0)) == 2,
			"⑫ 剪切应 ok 且 count=2(实得 %s)" % [cut])
	_chk(doc3.undo_count() == cut_undo_before + 1,
			"⑫ 剪切应恰好产生 1 条 undo(实得 %d→%d)"
					% [cut_undo_before, doc3.undo_count()])
	_chk(_changed_count == cut_changed_before + 1, "⑫ 剪切应只发一次 changed(实得 +%d)"
			% (_changed_count - cut_changed_before))
	_chk(doc3.get_subcell(1, 1) == 0 and doc3.get_subcell(2, 1) == 0
			and doc3.get_subcell(1, 2) == e2,
			"⑫ 剪切应把选区置 0、区外不动")
	_chk(String(doc3.clipboard.get("kind", "")) == "tex" and int(doc3.clipboard.get("w", 0)) == 2
			and int(doc3.clipboard.get("h", 0)) == 1,
			"⑫ 剪切应同时填充剪贴板")
	_chk(doc3.undo() and doc3.get_subcell(1, 1) == e1 and doc3.get_subcell(2, 1) == e1,
			"⑫ undo 应还原剪切内容")
	# 失败路径:无选区 / 空剪贴板 都是 ok:false,不抛错
	var doc4 := _fresh()
	_chk(not bool(doc4.copy_selection().get("ok", true)), "⑫ 无选区复制应 ok:false")
	_chk(not bool(doc4.cut_selection().get("ok", true)), "⑫ 无选区剪切应 ok:false")
	_chk(not bool(doc4.paste_clipboard(Vector2i(0, 0)).get("ok", true)),
			"⑫ 空剪贴板粘贴应 ok:false")
	_chk(doc4.clear_selection_cells() == 0, "⑫ 无选区清除应返回 0")
	# 粘贴跨接缝:5 宽剪贴板以格 (3,2) 为左上角 ⇒ 子格 x=12..16,x=16 回绕到 0
	var doc5 := _fresh()
	for x in 5:
		doc5.set_cells(_cells([Vector2i(x, 0)]), EditorDesc.neutral_desc(6 + x))
	doc5.set_selection(Rect2i(0, 0, 5, 2))
	doc5.copy_selection()
	var wrap_paste := doc5.paste_clipboard(Vector2i(3, 2))
	_chk(bool(wrap_paste.get("ok", false))
			and doc5.get_subcell(12, 8) == EditorDesc.neutral_desc(6)
			and doc5.get_subcell(0, 8) == EditorDesc.neutral_desc(10),
			"⑫ 粘贴应环面回绕(子格 x=16→0)(实得 %s)" % [wrap_paste])


# ══ ⑬ 镜像:只翻选区 / 先读后写 / 两次回原图 / 无变化不入栈 / 非法轴拒 ══
func _test_mirror() -> void:
	var d1 := EditorDesc.neutral_desc(6)
	var d2 := EditorDesc.neutral_desc(7)
	var d3 := EditorDesc.neutral_desc(8)
	var d4 := EditorDesc.neutral_desc(9)
	var d5 := EditorDesc.neutral_desc(10)
	var d6 := EditorDesc.neutral_desc(11)
	# (a) 水平:3×2 选区中左右列互换(中间列不动)⇒ 手推改 4 格
	var doc := _fresh()
	doc.set_cells(_cells([Vector2i(0, 0)]), d1)
	doc.set_cells(_cells([Vector2i(1, 0)]), d2)
	doc.set_cells(_cells([Vector2i(2, 0)]), d3)
	doc.set_cells(_cells([Vector2i(0, 1)]), d4)
	doc.set_cells(_cells([Vector2i(1, 1)]), d5)
	doc.set_cells(_cells([Vector2i(2, 1)]), d6)
	doc.set_selection(Rect2i(0, 0, 3, 2))
	var u0 := doc.undo_count()
	var mh := doc.mirror_selection("h")
	_chk(bool(mh.get("ok", false)) and int(mh.get("count", 0)) == 4,
			"⑬ 水平镜像 3×2 应改 4 格(实得 %s)" % [mh])
	_chk(doc.get_subcell(0, 0) == d3 and doc.get_subcell(1, 0) == d2
			and doc.get_subcell(2, 0) == d1 and doc.get_subcell(0, 1) == d6
			and doc.get_subcell(1, 1) == d5 and doc.get_subcell(2, 1) == d4,
			"⑬ 水平镜像应逐格等于手算结果")
	_chk(doc.undo_count() == u0 + 1, "⑬ 镜像应恰好一条 undo(实得 %d→%d)"
			% [u0, doc.undo_count()])
	var mh2 := doc.mirror_selection("h")
	_chk(bool(mh2.get("ok", false)) and int(mh2.get("count", 0)) == 4
			and doc.get_subcell(0, 0) == d1 and doc.get_subcell(2, 0) == d3
			and doc.get_subcell(0, 1) == d4 and doc.get_subcell(2, 1) == d6,
			"⑬ 连续两次水平镜像应回原图(实得 %s)" % [mh2])
	# 无变化:单格选区 / 回文选区都不产生条目
	doc.set_selection(Rect2i(1, 0, 1, 1))
	var u1 := doc.undo_count()
	var mn := doc.mirror_selection("h")
	_chk(bool(mn.get("ok", false)) and int(mn.get("count", 0)) == 0
			and doc.undo_count() == u1,
			"⑬ 单格镜像应 count=0 且不产生 undo(实得 %s)" % [mn])
	var docp := _fresh()
	docp.set_cells(_cells([Vector2i(0, 0), Vector2i(1, 0)]), d1)
	docp.set_selection(Rect2i(0, 0, 2, 1))
	var up := docp.undo_count()
	var mp := docp.mirror_selection("h")
	_chk(bool(mp.get("ok", false)) and int(mp.get("count", 0)) == 0
			and docp.undo_count() == up,
			"⑬ 回文选区镜像应 count=0 且不产生 undo(实得 %s)" % [mp])
	# 非法轴 / 无选区
	var bad_axis := doc.mirror_selection("x")
	_chk(not bool(bad_axis.get("ok", true))
			and String(bad_axis.get("error", "")).contains("轴"),
			"⑬ 非法 axis 应 ok:false 且 error 提到轴(实得 %s)" % [bad_axis])
	_chk(not bool(_fresh().mirror_selection("h").get("ok", true)),
			"⑬ 无选区镜像应 ok:false")
	# (b) 垂直:2×3 选区中上下行互换 ⇒ 手推改 4 格
	var docv := _fresh()
	var e1 := EditorDesc.neutral_desc(6)
	var e2 := EditorDesc.neutral_desc(7)
	var e3 := EditorDesc.neutral_desc(8)
	var e4 := EditorDesc.neutral_desc(9)
	var e5 := EditorDesc.neutral_desc(10)
	var e6 := EditorDesc.neutral_desc(11)
	docv.set_cells(_cells([Vector2i(0, 0)]), e1)
	docv.set_cells(_cells([Vector2i(0, 1)]), e2)
	docv.set_cells(_cells([Vector2i(0, 2)]), e3)
	docv.set_cells(_cells([Vector2i(1, 0)]), e4)
	docv.set_cells(_cells([Vector2i(1, 1)]), e5)
	docv.set_cells(_cells([Vector2i(1, 2)]), e6)
	docv.set_selection(Rect2i(0, 0, 2, 3))
	var mv := docv.mirror_selection("v")
	_chk(bool(mv.get("ok", false)) and int(mv.get("count", 0)) == 4,
			"⑬ 垂直镜像 2×3 应改 4 格(实得 %s)" % [mv])
	_chk(docv.get_subcell(0, 0) == e3 and docv.get_subcell(0, 1) == e2
			and docv.get_subcell(0, 2) == e1 and docv.get_subcell(1, 0) == e6
			and docv.get_subcell(1, 1) == e5 and docv.get_subcell(1, 2) == e4,
			"⑬ 垂直镜像应逐格等于手算结果")
	_chk(docv.undo() and docv.get_subcell(0, 0) == e1 and docv.get_subcell(0, 2) == e3
			and docv.get_subcell(1, 0) == e4 and docv.get_subcell(1, 2) == e6,
			"⑬ undo 应还原垂直镜像")


# ══ ⑭ 渐变:JS createGradientJob 的 t 投影 + 逐通道四舍五入 + 颜色层限定 ══
func _test_gradient() -> void:
	var rgba0 := 0x11223344
	var rgba1 := 0xDDEECCBB
	var doc := _fresh()                      # 16×12 子格
	doc.active_layer = EditorConstants.LAYER_BG
	var g := doc.paint_gradient(Vector2i(0, 0), Vector2i(15, 11), rgba0, rgba1)
	_chk(bool(g.get("ok", false)) and int(g.get("count", 0)) == 192,
			"⑭ 整层渐变应 ok 且改满 192 子格(实得 %s)" % [g])
	_chk(doc.get_subcell(0, 0) == rgba0,
			"⑭ a 端 t=0 应是 rgba0(实得 0x%X)" % doc.get_subcell(0, 0))
	_chk(doc.get_subcell(15, 11) == rgba1,
			"⑭ b 端 t=1 应是 rgba1(实得 0x%X)" % doc.get_subcell(15, 11))
	_chk(doc.undo_count() == 1, "⑭ 渐变应只产生一条 undo(实得 %d)" % doc.undo_count())
	# 中点近似:(7,5) t = (7*15+5*11)/(15²+11²) = 160/346
	var t_mid := float(7 * 15 + 5 * 11) / float(15 * 15 + 11 * 11)
	var expect_mid := _lerp_ref(rgba0, rgba1, t_mid)
	var actual_mid := doc.get_subcell(7, 5)
	_chk(_channels_close(actual_mid, expect_mid, 1),
			"⑭ 中点 (7,5) 应≈手算 lerp(期望 0x%X,实得 0x%X)"
					% [expect_mid, actual_mid])
	# 同参数再跑一次:0 改动、不入栈
	var u0 := doc.undo_count()
	var g_same := doc.paint_gradient(Vector2i(0, 0), Vector2i(15, 11), rgba0, rgba1)
	_chk(bool(g_same.get("ok", false)) and int(g_same.get("count", 0)) == 0
			and doc.undo_count() == u0,
			"⑭ 同参数再渐变应 count=0 且不产生条目(实得 %s)" % [g_same])
	# dx=dy=0 ⇒ t=0,整层铺 rgba0
	var doc_flat := _fresh()
	doc_flat.active_layer = EditorConstants.LAYER_BG
	var g_flat := doc_flat.paint_gradient(Vector2i(5, 5), Vector2i(5, 5), rgba0, rgba1)
	_chk(bool(g_flat.get("ok", false)) and doc_flat.get_subcell(0, 0) == rgba0
			and doc_flat.get_subcell(15, 11) == rgba0,
			"⑭ dx=dy=0 应 t=0、整层铺 rgba0(实得 %s)" % [g_flat])
	# 逐通道**四舍五入**(不是截断):t=0.5 时 round(15*0.5)=8(截断会给 7)
	var doc_round := _fresh()
	doc_round.active_layer = EditorConstants.LAYER_BG
	var g_round := doc_round.paint_gradient(Vector2i(0, 0), Vector2i(2, 0), 0x00000000, 0x0F0F0F0F)
	_chk(bool(g_round.get("ok", false)) and doc_round.get_subcell(1, 0) == 0x08080808,
			"⑭ t=0.5 的通道应四舍五入到 8(截断会给 7),实得 0x%X"
					% doc_round.get_subcell(1, 0))
	# clip_selection:只改选区 4×3 = 12 格
	var doc_clip := _fresh()
	doc_clip.active_layer = EditorConstants.LAYER_BG
	doc_clip.set_selection(Rect2i(2, 2, 4, 3))
	var gc := doc_clip.paint_gradient(Vector2i(0, 0), Vector2i(15, 11), rgba0, rgba1, true)
	_chk(bool(gc.get("ok", false)) and int(gc.get("count", 0)) == 12,
			"⑭ clip_selection 只改选区 4×3=12 格(实得 %s)" % [gc])
	_chk(doc_clip.get_subcell(2, 2) != 0 and doc_clip.get_subcell(5, 4) != 0,
			"⑭ 选区内(角与角)应被写")
	_chk(doc_clip.get_subcell(1, 2) == 0 and doc_clip.get_subcell(2, 1) == 0
			and doc_clip.get_subcell(6, 5) == 0,
			"⑭ 选区外应保持 0")
	_chk(doc_clip.undo_count() == 1, "⑭ 选区渐变也只一条 undo(实得 %d)" % doc_clip.undo_count())
	# 纹理层:拒绝,且不改图、不 dirty
	var doc_tex := _fresh()
	doc_tex.active_layer = 1
	var bad := doc_tex.paint_gradient(Vector2i(0, 0), Vector2i(15, 11), rgba0, rgba1)
	_chk(not bool(bad.get("ok", true)) and String(bad.get("error", "")).contains("颜色层"),
			"⑭ 纹理层渐变应 ok:false 且 error 提到颜色层(实得 %s)" % [bad])
	_chk(doc_tex.undo_count() == 0 and doc_tex.dirty == false,
			"⑭ 失败的渐变不应改图/dirty(undo=%d dirty=%s)"
					% [doc_tex.undo_count(), doc_tex.dirty])


# ══ ⑮ meta:加/删 player/respawn/enemy、clear_meta、信号、undo/redo、深拷贝 ══
func _test_meta() -> void:
	var doc := _fresh()                     # 4×3 格
	var meta0 := _meta_count
	var changed0 := _changed_count
	_chk(doc.add_player(Vector2i(1, 2)) == 0, "⑮ 第一个出生点应返回索引 0")
	_chk(_meta_count == meta0 + 1 and _changed_count == changed0,
			"⑮ add_player 应只发一次 meta_changed、不发 changed(meta +%d changed +%d)"
					% [_meta_count - meta0, _changed_count - changed0])
	_chk(doc.dirty and doc.undo_count() == 1, "⑮ add_player 应置 dirty 且入 undo")
	var e0: Dictionary = {}
	if not doc._undo.is_empty():
		e0 = doc._undo[0]
	_chk(String(e0.get("kind", "")) == "meta", "⑮ meta 条目应 kind=meta(实得 %s)" % [e0])
	_chk(doc.add_player(Vector2i(-1, 3)) == 1,
			"⑮ 环面归一化:(-1,3) 应落 (3,0) 且返回索引 1")
	_chk(_player_at(doc, 1) == Vector2i(3, 0),
			"⑮ 第二个出生点坐标应 = (3,0)(实得 %s)" % _player_at(doc, 1))
	_chk(doc.remove_player_at(Vector2i(-1, 0)),
			"⑮ remove_player_at 应按归一化坐标删第一个命中")
	_chk((doc.map["players"] as Array).size() == 1 and _player_at(doc, 0) == Vector2i(1, 2),
			"⑮ 删除后应只剩第一个出生点(实得 %s)" % [_players_brief(doc)])
	var meta_miss := _meta_count
	var undo_miss := doc.undo_count()
	_chk(not doc.remove_player_at(Vector2i(2, 2)), "⑮ 删不存在的出生点应 false")
	_chk(_meta_count == meta_miss and doc.undo_count() == undo_miss,
			"⑮ 无改动不应发 meta_changed / 入 undo")
	# 复活点:side 只认 1|2
	_chk(doc.add_respawn(1, Vector2i(1, 1)) == 0, "⑮ add_respawn(1) 应返回 0")
	_chk(doc.add_respawn(2, Vector2i(2, 2)) == 1, "⑮ add_respawn(2) 应返回 1")
	_chk(doc.add_respawn(0, Vector2i(0, 0)) == -1 and doc.add_respawn(3, Vector2i(0, 0)) == -1,
			"⑮ side 非法(0/3)应返回 -1")
	_chk(_respawn_at(doc, 0) == Vector3i(1, 1, 1) and _respawn_at(doc, 1) == Vector3i(2, 2, 2),
			"⑮ 复活点应记 side/x/y(实得 %s/%s)"
					% [_respawn_at(doc, 0), _respawn_at(doc, 1)])
	_chk(doc.remove_respawn_at(2, Vector2i(2, 2))
			and not doc.remove_respawn_at(2, Vector2i(2, 2)),
			"⑮ 删复活点:第一次 true、第二次 false")
	_chk(not doc.remove_respawn_at(0, Vector2i(1, 1)), "⑮ 非法 side 删复活点应 false")
	# 敌人
	_chk(doc.add_enemy("slime", Vector2i(2, 2)) == 0, "⑮ add_enemy 应返回 0")
	_chk(String((doc.map["enemies"][0] as Dictionary).get("type", "")) == "slime",
			"⑮ 敌人类型应写入(实得 %s)" % [doc.map["enemies"][0]])
	_chk(doc.remove_enemy_at(Vector2i(2, 2)) and not doc.remove_enemy_at(Vector2i(2, 2)),
			"⑮ 删敌人:第一次 true、第二次 false")
	# meta_snapshot 深拷贝:改返回值不影响 doc
	var snap := doc.meta_snapshot()
	var snap_players: Array = snap.get("players", [])
	_chk(snap_players.size() == (doc.map["players"] as Array).size(),
			"⑮ meta_snapshot 应包含全部 players(实得 %d/%d)"
					% [snap_players.size(), (doc.map["players"] as Array).size()])
	if not snap_players.is_empty():
		(snap_players[0] as Dictionary)["x"] = 99
		snap_players.append({"x": 7, "y": 7})
	_chk(_player_at(doc, 0) == Vector2i(1, 2) and (doc.map["players"] as Array).size() == 1,
			"⑮ 改 meta_snapshot 返回值不应影响 doc(实得 %s)" % [_players_brief(doc)])
	# undo/redo 还原 meta(快照式条目)
	var doc2 := _fresh()
	doc2.add_player(Vector2i(1, 1))
	doc2.add_respawn(1, Vector2i(0, 0))
	doc2.add_enemy("fly", Vector2i(3, 2))
	var meta_snap := _meta_json(doc2)
	var meta_c0 := _meta_count
	var undo_c0 := doc2.undo_count()
	var cleared := doc2.clear_meta("all")
	_chk(cleared == 3, "⑮ clear_meta(all) 应返回 3(实得 %d)" % cleared)
	_chk(_meta_count == meta_c0 + 1 and doc2.undo_count() == undo_c0 + 1,
			"⑮ clear_meta 应一次 meta_changed / 一条 undo(changed +%d, undo %d→%d)"
					% [_meta_count - meta_c0, undo_c0, doc2.undo_count()])
	_chk(_meta_json(doc2) == _empty_meta_json(), "⑮ clear_meta(all) 后三张表应空")
	_chk(doc2.undo() and _meta_json(doc2) == meta_snap,
			"⑮ undo 应还原 meta 三张表")
	_chk(_meta_count == meta_c0 + 2, "⑮ undo meta 也应发 meta_changed(实得 +%d)"
			% (_meta_count - meta_c0))
	_chk(doc2.redo() and _meta_json(doc2) == _empty_meta_json(),
			"⑮ redo 应再次清空 meta")
	# clear_meta 分 kind / 非法 kind / 空表无条目
	var doc3 := _fresh()
	doc3.add_player(Vector2i(0, 0))
	doc3.add_player(Vector2i(1, 0))
	doc3.add_respawn(1, Vector2i(0, 1))
	doc3.add_enemy("slime", Vector2i(2, 2))
	var u3 := doc3.undo_count()
	var mc3 := _meta_count
	_chk(doc3.clear_meta("players") == 2, "⑮ clear_meta(players) 应返回 2")
	_chk((doc3.map["players"] as Array).is_empty()
			and (doc3.map["respawns"] as Array).size() == 1
			and (doc3.map["enemies"] as Array).size() == 1,
			"⑮ clear_meta(players) 只清 players")
	_chk(_meta_count == mc3 + 1 and doc3.undo_count() == u3 + 1,
			"⑮ clear_meta(players) 应一次 meta_changed / 一条 undo")
	_chk(doc3.clear_meta("bogus") == -1, "⑮ clear_meta 非法 kind 应返回 -1")
	_chk(doc3.clear_meta("players") == 0 and doc3.undo_count() == u3 + 1
			and _meta_count == mc3 + 1,
			"⑮ 空表 clear_meta 应返回 0 且不再发信号/入栈(meta +%d)"
					% (_meta_count - mc3))


# ── 工具 ────────────────────────────────────────────────────────────────────

func _fresh(cells_w: int = 4, cells_h: int = 3, map_name: String = "t") -> EditorDoc:
	var doc := EditorDoc.new()
	_watch(doc)
	doc.new_map(map_name, cells_w, cells_h)
	return doc


func _watch(doc: EditorDoc) -> void:
	doc.changed.connect(_on_changed)
	doc.structure_changed.connect(_on_structure)
	doc.meta_changed.connect(_on_meta)


func _on_changed(layer: int, subcells: PackedInt32Array) -> void:
	_changed_count += 1
	_last_layer = layer
	_last_idxs = subcells


func _on_structure() -> void:
	_structure_count += 1


func _on_meta() -> void:
	_meta_count += 1


func _cells(list: Array) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for p in list:
		out.append(p)
	return out


func _player_at(doc: EditorDoc, i: int) -> Vector2i:
	var arr: Array = doc.map.get("players", [])
	if i < 0 or i >= arr.size():
		return Vector2i(-1, -1)
	var d: Dictionary = arr[i]
	return Vector2i(int(d.get("x", -1)), int(d.get("y", -1)))


func _players_brief(doc: EditorDoc) -> String:
	var parts: PackedStringArray = []
	for i in (doc.map.get("players", []) as Array).size():
		var p := _player_at(doc, i)
		parts.append("(%d,%d)" % [p.x, p.y])
	return "[" + ", ".join(parts) + "]"


func _respawn_at(doc: EditorDoc, i: int) -> Vector3i:
	var arr: Array = doc.map.get("respawns", [])
	if i < 0 or i >= arr.size():
		return Vector3i(-1, -1, -1)
	var d: Dictionary = arr[i]
	return Vector3i(int(d.get("side", 0)), int(d.get("x", -1)), int(d.get("y", -1)))


func _meta_json(doc: EditorDoc) -> String:
	return JSON.stringify(doc.meta_snapshot())


func _empty_meta_json() -> String:
	return JSON.stringify({"players": [], "respawns": [], "enemies": []})


# 冒烟自己的 lerpRGBA(逐通道 round(x+(y-x)*t)&255)—— 与实现分开写,避免自证。
func _lerp_ref(a: int, b: int, t: float) -> int:
	var au := a & 0xFFFFFFFF
	var bu := b & 0xFFFFFFFF
	var out := 0
	for raw_shift in [24, 16, 8, 0]:
		var shift := int(raw_shift)
		var x := (au >> shift) & 255
		var y := (bu >> shift) & 255
		out = (out << 8) | (roundi(float(x) + float(y - x) * t) & 255)
	return out


func _channels_close(a: int, b: int, tol: int) -> bool:
	var au := a & 0xFFFFFFFF
	var bu := b & 0xFFFFFFFF
	for raw_shift in [24, 16, 8, 0]:
		var shift := int(raw_shift)
		if absi(((au >> shift) & 255) - ((bu >> shift) & 255)) > tol:
			return false
	return true


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
