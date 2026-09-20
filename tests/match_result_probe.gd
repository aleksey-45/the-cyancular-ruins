extends Node

# 结算页的**版式与信号**守卫(必须真渲染;**headless 下取不到像素**,那是留给用户的跑法)。
# 跑法: "$GODOT" --path . --quit-after 3600 res://tests/match_result_probe.tscn
# 判据: 文本 `MATCH RESULT PROBE: ALL-OK`。
#
# ═══ 为什么需要它 ═══
# ★ 版式是"改了不报错"的一类:两节画成一栏、列数不随 columns 变、MVP 高亮落错行,
#   全都不会报错,只会画出一张读不出来的图。所以要**取图 + 节点级断言**两条一起。
# ★ 信号那一条是本页唯一的行为:连点两次按钮若发两次 leave_requested,
#   下游 safe_change_scene 会被调两次 —— 第一次切到主菜单、第二次把刚建出来的主菜单当 old 退役。
# ★ 空载荷不崩是硬要求:结算页崩了玩家卡在对局里出不去。

const OUT := "user://match_result_%d.png"

var _fails: Array[String] = []
var _count := 0


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fails.append(msg)


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
	await _shot({"title": "空"}, func(m): _check(
			m.get_node_or_null("Root/Panel/VBox/Sections").get_child_count() == 0,
			"空载荷应 0 节"))

	# ② 1v1 单节两行：列数 == 2 + columns.size()
	await _shot(MatchResultPayload.for_duel({"scores": {1: 7, 2: 3}, "rounds_won": {1: 2, 2: 1},
			"match_winner": 1}, {1: "阿甲", 2: "bob"}, 1), func(m):
		var g: GridContainer = m.get_node("Root/Panel/VBox/Sections/Section0/Rows")
		_check(g.columns == 3, "1v1 表头列数应为 2+1=3,实得 %d" % g.columns)
		_check(g.get_child_count() == 3 + 2 * 3, "1v1 应有 3 表头 + 2 行×3 格"))

	# ③ 3v3 两节 + MVP 标记恰好一次
	await _shot(MatchResultPayload.for_team({"stats": {
			1: {"kills": 5, "deaths": 3, "dmg": 400, "kscore": 600, "acs": 200},
			4: {"kills": 8, "deaths": 1, "dmg": 900, "kscore": 1200, "acs": 400}},
			"mvp": 4, "match_winner": 2}, {1: "阿甲", 4: "dave"}, {1: 1, 4: 2}, 1), func(m):
		var box: HBoxContainer = m.get_node("Root/Panel/VBox/Sections")
		_check(box.get_child_count() == 2, "3v3 应画 2 节,实得 %d" % box.get_child_count())
		var g: GridContainer = m.get_node("Root/Panel/VBox/Sections/Section1/Rows")
		_check(g.columns == 6, "3v3 表头列数应为 2+4=6,实得 %d" % g.columns)
		_check(_count_marks(m) == 1, "★ MVP 标记应恰好出现 1 次,实得 %d" % _count_marks(m)))

	# ④ 连点两次按钮 -> 只发一次信号
	var mm := MatchResult.new()
	add_child(mm)
	mm.show_result({"title": "信号"})
	var fired := [0]
	mm.leave_requested.connect(func() -> void: fired[0] += 1)
	mm.get_node("Root/Panel/VBox/BackButton").emit_signal("pressed")
	mm.get_node("Root/Panel/VBox/BackButton").emit_signal("pressed")
	_check(fired[0] == 1, "★ 连点两次应只发一次 leave_requested,实得 %d" % fired[0])
	mm.queue_free()


func _count_marks(n: Node) -> int:
	var c := 0
	if n is Label and (n as Label).text.begins_with(MatchResult.MVP_MARK):
		c += 1
	for ch in n.get_children():
		c += _count_marks(ch)
	return c


func _shot(payload: Dictionary, verify: Callable) -> void:
	var m := MatchResult.new()
	add_child(m)
	m.show_result(payload)
	await get_tree().process_frame
	await get_tree().process_frame
	verify.call(m)
	var img := get_viewport().get_texture().get_image()
	img.save_png(OUT % _count)
	_count += 1
	m.queue_free()
	await get_tree().process_frame
