extends Node

# 菜单场景骨架导出工具。
# 用于实例化代码构建的界面树，并将通用样式属性转换为全局 Theme 变体引用，
# 导出为静态 .tscn 场景框架供编辑器排版与预览。
#
# 运行方式:
#   godot --headless --path . --quit-after 600 res://tools/gen_menu_scene.tscn -- <屏名>
# 输出路径默认为 res://tests/_gen/<屏名>.tscn
# 支持通过 --full 参数导出包含动态子节点的完整场景结构用于像素比对。

const THEME_PATH := "res://ui/theme/menu_theme.tres"
const OUT_DIR := "res://.superpowers/sdd/_gen"

# 控件类型与候选变体映射表（按匹配优先级排序）
const VARIANTS := {
	"Label": ["H1", "Body", "Small", "Dim", "HeaderTitle", "Label"],
	"Button": ["BtnAccent", "BtnGold", "BtnQuiet", "BtnLegacy", "BtnLegacyQuiet", "RowButton",
			"BtnPrimary"],
	"PanelContainer": ["PanelCarvedBody", "PanelCarved", "HeaderStrip", "RowPanel",
			"PanelContainer"],
	"CheckButton": ["CheckButton"],
	"LineEdit": ["LineEdit"],
	"HSlider": ["HSlider"],
}

# 界面配置映射表：场景路径与需剥离的动态子容器标识
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

	# 1. 实例化场景树并等待帧渲染以初始化布局
	var root: Node = packed.instantiate()
	add_child(root)
	await get_tree().process_frame
	await get_tree().process_frame

	# 2. 为根 Control 挂载 Theme 并将可替换样式转为变体
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

	# 3. 处理动态子容器剥离
	var full := OS.get_cmdline_user_args().has("--full")
	var out_name := name + ("_full" if full else "")

	for s in ([] if full else cfg["strip"]):
		var box: Node = call("_strip_" + str(s), root)
		if box == null:
			_fails.append("strip 谓词 %s 未找到目标容器" % s)
			continue
		if box.get_child_count() == 0:
			_fails.append("strip 谓词 %s 目标容器为空" % s)
			continue
		for c in box.get_children():
			# 保留标题栏等静态组件
			if c is PanelContainer and (c as PanelContainer).theme_type_variation == &"HeaderStrip":
				continue
			box.remove_child(c)
			c.queue_free()

	# 清除运行时动态生成的材质资源
	_clear_materials(root)

	# 4. 规范化节点名称并重置 owner 导出场景
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


# 遍历控件节点，尝试将内联样式属性匹配转换为 Theme 变体
func _convert(n: Node) -> void:
	if n is Control:
		_try_variation(n as Control)
	for c in n.get_children():
		_convert(c)


func _try_variation(c: Control) -> void:
	var overrides := _overrides_of(c)
	# 字体统一回退到 Theme default_font 处理
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


# 比较两个纹理的像素数据是否一致
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


# 比较 StyleBoxFlat 各属性值是否相等
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


# 动态子节点剥离定位函数

# 设置页面快捷键网格
func _strip_bind_grid(root: Node) -> Node:
	return _find(root, func(n: Node) -> bool:
		return n is GridContainer and (n as GridContainer).columns == 2)


# 信息页面提交历史列表
func _strip_commit_list(root: Node) -> Node:
	var scroll := _find(root, func(n: Node) -> bool: return n is ScrollContainer)
	if scroll == null:
		return null
	return _find(scroll, func(n: Node) -> bool: return n is VBoxContainer)


# 信息页面开发团队与致谢栏目
func _strip_info_team(root: Node) -> Node:
	return _section_body(root, "开 发 团 队")


func _strip_info_credits(root: Node) -> Node:
	return _section_body(root, "致 谢")


func _section_body(root: Node, title: String) -> Node:
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


# Beta 页面卡片容器
func _strip_beta_cards(root: Node) -> Node:
	return _find(root, func(n: Node) -> bool:
		return n is HBoxContainer and n.get_child_count() > 0 and n.get_child(0) is PanelContainer)


# 结算界面结果网格
func _strip_result_grid(root: Node) -> Node:
	return _find(root, func(n: Node) -> bool: return n is GridContainer)


# 多人大厅房间列表网格
func _strip_lobby_dynamic(root: Node) -> Node:
	var box := _unique(root, func(n: Node) -> bool:
		return n is GridContainer and (n as GridContainer).columns == 4,
		"大厅房卡格(4 列 GridContainer)")
	if box == null:
		return null
	if box.get_parent() != root:
		_fails.append("大厅房卡格定位错误 (parent=%s)，存在歧义"
				% str((box.get_parent() as Node).name))
		return null
	return box


# 创建房间弹窗禁用武器网格
func _strip_lobby_weapon_grid(root: Node) -> Node:
	var grid := _unique(root, func(n: Node) -> bool:
		return n is GridContainer and (n as GridContainer).columns == 2 and not _under_scroll(n),
		"禁用武器网格(2 列 GridContainer)")
	return grid.get_parent() if grid != null else null


# 创建房间弹窗地图选择器宿主
func _strip_lobby_map_picker(root: Node) -> Node:
	var scroll := _unique(root, func(n: Node) -> bool: return n is ScrollContainer,
			"地图选择器内部的 ScrollContainer")
	if scroll == null:
		return null
	var picker := scroll.get_parent()
	if picker == null or picker.get_parent() == null or picker.get_child_count() != 2 \
			or not (picker.get_child(0) is PanelContainer):
		_fails.append("地图选择器容器结构不符，无法安全定位宿主")
		return null
	return picker.get_parent()


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


# 定位唯一结构节点，命中数量不为 1 时记录错误
func _unique(root: Node, pred: Callable, label: String) -> Node:
	var hits: Array[Node] = []
	_collect(root, pred, hits)
	if hits.size() != 1:
		_fails.append("定位 %s 命中 %d 个候选（期望单一匹配）"
				% [label, hits.size()])
		return null
	return hits[0]


func _collect(root: Node, pred: Callable, out: Array[Node]) -> void:
	if pred.call(root):
		out.append(root)
	for c in root.get_children():
		_collect(c, pred, out)


# 检查节点是否位于 ScrollContainer 容器内部
func _under_scroll(n: Node) -> bool:
	var p := n.get_parent()
	while p != null:
		if p is ScrollContainer:
			return true
		p = p.get_parent()
	return false


# 为自动生成的内部节点赋予规范命名
func _name_nodes(root: Node) -> void:
	_name_children(root)


func _name_children(n: Node) -> void:
	var used := {}
	for c in n.get_children():
		# 仅为以 @ 开头的自动生成命名重命名，保留手动命名的语义节点
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

