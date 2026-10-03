extends Node

# 【一次性工具 · 计划 2026-10-03-ui-to-tscn-and-theme 的 Task 3-5 用】
# 把「代码里建的菜单屏」**导出成 `.tscn` 骨架**,让版式在 Godot 编辑器里看得见、拖得动。
#
# ═══ 为什么是"导出"而不是手写 ═══
# 这条任务的判据是「**外观不变**」,而手抄一棵几十节点的树(锚点/尺寸/容器参数/样式)几乎必然
# 抄错一两处 —— 而抄错**不报错**。本工具让**现有代码自己把树建出来**,于是:
#   · **版式**由构造保证不变(导出的就是同一棵树);
#   · **样式**从 `theme_override_*` 转成 `theme_type_variation` 时,**逐值与 Theme 比对**,
#     只有"这个节点显式设的每一样都恰好等于某个变体的取值"才换 —— 换不掉的原样留在
#     `.tscn` 里(诚实的兜底,外观也不变)。
#
# ═══ 跑法 ═══
#   "<GODOT> --headless --path . --quit-after 600 res://tools/gen_menu_scene.tscn -- <屏名>
# 输出 `res://tests/_gen/<屏名>.tscn`(**不带脚本** —— 纯骨架,供"实例化它再取图"的自检用)。
# 屏名与"要剥掉的动态子树"见 SCREENS。
#
# ═══ 覆盖上限(照实登记)═══
# ① 它只保证"**同一份代码**建出来的树 == `.tscn`"。`.gd` 里那份建树代码删掉之后,
#    两者就不再由构造绑定 —— 之后的漂移只有逐屏取图看得见。
# ② 字体:`theme_override_fonts/font` 的比对对象是 `Theme.default_font`(**不是**同一个对象:
#    一个是 `PixelFont.shared()` 的 FontFile,一个是 `menu_font.tres` 的 FontVariation)。
#    它们是"渲染等价"而不是"同一个资源" —— 故**字体这一项是放行而非逐值相等**,
#    由 Task 2 的前后取图与本次的骨架取图共同兜底。
# ③ 动态子树按**结构**定位(见 SCREENS 的 strip),不按名字 —— 改了那截结构要同步改这里。

const THEME_PATH := "res://ui/theme/menu_theme.tres"
# 输出落进 `.superpowers/`(整目录 gitignore)⇒ 生成的是**校验用骨架**,不是产物;
# 产物是人工把校验过的骨架整理成 `scenes/*.tscn` 之后那一份。
const OUT_DIR := "res://.superpowers/sdd/_gen"

# 候选变体表:节点类 -> 候选名(**按优先次序**;末尾那个是"基础类本身"= 不挂变体)。
# 取值照抄 `tools/gen_menu_theme.gd` 建出来的那套。加了新变体要在这里补一行。
const VARIANTS := {
	"Label": ["H1", "Body", "Small", "Dim", "HeaderTitle", "Label"],
	# ★ 没有"基础类型 Button"这一档:本 Theme **刻意不设** `Button`(否则 `CheckButton` 会沿
	#   类链穿上按钮的皮,见 gen_menu_theme.gd 的 `_button_variants()` 顶上那段)。
	"Button": ["BtnAccent", "BtnGold", "BtnQuiet", "BtnLegacy", "BtnLegacyQuiet", "RowButton",
			"BtnPrimary"],
	"PanelContainer": ["PanelCarvedBody", "PanelCarved", "HeaderStrip", "RowPanel",
			"PanelContainer"],
	"CheckButton": ["CheckButton"],
	"LineEdit": ["LineEdit"],
	"HSlider": ["HSlider"],
}

# 屏名 -> { scene, strip: [定位谓词名] }
# `strip` 里的每一项都是本文件里的一个 `_strip_<名字>()`,返回**要从骨架里剥掉的子树根**
# (动态行:每个玩家的/每次开局的/随设置变的)。列表为空 = 该屏全是静态骨架。
const SCREENS := {
	"settings_menu": {"scene": "res://scenes/settings_menu.tscn", "strip": ["bind_grid"]},
	"info_menu": {"scene": "res://scenes/info_menu.tscn", "strip": ["commit_list"]},
	"beta_menu": {"scene": "res://scenes/beta_menu.tscn", "strip": []},
	"match_result": {"scene": "res://ui/screens/match_result.tscn", "strip": ["result_grid"]},
	"main_menu": {"scene": "res://scenes/main_menu.tscn", "strip": []},
	"mp_lobby": {"scene": "res://scenes/mp_lobby.tscn", "strip": ["lobby_dynamic"]},
}

var _fails: Array[String] = []
var _converted := 0
var _kept := 0
var _fonts_dropped := 0
# ★★ 必须**显式**持有 theme:`Control.theme` 是**本节点的局部 theme**,子节点上它是 null
#    (生效值靠父链回退,`get_theme_stylebox()` 之类才走链)。用它去比对 ⇒ 子节点全部匹配不上
#    ⇒ 表现为"一个都没换、全部保留"(实测踩过:换成变体 0 / 保留 66)。
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

	# 1) 让**现有代码**把树建出来(等价于真跑一次这一屏)
	var root: Control = packed.instantiate()
	add_child(root)
	await get_tree().process_frame
	await get_tree().process_frame

	# 2) 挂上 Theme(变体才解析得到值),再把可换的 override 换成变体
	_theme = theme
	root.theme = theme
	_convert(root)

	# 2b) `--full`:**不剥**动态行,导一份"完整骨架" —— 它是与改前截图**逐像素比对**用的
	#     (剥了动态行就没法直接比:那部分本来就该空着,等 `.gd` 填)。
	var full := OS.get_cmdline_user_args().has("--full")
	var out_name := name + ("_full" if full else "")

	# 3) 剥掉动态子树
	for s in ([] if full else cfg["strip"]):
		var box: Node = call("_strip_" + str(s), root)
		if box == null:
			_fails.append("strip「%s」没定位到目标容器(结构改了?)" % s)
			continue
		if box.get_child_count() == 0:
			_fails.append("strip「%s」定位到的容器本来就是空的 ⇒ 这条剥除是空转" % s)
			continue
		for c in box.get_children():
			box.remove_child(c)
			c.queue_free()

	# 4) 起名 + 设 owner(没 owner 的节点不会被 pack 收进去)
	_name_nodes(root)
	_set_owner(root, root)
	# 去掉脚本:导出的是一份**纯骨架**,实例化它不会再有代码去建第二遍。
	# (真正的生产 `.tscn` 由调用方在文本上补回 `script = ExtResource(...)`)
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


# ── 把 `theme_override_*` 换成 `theme_type_variation` ──
# 判据:**这个节点显式设的每一样,都恰好等于某个候选变体在同名槽上的取值** ⇒ 换。
# 任何一样对不上就整节点不动(宁可留 override,也不猜)。
func _convert(n: Node) -> void:
	if n is Control:
		_try_variation(n as Control)
	for c in n.get_children():
		_convert(c)


func _try_variation(c: Control) -> void:
	var overrides := _overrides_of(c)
	# ★★ **无条件**先丢掉 `theme_override_fonts/*` —— 即使这个节点最终因为别的原因
	#   (如金色标题的 48 号字 + 金)没能整套换成变体,字体也必须走 Theme 的 `default_font`。
	#   理由:`UiFactory.style_control` 挂的是 `PixelFont.shared()` 的 **FontFile**,
	#   而它真正的价值(关抗锯齿/微调/子像素 + **CJK 回退链**)是**运行时**写上去的 ——
	#   `PackedScene.pack` 只会写出 `ExtResource("…/less_perfect_dos_vga.ttf")`,
	#   那些运行时属性**存不进 `.tscn`**。只留裸 ttf ⇒ **汉字没有字形、静默换字体**
	#   (关闭抗锯齿那三项已被 Task 2 烘进 `.import`,能活;回退链不能)。
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
				c.set(p, null)   # 清掉全部 override(*/font 除外,见下)
			if vname != c.get_class():
				c.theme_type_variation = StringName(vname)
			_converted += 1
			return
	_kept += 1


# 该节点上**显式设过**的 theme_override 属性名(`theme_override_styles/panel` 这种)。
func _overrides_of(c: Control) -> Array[String]:
	var out: Array[String] = []
	for p in c.get_property_list():
		var pn := str(p["name"])
		if pn.begins_with("theme_override_") and c.get(pn) != null:
			out.append(pn)
	return out


# 逐条比对:节点的每一个 override 是否都等于变体 `vname` 在同名属性上的取值。
func _matches(c: Control, overrides: Array[String], vname: String) -> bool:
	var theme := _theme
	if theme == null:
		return false
	for pn in overrides:
		var parts := pn.split("/", false, 1)
		if parts.size() != 2:
			return false
		var kind := parts[0].trim_prefix("theme_override_")   # styles / fonts / font_sizes / …
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
				return false   # 已在 `_try_variation` 里无条件丢掉,不该再走到这
			_:
				return false
	return true


# 纹理**按像素**比。★ 不能写 `have != theme.get_icon(...)`:`_make_switch()` 画出来的是
# 运行时 `ImageTexture`,而 Theme 引用的是**文件里的 PNG**(`CompressedTexture2D`)——
# 两者**像素相同、对象不同**,`Resource` 的 `==` 是同一性 ⇒ 那条比对**恒假**,
# CheckButton 会永远换不成变体(实测:0 个转换)。
# 两条 PNG 的 `.import` 已把 `fix_alpha_border` 关掉(见 gen_menu_theme 文件头),故逐像素可相等。
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


# StyleBoxFlat 逐属性比。不用 `==`(Resource 的 `==` 是同一性,不是值)。
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


# ── 剥动态行:按**结构**定位(不按名字 —— 代码建的节点名全是自动生成的)──
# 每个函数返回一个**容器**,它的**子节点**被清空(容器本身留在骨架里:它带着
# `columns` / `separation` / `custom_minimum_size` 这些静态版式参数,是骨架的一部分)。
# ★ 定位不到、或定位到的容器本来就空 ⇒ **算失败**(空转的剥除 = 这条 strip 已经失效而没人知道)。

# 设置页:右栏那个「(动作名, 键位)」两列表。行按 `Settings.REMAPPABLE_ACTIONS` 循环建,
# 文案随键位变 —— 全部动态。
func _strip_bind_grid(root: Node) -> Node:
	return _find(root, func(n: Node) -> bool:
		return n is GridContainer and (n as GridContainer).columns == 2)


# 信息页:左栏滚动区里那棵提交历史 VBox(行随 `AppInfo.commit_log()` 变)。
# ★ 剥的是 **VBox 的子节点**,VBox 自己留着 —— 它带 `custom_minimum_size = (ROW_W, 0)`。
func _strip_commit_list(root: Node) -> Node:
	var scroll := _find(root, func(n: Node) -> bool: return n is ScrollContainer)
	if scroll == null:
		return null
	return _find(scroll, func(n: Node) -> bool: return n is VBoxContainer)


# 结算页:结果网格。
func _strip_result_grid(root: Node) -> Node:
	return _find(root, func(n: Node) -> bool: return n is GridContainer)


# 大厅:动态区(房卡列表 / 名单行 / 表单行)。
func _strip_lobby_dynamic(root: Node) -> Node:
	return _find(root, func(n: Node) -> bool: return n is ScrollContainer)


func _find(root: Node, pred: Callable) -> Node:
	if pred.call(root):
		return root
	for c in root.get_children():
		var r := _find(c, pred)
		if r != null:
			return r
	return null


# ── 起名 + owner ──
# 代码建的节点名是 `@VBoxContainer@12` 这种 —— 进 `.tscn` 之后在编辑器里没法读。
# 按「类型 + 同类序号」重起一个稳定的名字。★ 只影响可读性,不影响任何取值。
func _name_nodes(root: Node) -> void:
	var used := {}
	for c in root.get_children():
		var base := c.get_class()
		var n: int = int(used.get(base, 0)) + 1
		used[base] = n
		c.name = "%s%d" % [base, n]
		_name_children(c)


func _name_children(n: Node) -> void:
	var used := {}
	for c in n.get_children():
		var base := c.get_class()
		var k: int = int(used.get(base, 0)) + 1
		used[base] = k
		c.name = "%s%d" % [base, k]
		_name_children(c)


func _set_owner(n: Node, owner: Node) -> void:
	for c in n.get_children():
		c.owner = owner
		_set_owner(c, owner)
