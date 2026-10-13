extends Node


const EXPECTED_CHECKS := 20

const SCENE := "res://scenes/settings_menu.tscn"

# 一节里应当出现的四个标签 + 它们各自对应的 Settings 键。
const ROWS := [
	["显示子弹尾迹(所有子弹)", "pvp_show_trajectories"],
	["显示敌方血量条", "pvp_show_enemy_hp"],
	["打开小地图", "pvp_show_minimap"],
	["小地图显示敌方位置", "pvp_minimap_show_enemy"],
]

# 相 B 的交错基线(见文件头):相邻两键取值不同,好让"某一行接错键"必红。
const DISTINCT_BASELINE := [false, true, false, true]

var _checks := 0
var _fails: Array[String] = []


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if ok:
		print("  ok   " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


func _ready() -> void:
	var ps := load(SCENE) as PackedScene
	if ps == null:
		print("SETTINGS DISPLAY SECTION PROBE: FAIL(场景加载不到)")
		get_tree().quit(1)
		return
	# 探针会真的拨开关,而 `settings_menu.gd` 的 `_check()` 挂的 lambda 会 `Settings.save()`
	#  ->  会写用户的 cfg。记下原值,收尾还原后再 save() 一次(见 _restore)。
	var orig := {}
	for row in ROWS:
		orig[str(row[1])] = bool(Settings.get(str(row[1])))

	# ── 相 A:非默认基线(四个键全 false;出厂默认全是 true)──
	# 见文件头:默认基线会让"初值跟随 Settings"这条断言始终为 true,mutation 咬不住。
	_set_all_keys(false)
	var a := _build(ps)
	var labels_a := _collect_labels(a["page"])
	var section_found := false
	for l in labels_a:
		if str(l).contains("联机显示"):
			section_found = true
	_check(section_found, "设置页有「联机显示」一节(实得标签:%s)" % str(labels_a))
	_check(_count_label(labels_a, "联机显示") == 1,
			"「联机显示」这个标题**恰好出现 1 次**(插两遍会红)")
	var checks_a := _collect_checks(a["page"])
	for row in ROWS:
		var want := str(row[0])
		var key := str(row[1])
		var cb := _find_check_by_label(checks_a, want)
		_check(cb != null, "开关「%s」建出来了" % want)
		if cb == null:
			continue
		# - 非默认基线  ->  把 `Settings.<key>` 换成 `true` 字面量、或接到另一个真值为 true
		#   的键,都会让这条红。
		_check(cb.button_pressed == false,
				"「%s」的初值跟随 `Settings.%s`(非默认基线 false;写死 `true` 会红)"
						% [want, key])
	_check(_section_precedes_keymap(a["page"]), "「联机显示」排在「按键映射」**之前**")
	_check(_section_after_general(a["page"]), "「联机显示」排在「通用开关」**之后**")
	a["host"].free()   # 同一同步调用栈内 free:上面的断言全是同步的

	# ── 相 B:交错基线(相邻两键取值不同)+ 行为面 ──
	for i in ROWS.size():
		Settings.set(str(ROWS[i][1]), DISTINCT_BASELINE[i])
	var b := _build(ps)
	var checks_b := _collect_checks(b["page"])
	for i in ROWS.size():
		var want := str(ROWS[i][0])
		var key := str(ROWS[i][1])
		var cb := _find_check_by_label(checks_b, want)
		if cb == null:
			_check(false, "相 B:开关「%s」找不到" % want)
			continue
		_check(cb.button_pressed == bool(Settings.get(key)),
				"「%s」的初值来自 `Settings.%s`(基线交错,接错键会红)" % [want, key])
	# - 行为面:逐行拨动,断言只写它自己那个键(写错键 / 随意将别的键也写了都会红)。
	for i in ROWS.size():
		var want := str(ROWS[i][0])
		var key := str(ROWS[i][1])
		_set_all_keys(false)   # 每行从同一基线出发:其余三键必须保持 false
		var cb := _find_check_by_label(checks_b, want)
		if cb == null:
			_check(false, "行为面:开关「%s」找不到" % want)
			continue
		cb.button_pressed = true
		cb.toggled.emit(true)
		var others_untouched := true
		for j in ROWS.size():
			if j != i and bool(Settings.get(str(ROWS[j][1]))):
				others_untouched = false
		_check(bool(Settings.get(key)) == true and others_untouched,
				"拨动「%s」写回的是 `Settings.%s`,且不碰其它三个键" % [want, key])
	b["host"].free()

	_restore(orig)
	_finish()


# 造一页:加入场景树 -> `_ready` 跑完(控件齐全) -> 返回 {"host","page"};free 由调用方做。
# - 设置页 `_ready` 里没有 deferred 的网络动作(它不连大厅) ->  同一同步栈内 free 安全。
func _build(ps: PackedScene) -> Dictionary:
	var host := Node.new()
	add_child(host)
	var p: Node = ps.instantiate()
	host.add_child(p)
	return {"host": host, "page": p}


# 直接写内存里的四个 Settings 键(不 save() —— 落盘只发生在 lambda 与 _restore 里)。
func _set_all_keys(v: bool) -> void:
	for row in ROWS:
		Settings.set(str(row[1]), v)


# 还原探针进来时读到的四个原值,并落盘一次(把探针期间被 lambda 写脏的 cfg 复原)。
func _restore(orig: Dictionary) -> void:
	for row in ROWS:
		Settings.set(str(row[1]), bool(orig[str(row[1])]))
	Settings.save()


# 递归收所有 Label 的文本(用于断言"这一节存在/唯一"与"它排在别节之间")。
func _collect_labels(root: Node, out: Array = []) -> Array:
	if root is Label:
		out.append((root as Label).text)
	for c in root.get_children():
		_collect_labels(c, out)
	return out


func _collect_checks(root: Node, out: Array = []) -> Array:
	if root is CheckButton:
		out.append(root)
	for c in root.get_children():
		_collect_checks(c, out)
	return out


func _count_label(labels: Array, text: String) -> int:
	var n := 0
	for l in labels:
		if str(l) == text:
			n += 1
	return n


# 开关行 = 定宽标签列 + 紧邻控件(HBox);按标签找行、再取行里的 CheckButton。
func _find_check_by_label(checks: Array, label_text: String) -> CheckButton:
	for cb in checks:
		var row := (cb as CheckButton).get_parent()
		if row == null:
			continue
		for c in row.get_children():
			if c is Label and (c as Label).text == label_text:
				return cb
	return null


# 「联机显示」那节必须排在「按键映射」之前(与设计 §3.6 的次序一致)。
# - 判定依据为两个节标题在遍历序里的先后,不是它们在屏幕上的 y —— 后者会随版式变。
func _section_precedes_keymap(root: Node) -> bool:
	var labels := _collect_labels(root)
	var i_net := labels.find("联机显示")
	var i_key := -1
	for i in labels.size():
		if str(labels[i]).begins_with("按键映射"):
			i_key = i
			break
	return i_net >= 0 and i_key >= 0 and i_net < i_key


# 「联机显示」还必须排在「通用开关」之后 —— 只钉"早于按键映射"的话,把它插到
# 整页最前面(音量之前)也全部断言通过。
# - 锚点取「通用开关」那一块里唯一那一行的标签 —— 那一块(鼠标滚轮切枪)没有节标题,
#   故只能用行标签当锚。
func _section_after_general(root: Node) -> bool:
	var labels := _collect_labels(root)
	var i_net := labels.find("联机显示")
	var i_gen := labels.find("鼠标滚轮切枪")
	return i_net >= 0 and i_gen >= 0 and i_gen < i_net


func _finish() -> void:
	if _checks < EXPECTED_CHECKS:
		_fails.append("★ 只跑了 %d 条断言(期望 ≥ %d)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("SETTINGS DISPLAY SECTION PROBE: ALL-OK(%d 条断言)" % _checks)
		get_tree().quit(0)
	else:
		print("SETTINGS DISPLAY SECTION PROBE: %d 条失败" % _fails.size())
		for f in _fails:
			print("  ✗ " + f)
		get_tree().quit(1)
