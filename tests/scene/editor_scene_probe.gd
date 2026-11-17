extends Node

# P2 编辑器场景探针:真实例化 editor_root.tscn,走「打开真实地图 → 改一格 → 保存 → 重开 → 再保存」
# 的字节级往返,并检查撤销/重做、校验、画布纹理。
# 去掉什么它才会红:
#   ① 编辑器场景构建失败/缺 API ⇒ ① 组红;
#   ② EditorIO 打开 .cyrm 不迁移/不解码 ⇒ ② 组红;
#   ③ EditorDoc.set_cells 没落到 map(改完读回不一致)⇒ ③ 组红;
#   ④ 保存链 encode/write 丢数据 ⇒ ⑩ 组「重开再存字节相等」红;
#   ⑤ undo/redo 不工作 ⇒ ④ 组红;
#   ⑥ 画布没建视口纹理 ⇒ ⑤ 组红;
#   ⑦ 编辑器的「行为」坏了:撤销/重做可用态或点击接线、缩放按钮、工具快捷键(含组合键不被裸键吃掉)、
#      按层适用性、校验结果不切 Tab ⇒ ⑦ 组红。★ 版式/控件存在性/宽度数值不自动化(tests.md「配色·版式不写」)。
#   ⑧ 未保存改动能从新建/打开/返回/关窗任一入口静默丢掉 ⇒ ⑧ 组红;
#   ⑨ 移动工具端到端(画布拖拽 → root 接线 → tools 写 doc)断了 ⇒ ⑨ 组红;
#   ⑩ 用了绝对坐标/固定宽度导致控件溢出父容器 ⇒ ⑦ 组「无溢出」红。
# 判据 = 未跑满条数 + 失败清单;退出码只是陪衬。

const EXPECTED_CHECKS := 60
const MAP := "res://maps/newfactory.cyrm"
const A := "user://maps/_editor_scene_probe_a.cyrm"
const EXPORT_C := "user://maps/_editor_scene_probe_export.cyrm"
const USER_EXPORT := "user://maps/untitled.cyrm"
const B := "user://maps/_editor_scene_probe_b.cyrm"
const SUB := Vector2i(20, 20)

var _fails: Array[String] = []
var _checks := 0
var _editor: Control = null
var _doc: EditorDoc = null
var _sp_before := ""
var _mp_before := ""
var _map_before := ""
var _settings_bytes := PackedByteArray()
var _settings_existed := false
var _untitled_existed := false
var _user_export_created := false


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)
		print("  ✗ " + msg)


func _ready() -> void:
	await get_tree().process_frame
	_cleanup()
	_backup_settings()

	var scene: PackedScene = load("res://scenes/editor/editor_root.tscn")
	_chk(scene != null, "① 空载守卫:load(editor_root.tscn) 为 null")
	if scene == null:
		_finish()
		return
	_editor = scene.instantiate() as Control
	_chk(_editor != null, "① editor_root.tscn 实例化失败")
	if _editor == null:
		_finish()
		return
	add_child(_editor)
	_editor.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_editor.size = Vector2(1600, 900)
	await get_tree().process_frame
	await get_tree().process_frame

	_doc = _editor.get_doc() as EditorDoc
	_chk(_doc != null, "① get_doc() 返回 null")
	if _doc == null:
		_finish()
		return

	var opened: Dictionary = _editor.open_path(MAP)
	_chk(bool(opened.get("ok", false)), "② 打开 %s 失败:%s" % [MAP, String(opened.get("error", ""))])
	if not bool(opened.get("ok", false)):
		_finish()
		return
	var sub_size := _doc.sub_size()
	_chk(sub_size.x > 0 and sub_size.y > 0 and (_doc.map["layers"] as Array).size() == 7,
			"② 打开后尺寸/图层不对:sub=%s layers=%d" % [str(sub_size), (_doc.map["layers"] as Array).size()])

	var before := _doc.get_subcell(SUB.x, SUB.y)
	var target := EditorDesc.neutral_desc(6)   # 纹理 6「描边方块」,tile_defs 合法
	_doc.set_cells([SUB], target)
	_chk(_doc.get_subcell(SUB.x, SUB.y) == target,
			"③ set_cells 未落到 map:期望 0x%08X 实得 0x%08X" % [target, _doc.get_subcell(SUB.x, SUB.y)])
	_chk(_doc.dirty, "③ 改图后 dirty 应为 true")

	_chk(_doc.can_undo(), "④ 改图后应有撤销")
	_doc.undo()
	_chk(_doc.get_subcell(SUB.x, SUB.y) == before,
			"④ undo 未恢复旧值:期望 0x%08X 实得 0x%08X" % [before, _doc.get_subcell(SUB.x, SUB.y)])
	_doc.redo()
	_chk(_doc.get_subcell(SUB.x, SUB.y) == target, "④ redo 未恢复新值")

	var save_a: Dictionary = _editor.save_to(A)
	_chk(bool(save_a.get("ok", false)), "② 保存到 %s 失败:%s" % [A, String(save_a.get("error", ""))])

	var reopened: Dictionary = _editor.open_path(A)
	_chk(bool(reopened.get("ok", false)), "② 重开 %s 失败:%s" % [A, String(reopened.get("error", ""))])
	_chk(_doc.get_subcell(SUB.x, SUB.y) == target,
			"② 重开后改动的子格丢了:期望 0x%08X 实得 0x%08X" % [target, _doc.get_subcell(SUB.x, SUB.y)])

	var save_b: Dictionary = _editor.save_to(B)
	_chk(bool(save_b.get("ok", false)), "② 再保存到 %s 失败:%s" % [B, String(save_b.get("error", ""))])
	var raw_a := FileAccess.get_file_as_bytes(A)
	var raw_b := FileAccess.get_file_as_bytes(B)
	_chk(not raw_a.is_empty() and raw_a == raw_b,
			"② 重开再保存不是逐字节相等(%d vs %d 字节)" % [raw_a.size(), raw_b.size()])

	var report: Dictionary = _editor.validate()
	_chk(report.has("errors") and report.has("warnings"), "⑥ validate() 返回形状不对")

	var canvas: EditorCanvas = _editor.call("get_editor_canvas") as EditorCanvas
	_chk(canvas != null, "⑤ get_editor_canvas() 返回 null")
	if canvas != null:
		var tex = canvas.view_texture()
		_chk(tex != null and tex.get_width() > 0 and tex.get_height() > 0,
				"⑤ 画布视口纹理为空(期望非空)")

	await _check_ui_layout()
	await _check_dirty_guard()
	await _check_move_tools()
	_check_export_and_load()
	_check_deferred_features()
	_restore_settings()
	_cleanup()
	_finish()


# ── 移动工具端到端:画布拖拽 → root 接线 → editor_tools 写 doc(撤销各一条)──
func _check_move_tools() -> void:
	var canvas: EditorCanvas = _editor.call("get_editor_canvas") as EditorCanvas
	canvas.set_camera(Vector2.ZERO, 16.0)
	_doc.active_layer = 1
	canvas.set_active_layer(1)
	_doc.clear_meta("all")
	var d := EditorDesc.neutral_desc(7)
	_doc.set_cells([Vector2i(10, 10)], d)
	_doc.set_selection(Rect2i(8, 8, 8, 8))
	canvas.set_selection(_doc.selection)
	(_editor.find_child("ToolMove", true, false) as Button).pressed.emit()
	await get_tree().process_frame
	# 选区屏幕矩形 = (128,128,128,128);按 (192,192) 拖到 (224,208) ⇒ Δ 子格 (2,1)
	_canvas_click(canvas, Vector2(192, 192), true)
	_canvas_drag(canvas, Vector2(224, 208))
	_canvas_click(canvas, Vector2(224, 208), false)
	await get_tree().process_frame
	var sel_moved := _doc.get_subcell(10, 10) == 0 and _doc.get_subcell(12, 11) == d \
			and _doc.selection.position == Vector2i(10, 9)
	_doc.undo()

	# meta 拖拽:出生点格 (2,2) 中心 = 屏幕 (160,160),拖到 (224,224) ⇒ 格 (3,3)
	_doc.clear_meta("all")
	_doc.add_player(Vector2i(2, 2))
	canvas.refresh()
	await get_tree().process_frame
	_canvas_click(canvas, Vector2(160, 160), true)
	_canvas_drag(canvas, Vector2(224, 224))
	_canvas_click(canvas, Vector2(224, 224), false)
	await get_tree().process_frame
	var players: Array = _doc.map["players"]
	var meta_moved := players.size() == 1 and int(players[0]["x"]) == 3 \
			and int(players[0]["y"]) == 3
	_chk(sel_moved and meta_moved,
			"⑨ 移动工具端到端应写 doc:选区搬到 (12,11) 且 meta 改到 (3,3)(实得 sel=%s, players=%s)"
			% [str(sel_moved), str(players)])
	_doc.undo()
	(_editor.find_child("ToolBrush", true, false) as Button).pressed.emit()
	await get_tree().process_frame


# 合成鼠标事件直达画布(与真实输入同一条 _gui_input 路径)。
func _canvas_click(canvas: EditorCanvas, pos: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = pos
	canvas._gui_input(ev)


func _canvas_drag(canvas: EditorCanvas, pos: Vector2) -> void:
	var mm := InputEventMouseMotion.new()
	mm.position = pos
	canvas._gui_input(mm)


# ── 未保存改动拦截:新建/打开/返回/关窗前必须先确认(dirty=true)────────────────
# 判据:脏的时候点「文件→新建」必须先出 DiscardDialog、且不立刻换图;确认后才开新建弹层;
# 干净的时候同一入口必须直接开新建弹层(不该无谓多一步);打开/返回/关窗各一条。
func _check_dirty_guard() -> void:
	_doc.set_cells([Vector2i(21, 21)], EditorDesc.neutral_desc(6))
	var file_menu := _editor.find_child("FileMenu", true, false) as MenuButton
	file_menu.get_popup().id_pressed.emit(0)          # 文件 → 新建
	await get_tree().process_frame
	await get_tree().process_frame
	var discard := _editor.get_node_or_null("DiscardDialog") as ConfirmationDialog
	_chk(discard != null and discard.visible and discard.title.find("未保存") >= 0,
			"⑧ 有未保存改动时「新建」应先弹确认弹层(实得 %s)" % (discard.title if discard != null else "null"))
	if discard != null:
		discard.confirmed.emit()
	await get_tree().process_frame
	await get_tree().process_frame
	var new_dlg := _editor.get_node_or_null("Dialog") as ConfirmationDialog
	_chk(new_dlg != null and new_dlg.visible and new_dlg.title.find("新建") >= 0,
			"⑧ 确认「放弃改动」后应继续打开新建地图弹层(实得 %s)" % (new_dlg.title if new_dlg != null else "null"))
	if new_dlg != null:
		new_dlg.hide()
		new_dlg.queue_free()
	await get_tree().process_frame
	_doc.dirty = false
	file_menu.get_popup().id_pressed.emit(0)          # 干净状态下同一入口:不该再弹确认
	await get_tree().process_frame
	await get_tree().process_frame
	var clean_dlg := _editor.get_node_or_null("Dialog") as ConfirmationDialog
	_chk(_editor.get_node_or_null("DiscardDialog") == null and clean_dlg != null
			and clean_dlg.title.find("新建") >= 0,
			"⑧ 无未保存改动时「新建」应直接开新建弹层(不再多一步确认)")
	if clean_dlg != null:
		clean_dlg.hide()
		clean_dlg.queue_free()
	await get_tree().process_frame

	# 关窗走的是另一条通知路径(NOTIFICATION_WM_CLOSE_REQUEST),单独钉;
	# 新建/打开/返回共用同一个 _confirm_discard,上面已用「新建」覆盖。
	_doc.dirty = true
	_editor.notification(NOTIFICATION_WM_CLOSE_REQUEST)
	await get_tree().process_frame
	await get_tree().process_frame
	var close_discard := _editor.get_node_or_null("DiscardDialog") as ConfirmationDialog
	_chk(close_discard != null and close_discard.visible,
			"⑧ dirty 时关窗(NOTIFICATION_WM_CLOSE_REQUEST)也要先确认")
	if close_discard != null:
		close_discard.hide()
		close_discard.queue_free()
	await get_tree().process_frame
	_doc.dirty = false


# ── P3 导出两动作:只写文件的 export_to + Export&Load 的 Settings/MazeGenerator 状态 ──
func _check_export_and_load() -> void:
	var res: Dictionary = _editor.export_and_load(EXPORT_C, true, false)
	_chk(bool(res.get("ok", false)), "⑥ export_and_load 失败:%s" % String(res.get("error", "")))
	_chk(Settings.sp_map_path == EXPORT_C,
			"⑥ 导出并加载后 Settings.sp_map_path 应为 %s(实得 %s)" % [EXPORT_C, Settings.sp_map_path])
	_chk(MazeGenerator.map_file_path() == EXPORT_C,
			"⑥ 导出并加载后下一次 map_file_path() 应返回该文件(实得 %s)" % MazeGenerator.map_file_path())
	_chk(Settings.mp_map_path == _mp_before,
			"⑥ PvP 地图设置不该被「导出并加载」改动(%s → %s)" % [_mp_before, Settings.mp_map_path])
	# persist=true ⇒ Settings.save() 必须把单人地图路径写进 user://settings.cfg(下次开局仍用它)。
	var cf := ConfigFile.new()
	var cfg_ok := cf.load("user://settings.cfg") == OK
	_chk(cfg_ok and String(cf.get_value("single", "map_path", "")) == EXPORT_C,
			"⑥ 导出并加载的持久化没写进 settings.cfg(single/map_path=「%s」)" % String(cf.get_value("single", "map_path", "")))
	var exp: Dictionary = _editor.export_to("user")
	_chk(bool(exp.get("ok", false)), "⑥ 导出(只写文件)失败:%s" % String(exp.get("error", "")))
	_user_export_created = bool(exp.get("ok", false))
	_chk(_user_export_created and FileAccess.file_exists(USER_EXPORT)
			and FileAccess.get_file_as_bytes(USER_EXPORT).size() > 0,
			"⑥ 导出后文件应存在且非空:%s" % USER_EXPORT)


# ── 后置项:选区/剪贴板/镜像/渐变/meta 可视化/真渲染预览(都在场景里真接一遍) ──
# ── UI 行为:撤销重做/快捷键/按层适用性(版式数值按 test-economy 不自动化) ──


func _check_ui_layout() -> void:
	# 等布局结算(含 editor_root 的 _layout_split 延后一帧推右栏宽)
	await get_tree().process_frame
	await get_tree().process_frame

	var split := _editor.find_child("Split", true, false) as HSplitContainer
	var tabs := _editor.find_child("RightTabs", true, false) as TabContainer
	var tool_strip := _editor.find_child("ToolStrip", true, false) as GridContainer
	var pal := _editor.find_child("PaletteGrid", true, false) as GridContainer
	if split == null or tabs == null or tool_strip == null or pal == null:
		for _i in 3:
			_chk(false, "⑦ 结构缺失:跳过后续布局断言")
		return
	_chk(split.is_visible_in_tree() and tabs.is_visible_in_tree(),
			"⑦ 找不到可见的 Split/RightTabs")

	# 右栏只剩 2 个 Tab:选区·meta / 校验消息(图层与画刷已拆成常驻区域)
	_chk(tabs.get_tab_count() == 2,
			"⑦ 右栏 Tab 数期望 2(选区·meta / 校验·消息),实得 %d" % tabs.get_tab_count())

	# 分栏可拖拽(布局行为,不是版式数值)
	var before_w := tabs.size.x
	split.split_offset -= 120
	await get_tree().process_frame
	var dragged_w := tabs.size.x
	split.split_offset += 120
	await get_tree().process_frame
	_chk(dragged_w > before_w + 60.0 and absf(tabs.size.x - before_w) < 2.0,
			"⑦ 拖拽分栏应改变右栏宽(前 %.1f / 拖后 %.1f / 复位 %.1f)" % [before_w, dragged_w, tabs.size.x])

	# 撤销/重做:点击真回退/重做;笔画收尾(history_changed)后立刻可用
	var undo_btn := _editor.find_child("UndoBtn", true, false) as Button
	var redo_btn := _editor.find_child("RedoBtn", true, false) as Button
	var cur_val := _doc.get_subcell(2, 2)
	var alt_val := EditorDesc.neutral_desc(6) if cur_val != EditorDesc.neutral_desc(6) \
			else EditorDesc.neutral_desc(7)
	_doc.set_cells([Vector2i(2, 2)], alt_val)
	undo_btn.pressed.emit()
	_chk(_doc.get_subcell(2, 2) == cur_val and not redo_btn.disabled,
			"⑦ 点撤销按钮应把值退回去、重做按钮应变可用")
	_doc.undo()
	_doc.begin_stroke()
	_doc.set_cells([Vector2i(2, 2)], alt_val)
	_doc.end_stroke()
	_chk(not undo_btn.disabled,
			"⑦ 笔画收尾(history_changed)后撤销按钮应立即可用,不能等下一次改动")
	_doc.undo()

	# 左栏工具网格 / 调色板缩略图 / 右栏 7 层(与既有覆盖面对齐;版式数值不自动化)
	var tool_n := tool_strip.find_children("*", "Button", true, false).size()
	_chk(tool_n == 10, "⑦ 左栏工具网格应有 10 个工具按钮(含 移动/手形;实得 %d)" % tool_n)
	_chk(pal.get_child_count() >= 10,
			"⑦ 左栏应铺纹理缩略图(实得 %d 个)" % pal.get_child_count())
	var layer_btns := 0
	for node in _editor.find_children("*", "Button", true, false):
		if _is_layer_button((node as Button).text):
			layer_btns += 1
	_chk(layer_btns == 7, "⑦ 图层区应有 7 层按钮(实得 %d)" % layer_btns)

	var canvas: EditorCanvas = _editor.call("get_editor_canvas") as EditorCanvas

	# 工具快捷键:单键 H/V/B 分别切手形/移动/画笔;Ctrl+V 与 Shift+H 不被裸键吃掉
	_press_editor_key(KEY_H)
	var h_ok := canvas.is_pan_tool()
	_press_editor_key(KEY_V)
	var v_ok := canvas.is_move_tool()
	_press_editor_key(KEY_B)
	var b_ok := not canvas.is_pan_tool() and not canvas.is_move_tool()
	_chk(h_ok and v_ok and b_ok,
			"⑦ 工具快捷键 H/V/B 应分别切手形/移动/画笔(H=%s V=%s B=%s)" % [h_ok, v_ok, b_ok])
	_press_editor_key(KEY_V, true, false)
	_press_editor_key(KEY_H, false, true)
	_chk(not canvas.is_move_tool() and not canvas.is_pan_tool(),
			"⑦ Ctrl+V / Shift+H 不应被单键 V/H 工具吃掉")

	# 工具/面板按当前层类型适用性 + 渐进披露:纹理层只显示调色板,颜色层只显示颜色
	var grad_btn := _editor.find_child("ToolGradient", true, false) as Button
	var brush_color_btn := _editor.find_child("BrushColor", true, false) as ColorPickerButton
	var layer1_btn := _editor.find_child("Layer1", true, false) as Button
	var layer3_btn := _editor.find_child("Layer3", true, false) as Button
	layer3_btn.pressed.emit()                       # 切到颜色层(背景 100%)
	await get_tree().process_frame
	_chk(not grad_btn.disabled and brush_color_btn.is_visible_in_tree()
			and brush_color_btn.color.a > 0.9 and not pal.is_visible_in_tree(),
			"⑦ 颜色层应启用渐变/颜色(默认色不透明),并隐藏纹理调色板(渐进披露)")
	grad_btn.pressed.emit()
	await get_tree().process_frame
	var grad_active := grad_btn.theme_type_variation == &"ToolActive"
	layer1_btn.pressed.emit()                       # 切回纹理层(场景)
	await get_tree().process_frame
	_press_editor_key(KEY_T)
	_chk(grad_active and grad_btn.disabled and not brush_color_btn.is_visible_in_tree()
			and pal.is_visible_in_tree()
			and _editor.find_child("ToolBrush", true, false).theme_type_variation == &"ToolActive",
			"⑦ 纹理层应禁用渐变/隐藏颜色、恢复调色板;渐变/按 T 都不得进入(应停在画笔)")
	# 颜色层吸管:吸的是 RGBA 并回写取色器(纹理层吸的是 desc)
	layer3_btn.pressed.emit()
	await get_tree().process_frame
	var eyedrop_color := 0x336699FF
	_doc.set_cells([Vector2i(5, 5)], eyedrop_color)
	canvas.set_camera(Vector2.ZERO, 16.0)
	(_editor.find_child("ToolEyedrop", true, false) as Button).pressed.emit()
	await get_tree().process_frame
	_canvas_click(canvas, Vector2(88, 88), true)
	await get_tree().process_frame
	_chk(brush_color_btn.color.is_equal_approx(Color8(0x33, 0x66, 0x99, 0xFF))
			and _editor.find_child("ToolBrush", true, false).theme_type_variation == &"ToolActive",
			"⑦ 颜色层吸管应把 0x336699FF 写回取色器并回画笔(实得 %s)" % str(brush_color_btn.color))
	layer1_btn.pressed.emit()                       # 收尾:回纹理层 + 画笔,后续检查不依赖层类型
	await get_tree().process_frame

	# 当前层的眼睛不可关:控件不再出现「显示关但画布还在画」
	var layer1_vis := _editor.find_child("Layer1Vis", true, false) as CheckButton
	var vis_disabled := layer1_vis != null and layer1_vis.disabled
	var vis_pressed := layer1_vis != null and layer1_vis.button_pressed
	_chk(vis_disabled and vis_pressed,
			"⑦ 当前编辑层的眼睛应禁用并保持显示为开(实得 disabled=%s pressed=%s)"
			% [str(vis_disabled), str(vis_pressed)])

	# meta 放置模式:画刷框被抑制;选工具自动退出放置模式
	(_editor.find_child("MetaPlayer", true, false) as Button).pressed.emit()
	await get_tree().process_frame
	var meta_on := canvas.is_meta_mode_active()
	(_editor.find_child("ToolBrush", true, false) as Button).pressed.emit()
	await get_tree().process_frame
	_chk(meta_on and not canvas.is_meta_mode_active(),
			"⑦ 放置模式应抑制画刷框、选工具应自动退出放置模式(实得 on=%s / off=%s)"
			% [str(meta_on), str(not canvas.is_meta_mode_active())])

	# 敌人类型来自 enemies.json(不再写死非法 "slime");已放置列表可单条删除
	var enemy_opt := _editor.find_child("EnemyTypeOption", true, false) as OptionButton
	var enemies_before := (_doc.map["enemies"] as Array).size()
	(_editor.find_child("MetaEnemy", true, false) as Button).pressed.emit()
	await get_tree().process_frame
	canvas.set_camera(Vector2.ZERO, 16.0)
	_canvas_click(canvas, Vector2(120, 120), true)   # 格 (1,1)
	await get_tree().process_frame
	var enemies_after: Array = _doc.map["enemies"]
	var placed_ok := enemies_after.size() == enemies_before + 1
	var placed_type := ""
	if placed_ok:
		placed_type = String((enemies_after[enemies_after.size() - 1] as Dictionary).get("type", ""))
	var meta_list := _editor.find_child("MetaList", true, false) as VBoxContainer
	var type_changed := false
	if meta_list.get_child_count() > 0:
		var last_row := meta_list.get_child(meta_list.get_child_count() - 1) as Control
		var row_opt: OptionButton = null
		for node in last_row.find_children("*", "", true, false):
			if node is OptionButton:
				row_opt = node as OptionButton
				break
		if row_opt != null and row_opt.item_count > 1:
			var new_type := row_opt.get_item_text(1)
			row_opt.item_selected.emit(1)        # 模拟用户在下拉里改类型
			await get_tree().process_frame
			var enemy_list: Array = _doc.map["enemies"]
			type_changed = enemies_before < enemy_list.size() \
					and String((enemy_list[enemies_before] as Dictionary).get("type", "")) == new_type
	var del_btn: Button = null
	if meta_list.get_child_count() > 0:
		var last_row2 := meta_list.get_child(meta_list.get_child_count() - 1) as Control
		for node in last_row2.find_children("*", "", true, false):
			if node is Button and (node as Button).text == "删除":
				del_btn = node as Button
				break
	var had_del := del_btn != null
	if del_btn != null:
		del_btn.pressed.emit()
	await get_tree().process_frame
	_chk(placed_ok and placed_type == enemy_opt.get_item_text(0) and type_changed and had_del
			and (_doc.map["enemies"] as Array).size() == enemies_before,
			"⑦ 放敌人应用下拉里的合法类型、列表改类型、逐条删除(默认 %s 实得 %s / changed=%s / del=%s)"
			% [enemy_opt.get_item_text(0), placed_type, str(type_changed), str(had_del)])
	(_editor.find_child("ToolBrush", true, false) as Button).pressed.emit()
	await get_tree().process_frame

	# 顶栏「保存」主按钮:写盘并清 dirty
	_doc.set_cells([Vector2i(2, 2)], EditorDesc.neutral_desc(9))
	var dirty_before_save := _doc.dirty
	(_editor.find_child("SaveBtn", true, false) as Button).pressed.emit()
	await get_tree().process_frame
	await get_tree().process_frame
	_chk(dirty_before_save and not _doc.dirty, "⑦ 顶栏保存按钮应写盘并清 dirty")

	# 渐变默认只作用于选区:无选区时必须拒绝,不能整层覆盖
	layer3_btn.pressed.emit()
	await get_tree().process_frame
	_doc.set_selection(Rect2i())
	canvas.set_selection(Rect2i())
	(_editor.find_child("ToolGradient", true, false) as Button).pressed.emit()
	await get_tree().process_frame
	var undo_before_grad := _doc.undo_count()
	_canvas_click(canvas, Vector2(120, 120), true)
	_canvas_drag(canvas, Vector2(160, 140))
	_canvas_click(canvas, Vector2(160, 140), false)
	await get_tree().process_frame
	_chk(_doc.undo_count() == undo_before_grad,
			"⑦ 无选区时渐变应拒绝,不得整层覆盖(undo %d→%d)"
			% [undo_before_grad, _doc.undo_count()])
	(_editor.find_child("ToolBrush", true, false) as Button).pressed.emit()
	layer1_btn.pressed.emit()
	await get_tree().process_frame

	# 无溢出:每个可见 Control 都在父 Control 的 rect 内(容差 1px;ScrollContainer 内容不查)。
	var bad: Array[String] = []
	_collect_overflow(_editor, bad)
	_chk(bad.is_empty(), "⑦ 控件溢出父容器(应为 0 个):%s" % str(bad))


# 合成一个按键事件直接喂给编辑器根(_unhandled_input 会按 editor_ InputMap 判定)。
func _press_editor_key(code: int, ctrl := false, shift := false) -> void:
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.physical_keycode = code
	ev.ctrl_pressed = ctrl
	ev.shift_pressed = shift
	_editor._unhandled_input(ev)


func _is_layer_button(text: String) -> bool:
	for name in EditorConstants.LAYER_NAMES:
		if text == String(name):
			return true
	return false


func _collect_overflow(node: Node, bad: Array[String]) -> void:
	for child in node.get_children():
		if child is Window:
			continue                                  # 标准弹层是独立窗口,不参与页面 rect 检查
		if child is ScrollContainer:
			continue                                  # 滚动区内容可高于/宽于视口,不算溢出
		if child is Control:
			var c: Control = child
			var p := c.get_parent() as Control
			if p != null and c.is_visible_in_tree():
				var pr := Rect2(Vector2.ZERO, p.size)
				var cr := Rect2(c.position, c.size)
				if cr.position.x < pr.position.x - 1.0 or cr.position.y < pr.position.y - 1.0 						or cr.end.x > pr.end.x + 1.0 or cr.end.y > pr.end.y + 1.0:
					bad.append("%s(%s)" % [c.name, c.get_class()])
		_collect_overflow(child, bad)


func _check_deferred_features() -> void:
	var sel := Rect2i(0, 0, 8, 8)
	_doc.set_selection(sel)
	_chk(_doc.has_selection() and _doc.selection == sel, "⑨ 选区设置/回读:%s" % str(_doc.selection))

	var d := EditorDesc.neutral_desc(6)
	_doc.active_layer = 1
	var cells: Array[Vector2i] = []
	for sy in 2:
		for sx in 2:
			cells.append(Vector2i(SUB.x + sx, SUB.y + sy))
	_doc.set_cells(cells, d)
	_doc.set_selection(Rect2i(SUB.x, SUB.y, 2, 2))
	var copied := _doc.copy_selection()
	_chk(bool(copied.get("ok", false)) and int(copied.get("w", 0)) == 2 and int(copied.get("h", 0)) == 2,
			"⑨ 复制 2×2 选区:%s" % str(copied))

	var at := Vector2i(60, 60)
	_doc.set_selection(Rect2i())
	var pasted := _doc.paste_clipboard(at)
	_chk(bool(pasted.get("ok", false)) and _doc.get_subcell(at.x * 4, at.y * 4) == d,
			"⑨ 粘贴到格 (60,60) 未落到 map(实得 0x%08X)" % _doc.get_subcell(at.x * 4, at.y * 4))

	# 真图在 (80,80) 附近本来就有地形 ⇒ 先把 4×4 选区清成空气再摆左两列,期望值不依赖原图内容。
	var d2 := EditorDesc.neutral_desc(7)
	var clear_cells: Array[Vector2i] = []
	var left: Array[Vector2i] = []
	for sy in 4:
		for sx in 4:
			clear_cells.append(Vector2i(80 + sx, 80 + sy))
			if sx < 2:
				left.append(Vector2i(80 + sx, 80 + sy))
	_doc.set_cells(clear_cells, 0)
	_doc.set_cells(left, d2)
	_doc.set_selection(Rect2i(80, 80, 4, 4))
	var mirrored := _doc.mirror_selection("h")
	_chk(bool(mirrored.get("ok", false)) and _doc.get_subcell(83, 80) == d2 and _doc.get_subcell(80, 80) == 0,
			"⑨ 水平镜像选区未翻转到右列")

	_doc.active_layer = 3
	var grad := _doc.paint_gradient(Vector2i(0, 0),
			Vector2i(_doc.sub_size().x - 1, _doc.sub_size().y - 1), 0xFF0000FF, 0x0000FFFF)
	var g0 := _doc.get_subcell(0, 0) & 0xFFFFFFFF
	_chk(bool(grad.get("ok", false)) and g0 == 0xFF0000FF,
			"⑨ 颜色层渐变起点应= rgba0(实得 0x%08X)" % g0)

	# 真图本来就可能带 PvP 出生点/复活点 ⇒ 全部用「加之前 vs 加之后」的差来断言。
	var players_before := (_doc.map["players"] as Array).size()
	var respawns_before := (_doc.map["respawns"] as Array).size()
	var enemies_before := (_doc.map["enemies"] as Array).size()
	_doc.add_player(Vector2i(3, 3))
	_doc.add_respawn(1, Vector2i(4, 4))
	_doc.add_enemy("slime", Vector2i(5, 5))
	_chk((_doc.map["players"] as Array).size() == players_before + 1
			and (_doc.map["respawns"] as Array).size() == respawns_before + 1
			and (_doc.map["enemies"] as Array).size() == enemies_before + 1,
			"⑨ meta add_player/add_respawn/add_enemy 数量不对")
	_chk(_doc.remove_player_at(Vector2i(3, 3)) and (_doc.map["players"] as Array).size() == players_before,
			"⑨ remove_player_at 未删掉")
	var expected_clear := players_before + (respawns_before + 1) + (enemies_before + 1)
	var cleared := _doc.clear_meta("all")
	_chk(cleared == expected_clear
			and (_doc.map["players"] as Array).is_empty()
			and (_doc.map["respawns"] as Array).is_empty()
			and (_doc.map["enemies"] as Array).is_empty(),
			"⑨ clear_meta(all) 应删 %d 条并清空(实得 %d)" % [expected_clear, cleared])

	_editor.set_preview(true)
	var preview: Control = _editor.get_preview()
	_chk(bool(_editor.is_preview_on()) and preview != null, "⑨ 打开预览失败")
	if preview != null:
		var st: Dictionary = preview.stats()
		_chk(bool(st.get("ready", false)) and int(st.get("tiles", 0)) > 0,
				"⑨ 预览应已建好并铺了瓦片:%s" % str(st))
	_editor.set_preview(false)
	_chk(not bool(_editor.is_preview_on()), "⑨ 关闭预览失败")



func _backup_settings() -> void:
	_sp_before = Settings.sp_map_path
	_mp_before = Settings.mp_map_path
	_map_before = MazeGenerator.map_file_path()
	_settings_existed = FileAccess.file_exists("user://settings.cfg")
	if _settings_existed:
		_settings_bytes = FileAccess.get_file_as_bytes("user://settings.cfg")
	_untitled_existed = FileAccess.file_exists(USER_EXPORT)


func _restore_settings() -> void:
	Settings.sp_map_path = _sp_before
	Settings.mp_map_path = _mp_before
	MazeGenerator.set_map_file(_map_before)
	if _settings_existed:
		var f := FileAccess.open("user://settings.cfg", FileAccess.WRITE)
		if f != null:
			f.store_buffer(_settings_bytes)
			f.close()
	elif FileAccess.file_exists("user://settings.cfg"):
		DirAccess.remove_absolute("user://settings.cfg")


func _cleanup() -> void:
	for p in [A, B, EXPORT_C]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	if _user_export_created and not _untitled_existed and FileAccess.file_exists(USER_EXPORT):
		DirAccess.remove_absolute(USER_EXPORT)


func _finish() -> void:
	# 条数闸 = 恰好相等:少了 = 脚本中途中止(断言被静默跳过);多了 = 忘更新 EXPECTED_CHECKS。
	if _checks != EXPECTED_CHECKS:
		if _checks < EXPECTED_CHECKS:
			print("EDITOR SCENE PROBE: FAIL | 只跑了 %d 条 < %d(脚本中途中止)"
					% [_checks, EXPECTED_CHECKS])
		else:
			print("EDITOR SCENE PROBE: FAIL | 跑了 %d 条 > %d(EXPECTED_CHECKS 忘了加)"
					% [_checks, EXPECTED_CHECKS])
		get_tree().quit(1)
		return
	if not _fails.is_empty():
		print("EDITOR SCENE PROBE: FAIL(%d/%d)" % [_fails.size(), EXPECTED_CHECKS])
		for f in _fails:
			print("  - " + f)
		get_tree().quit(1)
		return
	print("EDITOR SCENE PROBE: ALL-OK(%d 条断言)" % _checks)
	get_tree().quit(0)
