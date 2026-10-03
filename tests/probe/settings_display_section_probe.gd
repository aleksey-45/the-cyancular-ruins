extends Node

# 设置页「联机显示」一节的常驻守卫。
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/probe/settings_display_section_probe.tscn
# 判据: 文本 `SETTINGS DISPLAY SECTION PROBE: ALL-OK`(不看退出码)。
#
# ★ 为什么需要它:四个开关原先只长在 1v1 大厅页上,那页在计划①里被删了 ⇒ 键还在、
#   读者还在,但**界面上再也改不了它们**。本探针钉住"这一节真的建出来了、且每个开关
#   真的写了对应的 Settings 键"。
# ★ 断言计数:ALL-OK 只证明"没有一条失败",不证明"该跑的都跑过"(见 tests/lib/probe_base.gd
#   文件头)。少跑一条就红 —— 改本探针必须同步改这个数。
#
# ★★ 与实施简报的一处**有意偏离**(2026-10-03):简报的 ROWS[0] 写的是 "显示子弹尾迹",
#   而设计文档 §3.6 与旧 1v1 大厅页(`matchmaking.gd`)的**权威文案**是
#   "显示子弹尾迹(所有子弹)"(括号里那半截是原文)。本探针的 `_find_check_by_label`
#   是**逐字相等**,故照简报写会让"这一行找不到"**恒红**。这里按**设计文档的文案**取值,
#   与 settings_menu.gd 实际建的标签一致 —— 偏离的是简报的笔误,不是设计。
const EXPECTED_CHECKS := 11

const SCENE := "res://scenes/settings_menu.tscn"

# 一节里应当出现的四个标签 + 它们各自对应的 Settings 键。
const ROWS := [
	["显示子弹尾迹(所有子弹)", "pvp_show_trajectories"],
	["显示敌方血量条", "pvp_show_enemy_hp"],
	["打开小地图", "pvp_show_minimap"],
	["小地图显示敌方位置", "pvp_minimap_show_enemy"],
]

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
	var p: Node = (load(SCENE) as PackedScene).instantiate()
	if p == null:
		print("SETTINGS DISPLAY SECTION PROBE: FAIL(场景加载不到)")
		get_tree().quit(1)
		return
	# ★ 不入树:入树会跑 `_ready`,而设置页 `_ready` 里 `Settings` 的读写与字体补全都会跑一遍。
	#   本探针只想验**建出来的控件**。设置页的控件全在 `_ready` 里建,故必须入树再摘。
	#
	# ★★ 因此这里用「加进树 → 同一同步调用栈内 free」的手法(与 lobby_create_form_probe 同款):
	#    `_ready` 跑完、控件齐全,而设置页 `_ready` 里没有 deferred 的网络动作(它不连大厅),
	#    所以没有"帧末才炸"的风险。
	var host := Node.new()
	add_child(host)
	host.add_child(p)
	var labels := _collect_labels(p)
	var section_found := false
	for l in labels:
		if str(l).contains("联机显示"):
			section_found = true
	_check(section_found, "设置页有「联机显示」一节(实得标签:%s)" % str(labels))
	var checks := _collect_checks(p)
	for row in ROWS:
		var want := str(row[0])
		var key := str(row[1])
		var cb := _find_check_by_label(checks, want)
		_check(cb != null, "开关「%s」建出来了" % want)
		if cb == null:
			continue
		# ★ 这条是本节的核心:开关的**初值必须来自那个 Settings 键**,不是写死的。
		#   把 `Settings.<key>` 换成 `true` 字面量 ⇒ 这条红。
		#   但"拨动开关会写回"那一半**行为面**在下面用真信号驱动。
		_check(cb.button_pressed == bool(Settings.get(key)),
				"「%s」的初值来自 `Settings.%s`" % [want, key])
	_check(_section_precedes_keymap(p), "「联机显示」排在「按键映射」**之前**")
	# ★ 行为面:拨一下开关,断言 Settings 真的被写回(而不是只画了个控件)。
	var first := _find_check_by_label(checks, "显示子弹尾迹(所有子弹)")
	if first != null:
		var before := Settings.pvp_show_trajectories
		first.button_pressed = not before
		first.toggled.emit(not before)
		_check(Settings.pvp_show_trajectories == (not before),
				"拨动「显示子弹尾迹(所有子弹)」会写回 Settings(不是只画了个控件)")
		Settings.pvp_show_trajectories = before
		Settings.save()
	host.free()   # 同一同步调用栈内 free:上面的断言全是同步的
	_finish()


# 递归收所有 Label 的文本(用于断言"这一节存在"与"它排在按键映射之前")。
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
# ★ 判据是**两个节标题在遍历序里的先后**,不是它们在屏幕上的 y —— 后者会随版式变。
func _section_precedes_keymap(root: Node) -> bool:
	var labels := _collect_labels(root)
	var i_net := labels.find("联机显示")
	var i_key := -1
	for i in labels.size():
		if str(labels[i]).begins_with("按键映射"):
			i_key = i
			break
	return i_net >= 0 and i_key >= 0 and i_net < i_key


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
