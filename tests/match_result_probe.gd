extends Node

# 结算页的**版式与信号**守卫(必须真渲染;**headless 下取不到像素**,那是留给用户的跑法)。
# 跑法: "$GODOT" --path . --quit-after 3600 res://tests/match_result_probe.tscn
# 判据: 文本 `MATCH RESULT PROBE: ALL-OK`。
#
# ═══ 为什么需要它 ═══
# ★ 版式是"改了不报错"的一类:两节画成一栏、列数不随 columns 变、MVP 高亮落错行、
#   面板不居中,全都不会报错,只会画出一张读不出来的图。所以要**取图 + 节点级断言**两条一起。
# ★ 信号那一条是本页唯一的行为:连点两次按钮若发两次 leave_requested,
#   下游 safe_change_scene 会被调两次 —— 第一次切到主菜单、第二次把刚建出来的主菜单当 old 退役。
# ★ 空载荷不崩是硬要求:结算页崩了玩家卡在对局里出不去。
#
# ═══ ★★ 两条"别改回去"的纪律(2026-09-20 评审后补)═══
# ① **控件必须从 `.tscn` 实例化,不许 `MatchResult.new()`**。`layer = 150` 只住在
#    `ui/match_result.tscn` 里,脚本一个字都不设(与三个 HUD 同款:层位值只有一处来源)。
#    `.new()` 建出来的是 **layer 1** 的 CanvasLayer ⇒ 结算页画在三个 HUD(130)与小地图(131)
#    **底下**,压暗罩盖不住它们。本探针此前正是用 `.new()` —— 那等于在验一条**生产不会走**
#    的路,这一类缺陷它一个都照不到。下面每次构造都过 `_make()`,并断言 `layer == LAYER_WANT`。
# ② **每条断言都要能真的红**。取到 null 就直接解引用/`save_png` 会把协程掐断 ⇒ `_ready()`
#    **一行都不打印**,和"探针真挂住"在输出上**长得一模一样**(本仓明确警告过这种误读)。
#    故:取图先判 `img == null` 并**响亮地记一条 FAIL**,取节点一律先 `_check(x != null)`。

const MATCH_RESULT_SCENE := "res://ui/match_result.tscn"
const LAYER_WANT := 150        # 只住在 .tscn 里;三个 HUD = 130、小地图 = 131、暂停菜单 = 145
const CENTRE_TOL := 2.0        # 面板屏幕矩形中心与视口中心的最大允许偏差(px)
const OUT := "user://match_result_%d.png"

var _fails: Array[String] = []
var _count := 0


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fails.append(msg)


# 唯一的构造入口:从场景实例化(**不是** `.new()`,理由见文件头 ①)。
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
		var s: Node = m.get_node_or_null("Root/Panel/VBox/Sections")
		# ★ 先判 null 再解引用:直接 `get_node_or_null(...).get_child_count()` 在节点缺失时
		#   会掐断 `_shot` 协程 ⇒ "空载荷不崩"这条**硬要求**会以"超时"的形状出现(一行 verdict
		#   都没有),与探针真挂住分不开 —— 而那正是本探针最该说清楚的一件事。
		_check(s != null, "空载荷:找不到 Root/Panel/VBox/Sections(节点路径变了?)")
		if s != null:
			_check(s.get_child_count() == 0, "空载荷应 0 节"))

	# ② 1v1 单节两行：列数 == 2 + columns.size()
	await _shot(MatchResultPayload.for_duel({"scores": {1: 7, 2: 3}, "rounds_won": {1: 2, 2: 1},
			"match_winner": 1}, {1: "阿甲", 2: "bob"}, 1), func(m):
		var g: GridContainer = m.get_node("Root/Panel/VBox/Sections/Section0/Rows")
		_check(g.columns == 3, "1v1 表头列数应为 2+1=3,实得 %d" % g.columns)
		_check(g.get_child_count() == 3 + 2 * 3, "1v1 应有 3 表头 + 2 行×3 格"))

	# ③ 3v3 两节 + MVP 标记恰好一次 + ★ 落在 MVP 行上
	await _shot(MatchResultPayload.for_team({"stats": {
			1: {"kills": 5, "deaths": 3, "dmg": 400, "kscore": 600, "acs": 200},
			4: {"kills": 8, "deaths": 1, "dmg": 900, "kscore": 1200, "acs": 400}},
			"mvp": 4, "match_winner": 2}, {1: "阿甲", 4: "dave"}, {1: 1, 4: 2}, 1), func(m):
		var box: HBoxContainer = m.get_node("Root/Panel/VBox/Sections")
		_check(box.get_child_count() == 2, "3v3 应画 2 节,实得 %d" % box.get_child_count())
		var g: GridContainer = m.get_node("Root/Panel/VBox/Sections/Section1/Rows")
		_check(g.columns == 6, "3v3 表头列数应为 2+4=6,实得 %d" % g.columns)
		_check(_count_marks(m) == 1, "★ MVP 标记应恰好出现 1 次,实得 %d" % _count_marks(m))
		# ★ 只数"★ 出现几次"是**位置盲**的:mvp 行号差一行照样只有 1 个标记 —— 那正是
		#   "MVP 高亮落错行"这一类缺陷的样子。要钉的是**哪一行**:★ 所在的**同一个网格**里,
		#   紧跟在它后面那个格子(昵称列;行的格子顺序 = [名次, 昵称, 数据…])必须正是
		#   `fit_name(mvp 的名字)`。两件一起才说明 ★ 与亮文本落在 **MVP 行**上。
		var hit := _find_mark(box)
		_check(not hit.is_empty(), "★ 应落在某个 Rows 网格的格子里(没找到 ⇒ 下面那条位置断言会空转)")
		if not hit.is_empty():
			var mg: GridContainer = hit[0]
			var mi: int = hit[1]
			var name_lbl: Label = mg.get_child(mi + 1) as Label
			var want := UiFactory.fit_name("dave", MatchResult.NAME_UNITS)
			_check(name_lbl != null and name_lbl.text == want,
					"★ 必须落在 MVP 行(dave)的昵称格:期望「%s」,实得「%s」" % [
							want, "" if name_lbl == null else name_lbl.text]))

	# ④ 连点两次按钮 + ESC -> 只发一次信号
	var mm := _make()
	add_child(mm)
	_check(mm.layer == LAYER_WANT,
			"★ 层位必须由 .tscn 声明(三个 HUD 是 130、小地图 131):期望 %d,实得 %d" % [
					LAYER_WANT, mm.layer])
	mm.show_result({"title": "信号"})
	var fired := [0]
	mm.leave_requested.connect(func() -> void: fired[0] += 1)
	# ★ ESC 那一路此前**没被测过**(下面两条都是直接 `emit_signal("pressed")`):键盘事件走
	#   `_unhandled_input`,与按钮**不同源**,而 `_leaving` 是两者唯一的闸门。所以先驱动 ESC、
	#   断言它**恰好**发一次;随后两次连点必须仍然只有那一次。
	#   ⚠ 顺序不能倒:先连点再驱动 ESC 的话 `_leaving` 早就为真,那条 ESC 断言**恒真**
	#     (与上面"只数标记不看行"是同一类空转断言)。
	var esc := InputEventKey.new()
	esc.pressed = true
	esc.physical_keycode = KEY_ESCAPE
	mm._unhandled_input(esc)
	_check(fired[0] == 1, "★ ESC 应发一次 leave_requested,实得 %d" % fired[0])
	mm.get_node("Root/Panel/VBox/BackButton").emit_signal("pressed")
	mm.get_node("Root/Panel/VBox/BackButton").emit_signal("pressed")
	_check(fired[0] == 1, "★ 连点两次应只发一次 leave_requested,实得 %d" % fired[0])
	mm.queue_free()
	await get_tree().process_frame

	# ⑤ 同一实例**连调两次** `show_result` -> 旧节当场摘掉、名字没被顶成 `@2`、面板不翻倍
	# ★ 这条钉的是 `show_result()` 的**清场纪律**(见 `ui/match_result.gd` 里那段注释):
	#   `queue_free()` 只是标记,旧节本帧仍是子节点 ⇒ 新节的名字被 Godot 自动改成
	#   `Section0@2`,而 `get_combined_minimum_size()` 把**新旧两份一起**量进去 ⇒ 偏移量按
	#   约两倍宽算、布局一旦摆定就不再重算 ⇒ 该实例永久偏宽(全程不报错)。
	# ★ 触发是真实的:3v3 的 `round_state` 会带**第二次** MATCH_OVER 载荷(新 mvp)进来。
	#   `_shot` 每次新建实例,照不到它 —— 所以这条必须**两次都调在同一个实例上**。
	var dup := _make()
	add_child(dup)
	var team_payload := MatchResultPayload.for_team({"stats": {
			1: {"kills": 5, "deaths": 3, "dmg": 400, "kscore": 600, "acs": 200},
			4: {"kills": 8, "deaths": 1, "dmg": 900, "kscore": 1200, "acs": 400}},
			"mvp": 4, "match_winner": 2}, {1: "阿甲", 4: "dave"}, {1: 1, 4: 2}, 1)
	dup.show_result(team_payload)
	await get_tree().process_frame
	dup.show_result(team_payload)          # 第二次 —— 与 3v3 那条重复的 MATCH_OVER 同形
	await get_tree().process_frame          # 让被 queue_free 的旧节真的没掉
	await get_tree().process_frame
	var dsec: Node = dup.get_node_or_null("Root/Panel/VBox/Sections")
	_check(dsec != null, "连调两次后找不到 Root/Panel/VBox/Sections(节点路径变了?)")
	if dsec != null:
		_check(dsec.get_child_count() == 2,
				"连调两次 show_result 后应仍只有 2 节,实得 %d" % dsec.get_child_count())
		# ★ 名字这条才是**判别性**的那条:旧节被 queue_free 之后 `get_child_count()` 会自己
		#   回到 2(所以只数个数照不到),但被顶成 `@2` 的**名字**是不可逆的 ——
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


# 找「带 ★ 的那个 Label」所在网格与其下标;找不到返回空数组。
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


# ★ 版式断言的**位置面**。上面那些断言(包括本节新加的)数的是个数/列数/名字,**位置一个都
#   照不到** —— 而"面板没居中、右半截切在屏幕外"正是那样全绿溜过去的(2026-09-20 取图才发现,
#   3v3 时整块 B 队数据都在屏幕外)。居中量的口径写在 `ui/match_result.gd` 的 `show_result()`
#   里;这里只核**结果**:面板屏幕矩形中心 == 视口中心。
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


func _shot(payload: Dictionary, verify: Callable) -> void:
	var m := _make()
	add_child(m)
	# ★ 每个实例都过这一条:层位只在 .tscn 里,`.new()` 建出来的是 layer 1。
	_check(m.layer == LAYER_WANT,
			"★ 层位必须由 .tscn 声明(三个 HUD 是 130、小地图 131):期望 %d,实得 %d" % [
					LAYER_WANT, m.layer])
	m.show_result(payload)
	await get_tree().process_frame
	await get_tree().process_frame
	verify.call(m)
	_check_centred(m)
	var img := get_viewport().get_texture().get_image()
	# ★ 与 `tests/hue_tint_probe.tscn` 同款,必须**响亮地记一条 FAIL 再退出**:
	#   `--headless` 下这条链给 null,而 `save_png` 在 null 值上会**掐断 `_shot` 协程**
	#   ⇒ `_run` 再也不恢复、`_ready()` 一行 verdict 都不打印 ⇒ 与"探针真挂住"分不开。
	#   本探针的先决条件是真渲染,误加 `--headless` 必须当场说出来,不能装死。
	if img == null:
		_check(false, "截图失败 —— 是不是误加了 --headless?(真渲染是本探针的前提)")
		m.queue_free()
		return
	img.save_png(OUT % _count)
	_count += 1
	m.queue_free()
	await get_tree().process_frame
