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
# ② **每条断言都要能真的红**。取到 null 就直接解引用/`save_png` 会在出错那一行**中止所在函数**。
#    ★ 2026-09-21 实测定案(本文件**只教这一个模型**,先前的"掐断协程、一行 verdict 都没有"
#    是过期说法,已按实测改写):`get_node` 取不到节点 / 在 null 上调用方法时,引擎**只** `ERROR`
#    一行,然后**出错的那个函数当场结束、调用方继续**。三层实测:
#      · 出错在 **lambda**(`_shot` 的 `verify`)→ lambda 结束,`_shot` 在 `verify.call(m)`
#        之后照常往下走;
#      · 出错在 **`_shot` 自己**(即下面 `save_png` 那个形状)→ `_shot` 结束,`_run` 继续;
#      · 出错在 **`_run` 里** → `_run` 结束,`_ready()` 的 `await _run()` 照常恢复。
#    三层**都**打印 **ALL-OK** ⇒ **假绿**(读者把那行当"后面那些都过了")。唯一"一行都不打印"
#    的形状是出错在 `_ready()` **自己身上**(那时连 verdict 都到不了,只能靠 `--quit-after` 收尾
#    —— 而它照样 exit 0,与"跑通了"在退出码上不可分)。
#    故:取图先判 `img == null` 并**响亮地记一条 FAIL**,取节点一律先 `_check(x != null)`。
#    (下面三处取节点都按这条改过,失败形态记在各自注释里。)

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
		# ★ 先判 null 再解引用(模型见文件头 ②)。直接 `get_node_or_null(...).get_child_count()`
		#   在节点缺失时**只结束这个 lambda**,而 `_shot` 在 `verify.call(m)` 之后**照常往下走**、
		#   `_run`/`_ready` 也照常恢复 ⇒ "空载荷不崩"这条**硬要求**被**静默跳过**,verdict 仍是
		#   **ALL-OK**(2026-09-21 实测:这一层不是"掐断 `_shot`、一行 verdict 都没有"—— 那是
		#   本文件原先的旧说法,已在文件头 ② 更正)。
		_check(s != null, "空载荷:找不到 Root/Panel/VBox/Sections(节点路径变了?)")
		if s != null:
			_check(s.get_child_count() == 0, "空载荷应 0 节"))

	# ② 1v1 单节两行：列数 == 2 + columns.size()
	# ★ 夹具与 `-s` 冒烟的 ① 同款(行数据走 `stats`;`scores` 已经不是本页的数据面)。
	await _shot(MatchResultPayload.for_duel({"stats": {
			1: {"kills": 7, "deaths": 2, "assists": 0, "dealt": 500, "taken": 200, "kscore": 800, "acs": 400},
			2: {"kills": 3, "deaths": 5, "assists": 0, "dealt": 300, "taken": 400, "kscore": 250, "acs": 125}},
			"rounds_won": {1: 2, 2: 1}, "mvp": 1, "match_winner": 1},
			{1: "阿甲", 2: "bob"}, 1), func(m):
		# ★ 先判 null 再解引用(文件头 ②)。**实测的失败形态**(2026-09-21,把 `Rows` 改名):
		#   直接 `get_node(...)` 取不到节点 ⇒ 引擎只 `ERROR` 一行,而**出错的那个函数当场结束、
		#   调用方继续** —— 于是这个 lambda 里**剩下的断言被静默跳过**,`_shot`/`_run` 照常往下走。
		#   若没有别处恰好也撞到同一个改名(那次碰巧是 ③ 替它报了红),verdict 就是 **ALL-OK**:
		#   一条**假绿**(读者会以为这两条都过了),比"探针挂住"危险得多。
		var g := m.get_node_or_null("Root/Panel/VBox/Sections/Section0/Rows") as GridContainer
		_check(g != null, "1v1:找不到 Root/Panel/VBox/Sections/Section0/Rows(节点路径变了?)")
		if g != null:
			_check(g.columns == 2 + 5, "1v1 表头列数应为 2+5=7,实得 %d" % g.columns)
			_check(g.get_child_count() == 7 + 2 * 7, "1v1 应有 7 表头 + 2 行×7 格"))

	# ③ 3v3 两节 + MVP 标记恰好一次 + ★ 落在 MVP 行上
	# ★ MVP 故意落在**第二节的第二个行**:每节只有一行时 `mvp.row == 0` 是**唯一可表示**的值,
	#   行号算错一行也照样绿 —— 那正是"MVP 高亮落错行"这一类缺陷的样子。第二节两行,行号才真的
	#   有得错(下面那条 ★ 位置断言按昵称格判,`mvp` 指向第 2 行的 `eve`、不是第 1 行的 `dave`)。
	# ★★ 本发是**唯一被人眼读的那张图**(`user://match_result_2.png`),而它正是六列宽度的守卫
	#   (`_check_centred` 的"面板必须装得下视口")。故六个字段**都给真值** —— 夹具里少给
	#   `assists`/`taken` 时那两列会**整列 0**,图上看着正常,却验不出"列与数据的对位"
	#   (两列互换、或写死在别的字段上都照样是全 0)。`acs` 保持 200/400/75:它决定栏内排序,
	#   而上面那条 ★ 位置断言依赖"eve 排在 dave **之后**"。
	await _shot(MatchResultPayload.for_team({"stats": {
			1: {"kills": 5, "deaths": 3, "assists": 2, "dealt": 400, "taken": 250, "kscore": 600, "acs": 200},
			4: {"kills": 8, "deaths": 1, "assists": 1, "dealt": 900, "taken": 200, "kscore": 1200, "acs": 400},
			5: {"kills": 2, "deaths": 4, "assists": 3, "dealt": 120, "taken": 150, "kscore": 150, "acs": 75}},
			"mvp": 5, "match_winner": 2}, {1: "阿甲", 4: "dave", 5: "eve"}, {1: 1, 4: 2, 5: 2}, 1), func(m):
		# ★ 先判 null 再解引用(文件头 ②;失败形态的实测记录见上一条 —— 另两处 lambda 同款)。
		var box := m.get_node_or_null("Root/Panel/VBox/Sections") as HBoxContainer
		_check(box != null, "3v3:找不到 Root/Panel/VBox/Sections(节点路径变了?)")
		if box == null:
			return
		_check(box.get_child_count() == 2, "3v3 应画 2 节,实得 %d" % box.get_child_count())
		var g := m.get_node_or_null("Root/Panel/VBox/Sections/Section1/Rows") as GridContainer
		_check(g != null, "3v3:找不到 Root/Panel/VBox/Sections/Section1/Rows(节点路径变了?)")
		if g == null:
			return
		_check(g.columns == 2 + 6, "3v3 表头列数应为 2+6=8,实得 %d" % g.columns)
		_check(g.get_child_count() == 8 + 2 * 8, "3v3 第二节应有 8 表头 + 2 行×8 格")
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
			var want := UiFactory.fit_name("eve", MatchResult.NAME_UNITS)
			_check(name_lbl != null and name_lbl.text == want,
					"★ 必须落在 MVP 行(eve,第二行)的昵称格:期望「%s」,实得「%s」" % [
							want, "" if name_lbl == null else name_lbl.text]))

	# ④a 可见性闸门 + ④b ESC 那一路(实例 A;下面 ④c 的按钮那一路用**另一个新实例**)
	# ★★ **两条路各用各的实例** —— 这是本探针最要紧的一处修法。此前两者共用一个实例、且 ESC 先驱动:
	#    ESC 一发就把 `_leaving` 闩上,后面两次 `emit_signal("pressed")` **物理上发不出信号**
	#    ⇒ 删掉 `back.pressed.connect(_request_leave)` 整条探针照样全绿 —— 而"返回主菜单按钮点了
	#    没反应"正是本页最该拦住的缺陷(结算页坏了 = 玩家卡在对局里出不去)。
	#    分开实例之后两条断言各自**非空转**:删连接 ⇒ ④c 红;删 `_unhandled_input` 的 ESC 分支 ⇒ ④b 红。
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
	# ★ ④a **可见性闸门**:`_unhandled_input` 首行是 `if not visible: return`,而控件在
	#   `show_result()` 之前一直隐藏(`_ready()` 末尾那句 `visible = false`)——
	#   没有这条,闸门被删掉也不会有任何断言变红(露出一块空面板的窗口里按 ESC 会提前换场)。
	_check(not ma.visible, "★ `show_result()` 之前必须不可见(否则会先露出一块空面板 + 按钮)")
	ma._unhandled_input(esc)
	_check(fa[0] == 0, "★ 不可见时 ESC 不得发 leave_requested(闸门被删了?),实得 %d" % fa[0])
	# ④b 可见之后 ESC **恰好**发一次,再按第二下**仍是**一次(`_leaving` 闩)。
	ma.show_result({"title": "信号"})
	ma._unhandled_input(esc)
	_check(fa[0] == 1, "★ ESC 应发一次 leave_requested,实得 %d" % fa[0])
	# ★ 第二下判的是**增量**,不是累计值。判累计值(`fa[0] == 1`)时,任何把 ESC 那一路
	#   整个弄坏的改动(计数恒 0)**同时**让上一条与这一条变红 ⇒ 多一条纯噪声的失败行,
	#   把真正的成因埋掉。取"首次 ESC 之后"的读数为基线,两条断言各管各的。
	#   ⚠ 判据仍是**严格相等**(不是 `<= 1`):`<= 1` 在"第二下重发"时是 `2 <= 1` = 假,
	#   看着还能红,但它同时放过了任何"计数倒退/被清零"的实现 —— 那正是这里要防的。
	var after_first: int = fa[0]
	ma._unhandled_input(esc)
	_check(fa[0] == after_first,
			"★ 第二次 ESC 不得再发(见 `_leaving`):首次之后 %d,第二次之后 %d" % [after_first, fa[0]])
	ma.queue_free()
	await get_tree().process_frame

	# ④c 按钮那一路(**新实例**:上一个实例的 `_leaving` 已被 ESC 闩上,共用会让这条恒真)
	var mb := _make()
	add_child(mb)
	_check(mb.layer == LAYER_WANT,
			"★ 层位必须由 .tscn 声明(三个 HUD 是 130、小地图 131):期望 %d,实得 %d" % [
					LAYER_WANT, mb.layer])
	mb.show_result({"title": "信号"})
	var fb := [0]
	mb.leave_requested.connect(func() -> void: fb[0] += 1)
	# ★ 先判 null 再解引用(文件头 ②)。这里与上面两处**形态不同**:它直接在 `_run` 里
	#   (不经过 lambda),出错会**结束 `_run` 本身** —— ④c 自己的断言与**整段 ⑤** 一起被跳过,
	#   而 `_ready` 的 `await _run()` 照常恢复、打印的却是 **ALL-OK**(2026-09-21 实测:把
	#   `BackButton` 改名即复现,输出里只有一行 `ERROR: Node not found` + `ALL-OK`)。
	#   那是**假绿**,比文件头 ② 预言的"一行都不打印"更坏:读者会把那行 ALL-OK 当成"④c 与 ⑤ 都过了"。
	var bb := mb.get_node_or_null("Root/Panel/VBox/BackButton") as Button
	_check(bb != null, "④c:找不到 Root/Panel/VBox/BackButton(节点路径变了?)")
	if bb != null:
		bb.emit_signal("pressed")
		bb.emit_signal("pressed")
	_check(fb[0] == 1, "★ 连点两次按钮应只发一次 leave_requested,实得 %d" % fb[0])
	mb.queue_free()
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
			1: {"kills": 5, "deaths": 3, "dealt": 400, "kscore": 600, "acs": 200},
			4: {"kills": 8, "deaths": 1, "dealt": 900, "kscore": 1200, "acs": 400}},
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

	# ★ 这里此前还有一条「三个客户端必须从 `.tscn` 实例化」的源码扫描(⑥)。已**整段搬走**:
	#   它的挂载点在**基类** `scenes/pvp_match_client.gd`(三个客户端全部 extends 它),而它
	#   守的却是一份**手写**的三个子类清单;且裸 `contains` 对注释是盲的(基类里那句注释原文
	#   就写着 `MatchResult.new()`)。现在住在 `tests/hud_declarative_probe.gd` 的
	#   `_check_result_scene_instantiation()`(走盘 + 剥注释,理由写在那里)。
	#   ⚠ 别在这儿"补回来":本文件是需要**真渲染**的窗口探针,只在有人开窗口时才跑。


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
	# ★ **装得下**这条与居中是一体两面:面板比视口宽时,居中会让它**对称地**裁掉左右两边 ——
	#   那就是本断言存在的理由(3v3 时 B 队四列整列在屏幕外)的**镜像**:居中照样成立、图照样
	#   读不出来,只判中心就全绿放过去了。
	var vp := get_viewport().get_visible_rect()
	var prect := p.get_global_rect()
	_check(prect.size.x <= vp.size.x and prect.size.y <= vp.size.y,
			"★ 面板必须装得下视口(比视口大 = 对称裁掉两边,与『没居中』同类的镜像缺陷):面板 %.1f×%.1f,视口 %.1f×%.1f" % [
					prect.size.x, prect.size.y, vp.size.x, vp.size.y])


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
	#   `--headless` 下这条链给 null,而 `save_png` 在 null 值上**只结束 `_shot` 本身**
	#   (模型见文件头 ②)—— `_shot` 的调用方 `_run`、以及 `_run` 的调用方 `_ready()`
	#   **全部照常恢复** ⇒ verdict 仍打 **ALL-OK**,整段 ①~⑤ **一条都没验**却看着全绿。
	#   ★ 本文件原先写的是"掐断 `_shot` 协程 ⇒ `_run` 再也不恢复、一行 verdict 都不打印":
	#   2026-09-21 实测**推翻**(见文件头 ②)—— 那个说法只在出错于 `_ready()` **自己身上**
	#   时才成立,而这里是 `_shot`。本探针的先决条件是真渲染,误加 `--headless` 必须当场
	#   说出来,不能装死。
	if img == null:
		_check(false, "截图失败 —— 是不是误加了 --headless?(真渲染是本探针的前提)")
		m.queue_free()
		return
	img.save_png(OUT % _count)
	_count += 1
	m.queue_free()
	await get_tree().process_frame
