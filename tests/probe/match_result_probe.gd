extends Node


const MATCH_RESULT_SCENE := "res://ui/screens/match_result.tscn"
# 面板使用 UiFactory.menu_panel() 构建，内容容器位于 Body 节点下，路径为 Root/Panel/Body/VBox/...
const LAYER_WANT := 150        # 画布层级，HUD 为 130，小地图为 131，暂停菜单为 145
const CENTRE_TOL := 2.0        # 面板中心与视口中心的最大允许偏差(像素)
const OUT := "user://match_result_%d.png"

var _fails: Array[String] = []
var _count := 0


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fails.append(msg)


# 构造入口：从场景实例化以保留层级属性
func _make() -> MatchResult:
	return (load(MATCH_RESULT_SCENE) as PackedScene).instantiate() as MatchResult


func _ready() -> void:
	await _run()
	if _fails.is_empty():
		print("MATCH RESULT PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("MATCH RESULT PROBE: FAIL")
		for f in _fails:
			print("  - %s" % f)
		get_tree().quit(1)


func _run() -> void:
	# 阶段 1：空载荷，不崩溃且只绘制标题
	await _shot({"title": "空"}, func(m):
		var s: Node = m.get_node_or_null("Root/Panel/Body/VBox/Sections")
		_check(s != null, "空载荷: 找不到 Root/Panel/Body/VBox/Sections")
		if s != null:
			_check(s.get_child_count() == 0, "空载荷应为 0 节"))

	# 阶段 2：1v1 对战结果
	await _shot(MatchResultPayload.for_duel({"stats": {
			1: {"kills": 3, "deaths": 4, "assists": 0, "dealt": 100, "taken": 250, "kscore": 300, "acs": 100},
			2: {"kills": 9, "deaths": 1, "assists": 0, "dealt": 450, "taken": 120, "kscore": 900, "acs": 450}},
			"rounds_won": {1: 0, 2: 2}, "mvp": 2, "match_winner": 2},
			{1: "阿甲", 2: "bob"}, 1), func(m):
		var g := m.get_node_or_null("Root/Panel/Body/VBox/Sections/Section0/Rows") as GridContainer
		_check(g != null, "1v1: 找不到 Root/Panel/Body/VBox/Sections/Section0/Rows")
		if g != null:
			_check(g.columns == 2 + 5, "1v1 表头列数应为 2+5=7，实得 %d" % g.columns)
			_check(g.get_child_count() == 7 + 2 * 7, "1v1 应有 7 表头 + 2 行×7 格")
		var secs1: Node = m.get_node_or_null("Root/Panel/Body/VBox/Sections")
		_check(secs1 != null, "1v1: Sections 节点不存在")
		if secs1 != null:
			_check(_count_marks(m) == 1, "1v1 应恰好有 1 个 MVP 标记，实得 %d 个"
					% _count_marks(m))
			var hit1 := _find_mark(secs1)
			_check(not hit1.is_empty(), "1v1: MVP 标记未落在 Rows 网格中")
			if not hit1.is_empty():
				var nm1: Label = (hit1[0] as GridContainer).get_child(int(hit1[1]) + 1) as Label
				var want1 := UiFactory.fit_name("bob", MatchResult.NAME_UNITS)
				_check(nm1 != null and nm1.text == want1,
						"1v1: MVP 标记必须落在 MVP 行(bob)的昵称格: 期望 [%s]，实得 [%s]" % [
								want1, "" if nm1 == null else nm1.text]))

	# 阶段 3：3v3 两节展示，MVP 标记恰好出现一次且对应正确行
	await _shot(MatchResultPayload.for_team({"stats": {
			1: {"kills": 5, "deaths": 3, "assists": 2, "dealt": 400, "taken": 250, "kscore": 600, "acs": 200},
			4: {"kills": 8, "deaths": 1, "assists": 1, "dealt": 900, "taken": 200, "kscore": 1200, "acs": 400},
			5: {"kills": 2, "deaths": 4, "assists": 3, "dealt": 120, "taken": 150, "kscore": 150, "acs": 75}},
			"mvp": 5, "match_winner": 2}, {1: "阿甲", 4: "dave", 5: "eve"}, {1: 1, 4: 2, 5: 2}, 1), func(m):
		var box := m.get_node_or_null("Root/Panel/Body/VBox/Sections") as HBoxContainer
		_check(box != null, "3v3: 找不到 Root/Panel/Body/VBox/Sections")
		if box == null:
			return
		_check(box.get_child_count() == 2, "3v3 应画 2 节，实得 %d" % box.get_child_count())
		var g := m.get_node_or_null("Root/Panel/Body/VBox/Sections/Section1/Rows") as GridContainer
		_check(g != null, "3v3: 找不到 Root/Panel/Body/VBox/Sections/Section1/Rows")
		if g == null:
			return
		_check(g.columns == 2 + 6, "3v3 表头列数应为 2+6=8，实得 %d" % g.columns)
		_check(g.get_child_count() == 8 + 2 * 8, "3v3 第二节应有 8 表头 + 2 行×8 格")
		_check(_count_marks(m) == 1, "3v3 MVP 标记应恰好出现 1 次，实得 %d" % _count_marks(m))
		var hit := _find_mark(box)
		_check(not hit.is_empty(), "3v3: MVP 标记未落在 Rows 网格中")
		if not hit.is_empty():
			var mg: GridContainer = hit[0]
			var mi: int = hit[1]
			var name_lbl: Label = mg.get_child(mi + 1) as Label
			var want := UiFactory.fit_name("eve", MatchResult.NAME_UNITS)
			_check(name_lbl != null and name_lbl.text == want,
					"3v3: 必须落在 MVP 行(eve，第二行)的昵称格: 期望 [%s]，实得 [%s]" % [
							want, "" if name_lbl == null else name_lbl.text]))

	var ma := _make()
	add_child(ma)
	_check(ma.layer == LAYER_WANT,
			"层位必须由场景声明: 期望 %d，实得 %d" % [LAYER_WANT, ma.layer])
	var fa := [0]
	ma.leave_requested.connect(func() -> void: fa[0] += 1)
	var esc := InputEventKey.new()
	esc.pressed = true
	esc.physical_keycode = KEY_ESCAPE
	# 阶段 4a: 未显示时按 ESC 不应触发离开请求
	_check(not ma.visible, "show_result 之前面板必须保持不可见")
	ma._unhandled_input(esc)
	_check(fa[0] == 0, "不可见时 ESC 不得发送 leave_requested，实得 %d" % fa[0])
	# 阶段 4b: 显示后按 ESC 触发一次离开请求，重复按键不应重复发送
	ma.show_result({"title": "信号"})
	ma._unhandled_input(esc)
	_check(fa[0] == 1, "ESC 应发送一次 leave_requested，实得 %d" % fa[0])
	var after_first: int = fa[0]
	ma._unhandled_input(esc)
	_check(fa[0] == after_first,
			"第二次 ESC 不得重复发送: 首次后 %d，二次后 %d" % [after_first, fa[0]])
	ma.queue_free()
	await get_tree().process_frame

	# 阶段 4c: 按钮点击逻辑，防连击保护
	var mb := _make()
	add_child(mb)
	_check(mb.layer == LAYER_WANT,
			"层位必须由场景声明: 期望 %d，实得 %d" % [LAYER_WANT, mb.layer])
	mb.show_result({"title": "信号"})
	var fb := [0]
	mb.leave_requested.connect(func() -> void: fb[0] += 1)
	var bb := mb.get_node_or_null("Root/Panel/Body/VBox/BackButton") as Button
	_check(bb != null, "找不到返回按钮: Root/Panel/Body/VBox/BackButton")
	if bb != null:
		bb.emit_signal("pressed")
		bb.emit_signal("pressed")
	_check(fb[0] == 1, "连点两次按钮应只发送一次 leave_requested，实得 %d" % fb[0])
	mb.queue_free()
	await get_tree().process_frame

	var dup := _make()
	add_child(dup)
	var team_payload := MatchResultPayload.for_team({"stats": {
			1: {"kills": 5, "deaths": 3, "dealt": 400, "kscore": 600, "acs": 200},
			4: {"kills": 8, "deaths": 1, "dealt": 900, "kscore": 1200, "acs": 400}},
			"mvp": 4, "match_winner": 2}, {1: "阿甲", 4: "dave"}, {1: 1, 4: 2}, 1)
	dup.show_result(team_payload)
	await get_tree().process_frame
	dup.show_result(team_payload)          # 重复调用测试幂等性
	await get_tree().process_frame
	await get_tree().process_frame
	var dsec: Node = dup.get_node_or_null("Root/Panel/Body/VBox/Sections")
	_check(dsec != null, "连调两次后找不到 Root/Panel/Body/VBox/Sections")
	if dsec != null:
		_check(dsec.get_child_count() == 2,
				"连调两次 show_result 后应仍只有 2 节，实得 %d" % dsec.get_child_count())
		_check(dsec.get_node_or_null("Section0") != null,
				"连调两次后 Section0 节点应存在")
		_check(dsec.get_node_or_null("Section1") != null,
				"连调两次后 Section1 节点应存在")
	var dp: Control = dup.get_node_or_null("Root/Panel") as Control
	_check(dp != null, "连调两次后找不到 Root/Panel")
	if dp != null:
		_check(absf(dp.size.x - dp.get_combined_minimum_size().x) <= CENTRE_TOL,
				"连调两次后面板宽度应等于内容最小宽: 实际 %.1f，最小 %.1f" % [
						dp.size.x, dp.get_combined_minimum_size().x])
	dup.queue_free()
	await get_tree().process_frame

func _find_mark(sections: Node) -> Array:
	for box in sections.get_children():
		var g: GridContainer = box.get_node_or_null("Rows") as GridContainer
		if g == null:
			continue
		for i in g.get_child_count():
			var l: Label = g.get_child(i) as Label
			if l != null and l.text.begins_with(MatchResult.MVP_MARK):
				return [g, i]
	return []


func _count_marks(n: Node) -> int:
	var c := 0
	if n is Label and (n as Label).text.begins_with(MatchResult.MVP_MARK):
		c += 1
	for ch in n.get_children():
		c += _count_marks(ch)
	return c


func _check_centred(m: MatchResult) -> void:
	var p: Control = m.get_node_or_null("Root/Panel") as Control
	_check(p != null, "找不到 Root/Panel(居中无从断言)")
	if p == null:
		return
	var got := p.get_global_rect().get_center()
	var want := get_viewport().get_visible_rect().size * 0.5
	_check(absf(got.x - want.x) <= CENTRE_TOL and absf(got.y - want.y) <= CENTRE_TOL,
			"面板必须居中: 期望中心 (%.1f, %.1f)，实得 (%.1f, %.1f)" % [
					want.x, want.y, got.x, got.y])
	var vp := get_viewport().get_visible_rect()
	var prect := p.get_global_rect()
	_check(prect.size.x <= vp.size.x and prect.size.y <= vp.size.y,
			"面板尺寸必须适配视口: 面板 %.1f×%.1f，视口 %.1f×%.1f" % [
					prect.size.x, prect.size.y, vp.size.x, vp.size.y])


func _shot(payload: Dictionary, verify: Callable) -> void:
	var m := _make()
	add_child(m)
	_check(m.layer == LAYER_WANT,
			"层位必须由场景声明: 期望 %d，实得 %d" % [LAYER_WANT, m.layer])
	m.show_result(payload)
	await get_tree().process_frame
	await get_tree().process_frame
	verify.call(m)
	_check_centred(m)
	var img := get_viewport().get_texture().get_image()
	if img == null:
		_check(false, "截图失败(无头渲染环境下视口未激活)")
		m.queue_free()
		return
	img.save_png(OUT % _count)
	_count += 1
	m.queue_free()
	await get_tree().process_frame
