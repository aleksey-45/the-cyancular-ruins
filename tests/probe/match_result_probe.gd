extends Node


const MATCH_RESULT_SCENE := "res://ui/screens/match_result.tscn"
# - 面板改走 `UiFactory.menu_panel()` 后,内容容器在多出来的一层 `Body` 里  ->
#   本文件里所有取节点的路径都是 `Root/Panel/Body/VBox/...`(改版前没有 `Body` 那一层)。
#   `Root/Panel`(居中量它)与 `Section{N}/Rows` 这两段的形状没变。
const LAYER_WANT := 150        # 只住在 .tscn 里;三个 HUD = 130、小地图 = 131、暂停菜单 = 145
const CENTRE_TOL := 2.0        # 面板屏幕矩形中心与视口中心的最大允许偏差(px)
const OUT := "user://match_result_%d.png"

var _fails: Array[String] = []
var _count := 0


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fails.append(msg)


# 唯一的构造入口:从场景实例化(不是 `.new()`,理由见文件头 ①)。
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
	# ① 空载荷:不崩，且只画标题
	await _shot({"title": "空"}, func(m):
		var s: Node = m.get_node_or_null("Root/Panel/Body/VBox/Sections")
		_check(s != null, "空载荷:找不到 Root/Panel/Body/VBox/Sections(节点路径变了?)")
		if s != null:
			_check(s.get_child_count() == 0, "空载荷应 0 节"))

	await _shot(MatchResultPayload.for_duel({"stats": {
			1: {"kills": 3, "deaths": 4, "assists": 0, "dealt": 100, "taken": 250, "kscore": 300, "acs": 100},
			2: {"kills": 9, "deaths": 1, "assists": 0, "dealt": 450, "taken": 120, "kscore": 900, "acs": 450}},
			"rounds_won": {1: 0, 2: 2}, "mvp": 2, "match_winner": 2},
			{1: "阿甲", 2: "bob"}, 1), func(m):
		var g := m.get_node_or_null("Root/Panel/Body/VBox/Sections/Section0/Rows") as GridContainer
		_check(g != null, "1v1:找不到 Root/Panel/Body/VBox/Sections/Section0/Rows(节点路径变了?)")
		if g != null:
			_check(g.columns == 2 + 5, "1v1 表头列数应为 2+5=7,实得 %d" % g.columns)
			_check(g.get_child_count() == 7 + 2 * 7, "1v1 应有 7 表头 + 2 行×7 格")
		var secs1: Node = m.get_node_or_null("Root/Panel/Body/VBox/Sections")
		_check(secs1 != null, "1v1:Sections 取不到(MVP 星标断言无从成立)")
		if secs1 != null:
			_check(_count_marks(m) == 1, "★ 1v1 也必须有 MVP 星标(恰好 1 个),实得 %d 个"
					% _count_marks(m))
			var hit1 := _find_mark(secs1)
			_check(not hit1.is_empty(), "1v1:★ 应落在某个 Rows 网格的格子里(没找到 ⇒ 下面那条位置断言会空转)")
			if not hit1.is_empty():
				var nm1: Label = (hit1[0] as GridContainer).get_child(int(hit1[1]) + 1) as Label
				var want1 := UiFactory.fit_name("bob", MatchResult.NAME_UNITS)
				_check(nm1 != null and nm1.text == want1,
						"★ 1v1:★ 必须落在 MVP 行(bob —— 9 杀排到第 1 行)的昵称格:期望「%s」,实得「%s」" % [
								want1, "" if nm1 == null else nm1.text]))

	# ③ 3v3 两节 + MVP 标记恰好一次 + -  落在 MVP 行上
	# - MVP 故意落在第二节的第二个行:每节只有一行时 `mvp.row == 0` 是唯一可表示的值,
	#   行号算错一行也照样绿 —— 那正是"MVP 高亮落错行"这一类缺陷的样子。第二节两行,行号才真的
	#   有得错(下面那条 -  位置断言按昵称格判,`mvp` 指向第 2 行的 `eve`、不是第 1 行的 `dave`)。
	# 注意事项：本发是唯一被人眼读的那张图(`user://match_result_2.png`),而它正是六列宽度的防御性校验
	#   (`_check_centred` 的"面板必须装得下视口")。故六个字段都给真值 —— 夹具里少给
	#   `assists`/`taken` 时那两列会整列 0,图上看着正常,却验不出"列与数据的对位"
	#   (两列互换、或写死在别的字段上都照样是全 0)。`acs` 保持 200/400/75:它决定栏内排序,
	#   而上面那条 -  位置断言依赖"eve 排在 dave 之后"。
	await _shot(MatchResultPayload.for_team({"stats": {
			1: {"kills": 5, "deaths": 3, "assists": 2, "dealt": 400, "taken": 250, "kscore": 600, "acs": 200},
			4: {"kills": 8, "deaths": 1, "assists": 1, "dealt": 900, "taken": 200, "kscore": 1200, "acs": 400},
			5: {"kills": 2, "deaths": 4, "assists": 3, "dealt": 120, "taken": 150, "kscore": 150, "acs": 75}},
			"mvp": 5, "match_winner": 2}, {1: "阿甲", 4: "dave", 5: "eve"}, {1: 1, 4: 2, 5: 2}, 1), func(m):
		# - 先判 null 再解引用(文件头 ②;失败形态的实测记录见上一条 —— 另两处 lambda 相同处理逻辑)。
		var box := m.get_node_or_null("Root/Panel/Body/VBox/Sections") as HBoxContainer
		_check(box != null, "3v3:找不到 Root/Panel/Body/VBox/Sections(节点路径变了?)")
		if box == null:
			return
		_check(box.get_child_count() == 2, "3v3 应画 2 节,实得 %d" % box.get_child_count())
		var g := m.get_node_or_null("Root/Panel/Body/VBox/Sections/Section1/Rows") as GridContainer
		_check(g != null, "3v3:找不到 Root/Panel/Body/VBox/Sections/Section1/Rows(节点路径变了?)")
		if g == null:
			return
		_check(g.columns == 2 + 6, "3v3 表头列数应为 2+6=8,实得 %d" % g.columns)
		_check(g.get_child_count() == 8 + 2 * 8, "3v3 第二节应有 8 表头 + 2 行×8 格")
		_check(_count_marks(m) == 1, "★ MVP 标记应恰好出现 1 次,实得 %d" % _count_marks(m))
		# - 只数"-  出现几次"是位置盲的:mvp 行号差一行照样只有 1 个标记 —— 那正是
		#   "MVP 高亮落错行"这一类缺陷的样子。要约束的是哪一行:-  所在的同一个网格里,
		#   紧跟在它后面那个格子(昵称列;行的格子顺序 = [名次, 昵称, 数据…])必须正是
		#   `fit_name(mvp 的名字)`。两件一起才说明 -  与亮文本落在 MVP 行上。
		var hit := _find_mark(box)
		_check(not hit.is_empty(), "★ 应落在某个 Rows 网格的格子里(没找到 ⇒ 下面那条位置断言会空转)")
		if not hit.is_empty():
			var mg: GridContainer = hit[0]
			var mi: int = hit[1]
			var name_lbl: Label = mg.get_child(mi + 1) as Label
			var want := UiFactory.fit_name("eve", MatchResult.NAME_UNITS)
			_check(name_lbl != null and name_lbl.text == want,
					"★ 必须落在 MVP 行(eve,第二行)的昵称格:期望「%s」,实得「%s」" % [
							want, "" if name_lbl == null else name_lbl.text]))

	var ma := _make()
	add_child(ma)
	_check(ma.layer == LAYER_WANT,
			"★ 层位必须由 .tscn 声明(三个 HUD 是 130、小地图 131):期望 %d,实得 %d" % [
					LAYER_WANT, ma.layer])
	var fa := [0]
	ma.leave_requested.connect(func() -> void: fa[0] += 1)
	var esc := InputEventKey.new()
	esc.pressed = true
	esc.physical_keycode = KEY_ESCAPE
	# - ④a 可见性门控前置校验:`_unhandled_input` 首行是 `if not visible: return`,而控件在
	#   `show_result()` 之前一直隐藏(`_ready()` 末尾那句 `visible = false`)——
	#   没有这条,门控前置校验被删掉也不会有任何断言变红(露出一块空面板的窗口里按 ESC 会提前换场)。
	_check(not ma.visible, "★ `show_result()` 之前必须不可见(否则会先露出一块空面板 + 按钮)")
	ma._unhandled_input(esc)
	_check(fa[0] == 0, "★ 不可见时 ESC 不得发 leave_requested(闸门被删了?),实得 %d" % fa[0])
	# ④b 可见之后 ESC 恰好发一次,再按第二下仍是一次(`_leaving` 闩)。
	ma.show_result({"title": "信号"})
	ma._unhandled_input(esc)
	_check(fa[0] == 1, "★ ESC 应发一次 leave_requested,实得 %d" % fa[0])
	# - 第二下判的是增量,不是累计值。判累计值(`fa[0] == 1`)时,任何把 ESC 那一路
	#   整个破坏的改动(计数恒 0)同时让上一条与这一条变红  ->  多一条纯噪声的失败行,
	#   把真正的成因埋掉。取"首次 ESC 之后"的读数为基线,两条断言各管各的。
	#   - 判定条件仍是严格相等(不是 `<= 1`):`<= 1` 在"第二下重发"时是 `2 <= 1` = 假,
	#   看着还能红,但它同时放过了任何"计数倒退/被清零"的实现 —— 那正是这里要防的。
	var after_first: int = fa[0]
	ma._unhandled_input(esc)
	_check(fa[0] == after_first,
			"★ 第二次 ESC 不得再发(见 `_leaving`):首次之后 %d,第二次之后 %d" % [after_first, fa[0]])
	ma.queue_free()
	await get_tree().process_frame

	# ④c 按钮那一路(新实例:上一个实例的 `_leaving` 已被 ESC 闩上,共用会让这条始终为 true)
	var mb := _make()
	add_child(mb)
	_check(mb.layer == LAYER_WANT,
			"★ 层位必须由 .tscn 声明(三个 HUD 是 130、小地图 131):期望 %d,实得 %d" % [
					LAYER_WANT, mb.layer])
	mb.show_result({"title": "信号"})
	var fb := [0]
	mb.leave_requested.connect(func() -> void: fb[0] += 1)
	var bb := mb.get_node_or_null("Root/Panel/Body/VBox/BackButton") as Button
	_check(bb != null, "④c:找不到 Root/Panel/Body/VBox/BackButton(节点路径变了?)")
	if bb != null:
		bb.emit_signal("pressed")
		bb.emit_signal("pressed")
	_check(fb[0] == 1, "★ 连点两次按钮应只发一次 leave_requested,实得 %d" % fb[0])
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
	dup.show_result(team_payload)          # 第二次 —— 与 3v3 那条重复的 MATCH_OVER 同形
	await get_tree().process_frame          # 让被 queue_free 的旧节真的没掉
	await get_tree().process_frame
	var dsec: Node = dup.get_node_or_null("Root/Panel/Body/VBox/Sections")
	_check(dsec != null, "连调两次后找不到 Root/Panel/Body/VBox/Sections(节点路径变了?)")
	if dsec != null:
		_check(dsec.get_child_count() == 2,
				"连调两次 show_result 后应仍只有 2 节,实得 %d" % dsec.get_child_count())
		# - 名字这条才是判别性的那条:旧节被 queue_free 之后 `get_child_count()` 会自己
		#   回到 2(所以只数个数无法覆盖检测),但被顶成 `@2` 的名字是不可逆的 ——
		#   此后 `get_node(".../Section0")` 恒 null。
		_check(dsec.get_node_or_null("Section0") != null,
				"连调两次后 `Section0` 这个名字必须还在(变成 `Section0@2` = 清场时漏了 remove_child)")
		_check(dsec.get_node_or_null("Section1") != null,
				"连调两次后 `Section1` 这个名字必须还在(变成 `Section1@2` = 清场时漏了 remove_child)")
	var dp: Control = dup.get_node_or_null("Root/Panel") as Control
	_check(dp != null, "连调两次后找不到 Root/Panel(节点路径变了?)")
	if dp != null:
		# 面板实收宽度必须等于内容最小宽。偏移量若按"两份"算,布局会把 size 撑在那里不动
		# (Godot 只保证 size ≥ 最小宽,不会把它缩回来)。
		_check(absf(dp.size.x - dp.get_combined_minimum_size().x) <= CENTRE_TOL,
				"连调两次后面板宽度必须等于内容最小宽(按两份算 = 永久偏宽):实收 %.1f,最小 %.1f" % [
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
			"★ 面板必须居中:期望中心 (%.1f, %.1f),实得 (%.1f, %.1f)" % [
					want.x, want.y, got.x, got.y])
	# - 装得下这条与居中是一体两面:面板比视口宽时,居中会让它对称地裁掉左右两边 ——
	#   那就是本断言存在的理由(3v3 时 B 队四列整列在屏幕外)的镜像:居中照样成立、图照样
	#   读不出来,只判中心就全部断言通过放过去了。
	var vp := get_viewport().get_visible_rect()
	var prect := p.get_global_rect()
	_check(prect.size.x <= vp.size.x and prect.size.y <= vp.size.y,
			"★ 面板必须装得下视口(比视口大 = 对称裁掉两边,与『没居中』同类的镜像缺陷):面板 %.1f×%.1f,视口 %.1f×%.1f" % [
					prect.size.x, prect.size.y, vp.size.x, vp.size.y])


func _shot(payload: Dictionary, verify: Callable) -> void:
	var m := _make()
	add_child(m)
	# - 每个实例都过这一条:层位只在 .tscn 里,`.new()` 建出来的是 layer 1。
	_check(m.layer == LAYER_WANT,
			"★ 层位必须由 .tscn 声明(三个 HUD 是 130、小地图 131):期望 %d,实得 %d" % [
					LAYER_WANT, m.layer])
	m.show_result(payload)
	await get_tree().process_frame
	await get_tree().process_frame
	verify.call(m)
	_check_centred(m)
	var img := get_viewport().get_texture().get_image()
	if img == null:
		_check(false, "截图失败 —— 是不是误加了 --headless?(真渲染是本探针的前提)")
		m.queue_free()
		return
	img.save_png(OUT % _count)
	_count += 1
	m.queue_free()
	await get_tree().process_frame
