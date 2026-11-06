extends Node


const THEME_PATH := "res://ui/theme/menu_theme.tres"
const OUT_DIR := "res://.superpowers/sdd/_gen"

const VARIANTS := {
	"Label": ["H1", "Body", "Small", "Dim", "HeaderTitle", "Label"],
	# ★ 没有「基础类型 Button」这一档:本 Theme 刻意不设 Button(否则 CheckButton 会沿类链穿上按钮的皮,见 gen_menu_theme.gd 的 _button_variants())。
	"Button": ["BtnAccent", "BtnGold", "BtnQuiet", "BtnLegacy", "BtnLegacyQuiet", "RowButton",
			"BtnPrimary"],
	"PanelContainer": ["PanelCarvedBody", "PanelCarved", "HeaderStrip", "RowPanel",
			"PanelContainer"],
	"CheckButton": ["CheckButton"],
	"LineEdit": ["LineEdit"],
	"HSlider": ["HSlider"],
}

const SCREENS := {
	"settings_menu": {"scene": "res://scenes/settings_menu.tscn", "strip": ["bind_grid"]},
	"info_menu": {"scene": "res://scenes/info_menu.tscn",
			"strip": ["commit_list", "info_team", "info_credits"]},
	"beta_menu": {"scene": "res://scenes/beta_menu.tscn", "strip": ["beta_cards"]},
	"match_result": {"scene": "res://ui/screens/match_result.tscn", "strip": []},
	"main_menu": {"scene": "res://scenes/main_menu.tscn", "strip": []},
	"mp_lobby": {"scene": "res://scenes/mp_lobby.tscn",
			"strip": ["lobby_dynamic", "lobby_weapon_grid", "lobby_map_picker"]},
}

var _fails: Array[String] = []
var _converted := 0
var _kept := 0
var _fonts_dropped := 0
var _theme: Theme = null


func _ready() -> void:
	var name := ""
	for a in OS.get_cmdline_user_args():
		if not a.begins_with("--"):
			name = a
	if name == "" or not SCREENS.has(name):
		print("GEN SCENE: 用法 `-- <屏名>`;已知 = %s" % str(SCREENS.keys()))
		get_tree().quit(1)
		return
	var cfg: Dictionary = SCREENS[name]
	var theme: Theme = load(THEME_PATH)
	if theme == null:
		print("GEN SCENE: FAIL 读不到 %s" % THEME_PATH)
		get_tree().quit(1)
		return
	var packed: PackedScene = load(str(cfg["scene"]))
	if packed == null:
		print("GEN SCENE: FAIL 读不到 %s" % cfg["scene"])
		get_tree().quit(1)
		return

	var root: Node = packed.instantiate()
	add_child(root)
	await get_tree().process_frame
	await get_tree().process_frame

	_theme = theme
	var theme_owner: Control = root as Control
	if theme_owner == null:
		theme_owner = _first_control(root)
	if theme_owner == null:
		print("GEN SCENE: FAIL 整棵树里没有 Control,Theme 无处可挂")
		get_tree().quit(1)
		return
	theme_owner.theme = theme
	_convert(root)

	var full := OS.get_cmdline_user_args().has("--full")
	var out_name := name + ("_full" if full else "")

	for s in ([] if full else cfg["strip"]):
		var box: Node = call("_strip_" + str(s), root)
		if box == null:
			_fails.append("strip「%s」没定位到目标容器(结构改了?)" % s)
			continue
		if box.get_child_count() == 0:
			_fails.append("strip「%s」定位到的容器本来就是空的 ⇒ 这条剥除是空转" % s)
			continue
		for c in box.get_children():
			# ★★ 永不删标题带:header_strip() 建出来的那块 PanelContainer 是内容 VBox 的亲儿子(tbox.add_child(strip) 之后才 add 各行)⇒「把 VBox 清空」会连标题一起抹掉、右栏变成两个没有标题的空盒子(实测踩过);标题是常量、属于静态骨架。
			if c is PanelContainer and (c as PanelContainer).theme_type_variation == &"HeaderStrip":
				continue
			box.remove_child(c)
			c.queue_free()

	_clear_materials(root)

	_name_nodes(root)
	_set_owner(root, root)
	root.set_script(null)

	var out := "%s/%s.tscn" % [OUT_DIR, out_name]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var ps := PackedScene.new()
	var perr := ps.pack(root)
	if perr != OK:
		print("GEN SCENE: FAIL pack 返回 %d" % perr)
		get_tree().quit(1)
		return
	var serr := ResourceSaver.save(ps, out)
	if serr != OK:
		print("GEN SCENE: FAIL 保存 %s 返回 %d" % [out, serr])
		get_tree().quit(1)
		return

	print("GEN SCENE[%s]: → %s(换成变体 %d 个节点 / 丢掉字体 override %d 处 / 保留其它 override %d 个节点)"
			% [out_name, out, _converted, _fonts_dropped, _kept])
	for f in _fails:
		print("  FAIL " + f)
	print("GEN SCENE: %s" % ("OK" if _fails.is_empty() else "FAIL(%d)" % _fails.size()))
	get_tree().quit(0 if _fails.is_empty() else 1)


func _convert(n: Node) -> void:
	if n is Control:
		_try_variation(n as Control)
	for c in n.get_children():
		_convert(c)


func _try_variation(c: Control) -> void:
	var overrides := _overrides_of(c)
	# ★★ 无条件先丢掉 theme_override_fonts/*:即使这个节点因为别的原因(如金色标题的 48 号字)没能整套换成变体,字体也必须走 Theme 的 default_font。
	#   UiFactory.style_control 挂的是 PixelFont.shared() 的 FontFile,它的价值(关抗锯齿/微调/子像素 + CJK 回退链)是运行时写上去的,存不进 .tscn;只留裸 ttf ⇒ 汉字没有字形、静默换字体。
	var rest: Array[String] = []
	for pn in overrides:
		if pn.begins_with("theme_override_fonts/"):
			c.set(pn, null)
			_fonts_dropped += 1
		else:
			rest.append(pn)
	overrides = rest
	if overrides.is_empty():
		return
	var cands: Array = VARIANTS.get(c.get_class(), [])
	for v in cands:
		var vname := str(v)
		if _matches(c, overrides, vname):
			for p in overrides:
				c.set(p, null)
			if vname != c.get_class():
				c.theme_type_variation = StringName(vname)
			_converted += 1
			return
	_kept += 1


func _overrides_of(c: Control) -> Array[String]:
	var out: Array[String] = []
	for p in c.get_property_list():
		var pn := str(p["name"])
		if pn.begins_with("theme_override_") and c.get(pn) != null:
			out.append(pn)
	return out


func _matches(c: Control, overrides: Array[String], vname: String) -> bool:
	var theme := _theme
	if theme == null:
		return false
	for pn in overrides:
		var parts := pn.split("/", false, 1)
		if parts.size() != 2:
			return false
		var kind := parts[0].trim_prefix("theme_override_")
		var slot := StringName(parts[1])
		var have = c.get(pn)
		match kind:
			"styles":
				if not _sb_eq(have, theme.get_stylebox(slot, vname)):
					return false
			"font_sizes":
				if int(have) != theme.get_font_size(slot, vname):
					return false
			"colors":
				if have != theme.get_color(slot, vname):
					return false
			"constants":
				if int(have) != theme.get_constant(slot, vname):
					return false
			"icons":
				if not _tex_eq(have, theme.get_icon(slot, vname)):
					return false
			"fonts":
				return false
			_:
				return false
	return true


func _tex_eq(a, b) -> bool:
	if a == null or b == null:
		return a == null and b == null
	if not (a is Texture2D) or not (b is Texture2D):
		return a == b
	var ia: Image = (a as Texture2D).get_image()
	var ib: Image = (b as Texture2D).get_image()
	if ia == null or ib == null:
		return false
	ia = ia.duplicate()
	ib = ib.duplicate()
	ia.convert(Image.FORMAT_RGBA8)
	ib.convert(Image.FORMAT_RGBA8)
	return ia.get_size() == ib.get_size() and ia.get_data() == ib.get_data()


func _sb_eq(a, b) -> bool:
	if a == null or b == null:
		return a == null and b == null
	if not (a is StyleBoxFlat) or not (b is StyleBoxFlat):
		return a == b
	var ak: StyleBoxFlat = a
	var bk: StyleBoxFlat = b
	for f in ["bg_color", "border_color", "corner_radius_top_left", "corner_radius_top_right",
			"corner_radius_bottom_right", "corner_radius_bottom_left", "border_width_left",
			"border_width_top", "border_width_right", "border_width_bottom",
			"content_margin_left", "content_margin_top", "content_margin_right",
			"content_margin_bottom", "draw_center"]:
		if ak.get(f) != bk.get(f):
			return false
	return true


# ── 剥动态行:按结构定位(不按名字 —— 代码建的节点名全是自动生成的)── 每个函数返回一个容器,它的子节点被清空(容器本身留在骨架里:columns / separation / custom_minimum_size 这些静态版式参数是骨架的一部分)。
# ★ 清空时跳过标题带(HeaderStrip);★ 定位不到、或定位到的容器本来就空 ⇒ 算失败(空转的剥除 = 这条 strip 已失效而没人知道)。

func _strip_bind_grid(root: Node) -> Node:
	return _find(root, func(n: Node) -> bool:
		return n is GridContainer and (n as GridContainer).columns == 2)


func _strip_commit_list(root: Node) -> Node:
	var scroll := _find(root, func(n: Node) -> bool: return n is ScrollContainer)
	if scroll == null:
		return null
	return _find(scroll, func(n: Node) -> bool: return n is VBoxContainer)


func _strip_info_team(root: Node) -> Node:
	return _section_body(root, "开 发 团 队")


func _strip_info_credits(root: Node) -> Node:
	return _section_body(root, "致 谢")


func _section_body(root: Node, title: String) -> Node:
	# ★★ 判据必须要求它是标题带本身(theme_type_variation == HeaderStrip):只判「文字等于 title」的话,外层那块 PanelCarved 递归下去也会命中同一条文字 ⇒ 返回的是整栏,
	#   一清就把这一栏连标题带一起抹掉(而 get_parent() 恰恰是合法值,不会报错)。
	var strip := _find(root, func(n: Node) -> bool:
		return n is PanelContainer and (n as PanelContainer).theme_type_variation == &"HeaderStrip" \
				and _first_label_text(n) == title)
	return strip.get_parent() if strip != null else null


func _first_label_text(n: Node) -> String:
	for c in n.get_children():
		if c is Label:
			return (c as Label).text
		var deeper := _first_label_text(c)
		if deeper != "":
			return deeper
	return ""


func _strip_beta_cards(root: Node) -> Node:
	return _find(root, func(n: Node) -> bool:
		return n is HBoxContainer and n.get_child_count() > 0 and n.get_child(0) is PanelContainer)


func _strip_result_grid(root: Node) -> Node:
	return _find(root, func(n: Node) -> bool: return n is GridContainer)


func _strip_lobby_dynamic(root: Node) -> Node:
	var box := _unique(root, func(n: Node) -> bool:
		return n is GridContainer and (n as GridContainer).columns == 4,
		"大厅房卡格(4 列 GridContainer)")
	if box == null:
		return null
	if box.get_parent() != root:
		_fails.append("大厅房卡格定位到了非根节点之下(parent=%s)⇒ 谓词有歧义(可能是弹层子树)"
				% str((box.get_parent() as Node).name))
		return null
	return box


func _strip_lobby_weapon_grid(root: Node) -> Node:
	return _unique(root, func(n: Node) -> bool:
		return n is VBoxContainer and not (n is MapPicker) and _looks_like_titled_scroll_block(n),
		"禁用武器块(不是 MapPicker 的「标题带 + 滚动区」VBox)")


func _looks_like_titled_scroll_block(n: Node) -> bool:
	if n.get_child_count() != 2:
		return false
	var head := n.get_child(0)
	return head is PanelContainer and (head as PanelContainer).theme_type_variation == &"HeaderStrip" \
			and n.get_child(1) is ScrollContainer


func _strip_lobby_map_picker(root: Node) -> Node:
	var picker := _unique(root, func(n: Node) -> bool:
		return n is MapPicker and _looks_like_titled_scroll_block(n),
		"地图选择器块(MapPicker:标题带 + 滚动区)")
	if picker == null:
		return null
	var host := picker.get_parent()
	if host == null:
		_fails.append("地图选择器:MapPicker 没有父节点 ⇒ 无法定位宿主容器")
		return null
	return host


func _clear_materials(n: Node) -> void:
	if n is CanvasItem and (n as CanvasItem).material != null:
		(n as CanvasItem).material = null
	for c in n.get_children():
		_clear_materials(c)


func _first_control(n: Node) -> Control:
	if n is Control:
		return n as Control
	for c in n.get_children():
		var r := _first_control(c)
		if r != null:
			return r
	return null


func _find(root: Node, pred: Callable) -> Node:
	if pred.call(root):
		return root
	for c in root.get_children():
		var r := _find(c, pred)
		if r != null:
			return r
	return null


func _unique(root: Node, pred: Callable, label: String) -> Node:
	var hits: Array[Node] = []
	_collect(root, pred, hits)
	if hits.size() != 1:
		_fails.append("定位「%s」命中 %d 个候选(期望恰 1 个)⇒ 谓词有歧义或结构改了"
				% [label, hits.size()])
		return null
	return hits[0]


func _collect(root: Node, pred: Callable, out: Array[Node]) -> void:
	if pred.call(root):
		out.append(root)
	for c in root.get_children():
		_collect(c, pred, out)


func _name_nodes(root: Node) -> void:
	_name_children(root)


func _name_children(n: Node) -> void:
	var used := {}
	for c in n.get_children():
		# ★★ 只给「自动名」起名:代码建的节点若没显式 name = …,Godot 给的是 @HBoxContainer@12 这种;而显式起过名的(如结算页的 Panel / TitleLabel)本来就是语义名,再改一遍等于把作者的意思抹掉。
		if str(c.name).begins_with("@"):
			var base := c.get_class()
			var k: int = int(used.get(base, 0)) + 1
			used[base] = k
			c.name = "%s%d" % [base, k]
		_name_children(c)


func _set_owner(n: Node, owner: Node) -> void:
	for c in n.get_children():
		c.owner = owner
		_set_owner(c, owner)
