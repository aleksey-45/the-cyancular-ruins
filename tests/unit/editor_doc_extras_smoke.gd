extends "res://tests/unit/editor_doc_smoke.gd"

# 编辑器文档模型的 **P2 后置项**:选区 / 剪贴板(纹理↔颜色互斥) / 镜像 / 颜色层渐变 /
# meta 快照与单条编辑 / 选区整块移动。
# ★ 与 editor_doc_smoke.gd 分文件:失败域不同(基础模型 vs 选区与 meta);夹具、信号计数与断言设施
#   全部继承自 base,不复制一份(否则两份 helper 会漂)。契约见 docs/systems/editor/editor-godot.md §4。
const EXPECTED_CHECKS_EXTRAS := 106


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
			print("EDITOR DOC EXTRAS SMOKE FAILED: load(%s) 为 null(-s 空载守卫:不 quit 会挂死)" % p)
			quit(1)
			return

	_test_selection()
	_test_clipboard()
	_test_mirror()
	_test_gradient()
	_test_meta()
	_test_move_selection()
	_test_meta_position()
	_test_meta_edit()

	if _checks != EXPECTED_CHECKS_EXTRAS:
		print("EDITOR DOC EXTRAS SMOKE FAILED: 只跑了 %d 条 < %d(脚本中途中止 / 忘了更新)" % [_checks, EXPECTED_CHECKS_EXTRAS])
		quit(1)
		return
	if not _fails.is_empty():
		print("EDITOR DOC EXTRAS SMOKE FAILED (%d/%d):" % [_fails.size(), EXPECTED_CHECKS_EXTRAS])
		for f in _fails:
			print("  - " + f)
		quit(1)
		return
	print("EDITOR DOC EXTRAS SMOKE: OK(%d 条断言):选区裁剪 · 剪贴板类型互斥 · 镜像 · 颜色层渐变 · "
			% _checks + "meta 快照/undo · 选区整块移动 · meta 单条改位置")
	quit(0)


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


# ══ ⑯ 选区整块移动:源清空 / 目标落值 / 选区平移 / 重叠以目标值为准 / 仅一条多值 undo ══
func _test_move_selection() -> void:
	var d1 := EditorDesc.neutral_desc(6)
	var d2 := EditorDesc.neutral_desc(7)
	var d3 := EditorDesc.neutral_desc(8)
	# (a) 非重叠移动:源清 0 / 目标落值 / 选区跟随;一条 undo(源∪目标) + 一次 changed,undo/redo 两端还原
	var doc := _fresh()                      # 16×12 子格
	doc.set_cells(_cells([Vector2i(2, 2)]), d1)
	doc.set_cells(_cells([Vector2i(3, 2)]), d2)
	doc.set_selection(Rect2i(2, 2, 2, 1))
	var u0 := doc.undo_count()
	var e0 := _changed_count
	var moved := doc.move_selection_content(Vector2i(4, 3))
	_chk(bool(moved.get("ok", false)) and int(moved.get("count", 0)) == 4
			and doc.get_subcell(2, 2) == 0 and doc.get_subcell(3, 2) == 0
			and doc.get_subcell(6, 5) == d1 and doc.get_subcell(7, 5) == d2
			and doc.selection == Rect2i(6, 5, 2, 1),
			"⑯ 移动应清源/落目标/选区跟随(count=4, 选区 (6,5,2,1);实得 %s/%s)" % [moved, doc.selection])
	# idx = sy*16+sx:源 34/35,目标 86/87
	_chk(doc.undo_count() == u0 + 1 and _changed_count == e0 + 1 and doc.dirty
			and _last_layer == 1 and _last_idxs.size() == 4 and _last_idxs.has(34)
			and _last_idxs.has(35) and _last_idxs.has(86) and _last_idxs.has(87)
			and doc.undo() and doc.get_subcell(2, 2) == d1 and doc.get_subcell(6, 5) == 0
			and doc.redo() and doc.get_subcell(6, 5) == d1,
			"⑯ 移动应一条 undo+一次 changed(源∪目标),undo/redo 还原两端(idxs=%s)" % [_last_idxs])
	# (b) 重叠:源 (4,4)=d1,(5,4)=d2 + offset(1,0) ⇒ (5,4) 以目标写的 d1 为准(不是先清后返 0)
	var doc2 := _fresh()
	doc2.set_cells(_cells([Vector2i(4, 4)]), d1)
	doc2.set_cells(_cells([Vector2i(5, 4)]), d2)
	doc2.set_cells(_cells([Vector2i(6, 4)]), d3)
	doc2.set_selection(Rect2i(4, 4, 2, 1))
	var overlap := doc2.move_selection_content(Vector2i(1, 0))
	_chk(bool(overlap.get("ok", false)) and int(overlap.get("count", 0)) == 3
			and doc2.get_subcell(4, 4) == 0 and doc2.get_subcell(5, 4) == d1
			and doc2.get_subcell(6, 4) == d2,
			"⑯ 重叠格应以目标写的值为准:手推 0/d1/d2(实得 %d/%d/%d)"
					% [doc2.get_subcell(4, 4), doc2.get_subcell(5, 4), doc2.get_subcell(6, 4)])
	# (c) 不环面回绕:左/右/下越界都 ok:false,且选区/历史/dirty 一律不动
	var doc3 := _fresh()
	doc3.set_selection(Rect2i(0, 0, 2, 1))
	var e3 := _changed_count
	var bad_l := doc3.move_selection_content(Vector2i(-1, 0))
	var bad_r := doc3.move_selection_content(Vector2i(15, 0))
	var doc3b := _fresh()
	doc3b.set_selection(Rect2i(15, 11, 1, 1))
	var bad_d := doc3b.move_selection_content(Vector2i(0, 1))
	_chk(not bool(bad_l.get("ok", true)) and not bool(bad_r.get("ok", true))
			and not bool(bad_d.get("ok", true))
			and String(bad_l.get("error", "")).contains("越界")
			and doc3.selection == Rect2i(0, 0, 2, 1) and doc3.undo_count() == 0
			and _changed_count == e3 and doc3.dirty == false,
			"⑯ 左/右/下越界都应 ok:false(不环面回绕)且选区/历史/changed/dirty 不动(实得 %s)" % [bad_l])
	# (d) 失败形状 + offset=0 空操作:没图/没选区/层非法 ⇒ false;offset=0 ⇒ count 0、不入栈、不 dirty
	var no_map := EditorDoc.new()
	var bad_layer_doc := _fresh()
	bad_layer_doc.set_selection(Rect2i(0, 0, 1, 1))
	bad_layer_doc.active_layer = 7
	var doc_z := _fresh()
	doc_z.set_selection(Rect2i(2, 2, 2, 1))
	var zero := doc_z.move_selection_content(Vector2i.ZERO)
	_chk(not bool(no_map.move_selection_content(Vector2i(1, 0)).get("ok", true))
			and not bool(_fresh().move_selection_content(Vector2i(1, 0)).get("ok", true))
			and not bool(bad_layer_doc.move_selection_content(Vector2i(1, 0)).get("ok", true))
			and bool(zero.get("ok", false)) and int(zero.get("count", 0)) == 0
			and doc_z.undo_count() == 0 and doc_z.dirty == false
			and doc_z.selection == Rect2i(2, 2, 2, 1),
			"⑯ 没图/没选区/层非法应 false;offset=0 应 count 0 且不入栈/不 dirty(实得 %s)" % [zero])
	# (e) 缺席层没有内容可搬:count=0、选区照样平移、绝不凭空建层、不入栈
	var doc_miss := _fresh()
	doc_miss.active_layer = 5                 # 层 5 默认 null
	doc_miss.set_selection(Rect2i(1, 1, 2, 2))
	var miss := doc_miss.move_selection_content(Vector2i(2, 0))
	var sparse: Dictionary = EditorMap.create_map("s", 2, 2)       # 8×8 子格
	sparse["layers"][0] = null
	var doc_sparse := EditorDoc.new()
	_watch(doc_sparse)
	doc_sparse.load_map(sparse)
	doc_sparse.active_layer = 0
	doc_sparse.set_selection(Rect2i(0, 0, 2, 2))
	var smiss := doc_sparse.move_selection_content(Vector2i(2, 2))
	_chk(bool(miss.get("ok", false)) and int(miss.get("count", 0)) == 0
			and doc_miss.selection == Rect2i(3, 1, 2, 2)
			and doc_miss.map["layers"][5] == null and doc_miss.undo_count() == 0
			and doc_miss.dirty == false
			and bool(smiss.get("ok", false)) and int(smiss.get("count", 0)) == 0
			and sparse["layers"][0] == null,
			"⑯ 缺席颜色/纹理层应 count=0、选区平移、不凭空建层(实得 %s / %s)" % [miss, smiss])


# ══ ⑰ meta 单条改位置:三种 kind / 环面归一化 / 原地不动 / 越界与非法 kind 拒 / side·type 保留 ══
func _test_meta_position() -> void:
	var doc := _fresh()                      # 4×3 格
	doc.add_player(Vector2i(1, 2))           # player index 0
	doc.add_respawn(1, Vector2i(0, 0))       # respawn index 0
	doc.add_respawn(2, Vector2i(3, 2))       # respawn index 1
	doc.add_enemy("slime", Vector2i(2, 2))   # enemy index 0
	var u0 := doc.undo_count()
	var m0 := _meta_count
	var p_ok := doc.set_meta_position("player", 0, Vector2i(2, 0))
	var r_ok := doc.set_meta_position("respawn", 1, Vector2i(2, 1))
	var e_ok := doc.set_meta_position("enemy", 0, Vector2i(0, 1))
	_chk(p_ok and r_ok and e_ok and doc.undo_count() == u0 + 3 and _meta_count == m0 + 3
			and doc.dirty and _player_at(doc, 0) == Vector2i(2, 0)
			and _respawn_at(doc, 1) == Vector3i(2, 2, 1)
			and _enemy_at(doc, 0) == Vector2i(0, 1)
			and String((doc.map["enemies"][0] as Dictionary).get("type", "")) == "slime",
			"⑰ 三种 kind 应各入一条 meta 条目;respawn 保留 side、enemy 保留 type(实得 %s / %s)"
					% [_respawn_at(doc, 1), doc.map["enemies"][0]])
	# 环面归一化:(-1,4) ⇒ (3,1);(7,1) 归一化后同点 ⇒ 原地不动 false、不入栈
	_chk(doc.set_meta_position("player", 0, Vector2i(-1, 4))
			and _player_at(doc, 0) == Vector2i(3, 1)
			and not doc.set_meta_position("player", 0, Vector2i(7, 1)),
			"⑰ 新位置应环面归一化,归一化后原地不动应 false(实得 %s)" % [_player_at(doc, 0)])
	# 非法 kind / 索引越界:false,不入栈、不发 meta_changed
	var u1 := doc.undo_count()
	var m1 := _meta_count
	var bad_ok := not doc.set_meta_position("players", 0, Vector2i(0, 0)) \
			and not doc.set_meta_position("bogus", 0, Vector2i(0, 0)) \
			and not doc.set_meta_position("player", 1, Vector2i(0, 0)) \
			and not doc.set_meta_position("player", -1, Vector2i(0, 0)) \
			and not doc.set_meta_position("respawn", 2, Vector2i(0, 0)) \
			and not doc.set_meta_position("enemy", 1, Vector2i(0, 0))
	_chk(bad_ok and doc.undo_count() == u1 and _meta_count == m1,
			"⑰ 非法 kind/越界索引应 false 且不入栈/不发信号(undo %d→%d, meta %d→%d)"
					% [u1, doc.undo_count(), m1, _meta_count])
	# undo 四次逐条还原(快照式;含归一化那次),redo 重新应用第一次
	_chk(doc.undo() and doc.undo() and doc.undo() and doc.undo()
			and _player_at(doc, 0) == Vector2i(1, 2)
			and _respawn_at(doc, 1) == Vector3i(2, 3, 2)
			and _enemy_at(doc, 0) == Vector2i(2, 2)
			and doc.redo() and _player_at(doc, 0) == Vector2i(2, 0),
			"⑰ undo 应逐条还原三种 kind,redo 重新应用(实得 player=%s)" % [_player_at(doc, 0)])
	var blank := EditorDoc.new()
	_chk(not blank.set_meta_position("player", 0, Vector2i(0, 0)),
			"⑰ 没建图时改位置应 false")


# ══ ⑱ meta 单项删除 / 改敌人类型 / 扁平列表:顺序保持·保留 x/y·失败不入栈·meta_entries 只读 ══
func _test_meta_edit() -> void:
	var doc := _fresh()                      # 4×3 格
	doc.add_player(Vector2i(0, 0))
	doc.add_player(Vector2i(1, 0))
	doc.add_player(Vector2i(2, 0))
	doc.add_enemy("slime", Vector2i(3, 2))
	var u0 := doc.undo_count()
	var m0 := _meta_count
	_chk(doc.remove_meta_at("player", 1) and (doc.map["players"] as Array).size() == 2
			and _player_at(doc, 0) == Vector2i(0, 0) and _player_at(doc, 1) == Vector2i(2, 0)
			and doc.undo_count() == u0 + 1 and _meta_count == m0 + 1 and doc.dirty
			and doc.undo() and (doc.map["players"] as Array).size() == 3
			and _player_at(doc, 1) == Vector2i(1, 0) and doc.redo()
			and (doc.map["players"] as Array).size() == 2,
			"⑱ 删中间 player 应计数-1、剩余保持 (0,0)(2,0) 顺序、一条 meta 条目+一次 meta_changed,undo/redo 还原(实得 %s)"
					% [_players_brief(doc)])
	# 非法 kind / 越界 / 空表:false,不入栈、不发信号
	var u1 := doc.undo_count()
	var m1 := _meta_count
	var bad_del := not doc.remove_meta_at("players", 0) and not doc.remove_meta_at("bogus", 0) \
			and not doc.remove_meta_at("player", 2) and not doc.remove_meta_at("player", -1) \
			and not doc.remove_meta_at("respawn", 0) and not doc.remove_meta_at("enemy", 1)
	_chk(bad_del and doc.undo_count() == u1 and _meta_count == m1,
			"⑱ 非法 kind/越界/空表删应 false 且不入栈不发信号(undo %d→%d, meta %d→%d)"
					% [u1, doc.undo_count(), m1, _meta_count])
	# 改敌人类型:只改 type、保留 x/y;同类型/越界/空 type 拒
	var u2 := doc.undo_count()
	var m2 := _meta_count
	_chk(doc.set_meta_enemy_type(0, "bat")
			and String((doc.map["enemies"][0] as Dictionary).get("type", "")) == "bat"
			and _enemy_at(doc, 0) == Vector2i(3, 2)
			and doc.undo_count() == u2 + 1 and _meta_count == m2 + 1 and doc.dirty
			and doc.undo()
			and String((doc.map["enemies"][0] as Dictionary).get("type", "")) == "slime"
			and _enemy_at(doc, 0) == Vector2i(3, 2),
			"⑱ 改敌人类型应保留 x/y、恰好一条 meta 条目,undo 还原(实得 %s)" % [doc.map["enemies"]])
	var u3 := doc.undo_count()
	var m3 := _meta_count
	_chk(not doc.set_meta_enemy_type(0, "slime") and not doc.set_meta_enemy_type(1, "bat")
			and not doc.set_meta_enemy_type(-1, "bat") and not doc.set_meta_enemy_type(0, "")
			and not doc.set_meta_enemy_type(0, "  ")
			and doc.undo_count() == u3 and _meta_count == m3,
			"⑱ 同类型/越界/空 type 应 false 且不入栈不发信号(undo %d→%d, meta %d→%d)"
					% [u3, doc.undo_count(), m3, _meta_count])
	# meta_entries:扁平顺序 + 字段形状;不改 dirty/undo、不发信号
	var m: Dictionary = EditorMap.create_map("flat", 4, 3)
	m["players"] = [{"x": 0, "y": 0}, {"x": 1, "y": 0}]
	m["respawns"] = [{"side": 2, "x": 2, "y": 1}]
	m["enemies"] = [{"type": "slime", "x": 3, "y": 2}, {"type": "fly", "x": 1, "y": 1}]
	var doc2 := EditorDoc.new()
	_watch(doc2)
	doc2.load_map(m)
	var m4 := _meta_count
	var flat := doc2.meta_entries()
	var shape_ok := flat.size() == 5
	if shape_ok:
		shape_ok = String(flat[0].get("kind", "")) == "player" \
				and int(flat[0].get("index", -1)) == 0 \
				and int(flat[0].get("x", -1)) == 0 and int(flat[0].get("y", -1)) == 0 \
				and String(flat[1].get("kind", "")) == "player" \
				and int(flat[1].get("index", -1)) == 1 \
				and int(flat[1].get("x", -1)) == 1 and int(flat[1].get("y", -1)) == 0 \
				and String(flat[2].get("kind", "")) == "respawn" \
				and int(flat[2].get("index", -1)) == 0 and int(flat[2].get("side", -1)) == 2 \
				and int(flat[2].get("x", -1)) == 2 and int(flat[2].get("y", -1)) == 1 \
				and String(flat[3].get("kind", "")) == "enemy" \
				and int(flat[3].get("index", -1)) == 0 \
				and String(flat[3].get("type", "")) == "slime" \
				and int(flat[3].get("x", -1)) == 3 and int(flat[3].get("y", -1)) == 2 \
				and String(flat[4].get("kind", "")) == "enemy" \
				and int(flat[4].get("index", -1)) == 1 \
				and String(flat[4].get("type", "")) == "fly"
	_chk(shape_ok and doc2.undo_count() == 0 and not doc2.dirty and _meta_count == m4,
			"⑱ meta_entries 应 players→respawns→enemies 扁平有序、含 kind/index/side/type,不产生 undo·信号·dirty(实得 %s)"
					% [flat])


# ── 工具 ────────────────────────────────────────────────────────────────────
