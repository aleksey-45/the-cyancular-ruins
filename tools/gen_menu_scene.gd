extends Node

# 菜单场景生成器。两种模式(入口:`godot --headless --path . res://tools/gen_menu_scene.tscn -- <屏名>`):
#
# ① `-- main_menu`(**构建**模式,M1 容器化迁移):从零搭出容器树并**直接写** `res://scenes/main_menu.tscn`。
#    ★ 0 个绝对 offset(生成后自检:内存态 offset 全 0 + 产物里没有 `offset_*` / `position =` / `size =` 行)。
#    ★ unique_name_in_owner 由本文件显式设置(主菜单脚本用 `%StartBtn` 等取节点)。
#    ★ 编辑器入口是**运行期**按 feature 追加的,不在骨架里(见 scenes/main_menu.gd 的 _wire_menu)。
#
# ② 其它屏名(settings_menu / info_menu / beta_menu / match_result / mp_lobby):旧「转换」路径 ——
#    读已入库的静态骨架,把逐控件 override 收敛成 Theme variation、剥掉动态行,输出到 OUT_DIR
#    (`.superpowers/sdd/_gen/`),再手工替换回 scenes/。这些页尚未迁移到容器化,保持原行为。
#
# ★ 主菜单版式以 scenes/main_menu.tscn 为准;改版式 = 改本文件的 `_build_main_menu()`,重跑生成器 + 前后截图。

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

# ② 转换路径的屏清单(main_menu 走 ① 的构建路径,不在这里)。
const SCREENS := {
	"settings_menu": {"scene": "res://scenes/settings_menu.tscn", "strip": ["bind_grid"]},
	"info_menu": {"scene": "res://scenes/info_menu.tscn",
			"strip": ["commit_list", "info_team", "info_credits"]},
	"beta_menu": {"scene": "res://scenes/beta_menu.tscn", "strip": ["beta_cards"]},
	"match_result": {"scene": "res://ui/screens/match_result.tscn", "strip": []},
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
	if name == "":
		print("GEN SCENE: 用法 `-- <屏名>`;main_menu = 容器化构建;转换路径 = %s" % str(SCREENS.keys()))
		get_tree().quit(1)
		return
	if name == "main_menu":
		_build_main_menu()
		return
	if not SCREENS.has(name):
		print("GEN SCENE: 未知屏名 %s(已知 = main_menu + %s)" % [name, str(SCREENS.keys())])
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


# ── ① 主菜单容器化骨架(构建模式;入口 `-- main_menu`)─────────────────────────────
# 结构(0 绝对 offset,全由容器 + token 决定):
#   MainMenu(Control,full-rect,theme)
#   ├ Bg(ColorRect,full-rect)                                      %Bg(兜底底色;地图读不到时可见)
#   ├ Backdrop(Control,full-rect,script=ui/menu_backdrop.gd)       %Backdrop(实时光影场景)
#   ├ TitleHost(MarginContainer,top-wide;边距 TITLE_TOP) → Title    %Title(160 号青色、无背景;固定顶部)
#   ├ CenterContainer(full-rect) → MarginContainer(SP_6) → Content VBox(SP_5)
#   │   ├ MenuBox(VBox,SP_5,min-x=MENU_COL_W,SHRINK_CENTER)        %MenuBox
#   │   │   ├ PlayGroup(VBox,SP_3)      %StartBtn/%MultiBtn/%BetaBtn
#   │   │   ├ SepA(ColorRect,BORDER_W)  %SepA
#   │   │   ├ OptGroup(VBox,SP_3)       %SettingsBtn/%VerBtn
#   │   │   ├ SepB(ColorRect,BORDER_W)  %SepB
#   │   │   └ QuitBtn                   %QuitBtn
#   │   └ Version(Label,16 号弱化)                                  %Version
#   └ UILayer(CanvasLayer 140) → UIRoot(Control,full-rect)          %UILayer/%UIRoot
#       ↑ 运行期单人开局面板(sp_launch_panel)的宿主;整块 mouse_filter=IGNORE,不挡菜单点击。
# ★ 编辑器入口是**运行期**按 feature 追加进 PlayGroup 的(见 scenes/main_menu.gd 的 _wire_menu),不在骨架里。

const MAIN_MENU_OUT := "res://scenes/main_menu.tscn"
const BACKDROP_SCRIPT := "res://ui/menu_backdrop.gd"
# 标题字号/颜色是用户裁定口径(160 号 / 青色 / 无背景):改了就是版式回归,生成器自检会红。
const TITLE_TEXT := "The Cyancular Ruins"
const MENU_COL_W := 880   # 菜单按钮列宽 = min(880, 可用):min-x + SHRINK_CENTER,按钮 EXPAND_FILL
const MENU_BTN_H := UiFactory.SP_10 + UiFactory.SP_6   # 按钮行高 = 112(用户口径:按钮再大一点)
const TITLE_TOP := UiFactory.SP_10 + UiFactory.SP_9   # 标题距屏幕顶 = 144(用户口径:比"贴顶"低一档)
const MENU_DROP_SPACER := UiFactory.SP_10              # 80 = 2×40:居中容器里加上方的 80 空白 ⇒ 内容整体下移 40px
# 主菜单脚本 / 布局探针按 % 取的名字(与迁移前一致;少一个 = main_menu.gd 或探针红)。
const MAIN_MENU_UNIQUE := [
	"UILayer", "UIRoot", "Bg", "Backdrop", "Title", "MenuBox", "PlayGroup", "SepA", "SepB", "OptGroup",
	"StartBtn", "MultiBtn", "BetaBtn", "SettingsBtn", "VerBtn", "QuitBtn", "Version",
]
# 按钮文本(menu_autotest 按文本点击,改文案会让真链路批静默找不到按钮)。
const MAIN_MENU_BTN_TEXTS := ["单 人 模 式", "多 人 模 式", "Beta", "设 置", "信 息", "退 出"]


func _build_main_menu() -> void:
	var theme: Theme = load(THEME_PATH)
	if theme == null:
		print("GEN SCENE[main_menu]: FAIL 读不到 %s" % THEME_PATH)
		get_tree().quit(1)
		return
	var menu_script: Script = load("res://scenes/main_menu.gd")
	if menu_script == null:
		print("GEN SCENE[main_menu]: FAIL 读不到 res://scenes/main_menu.gd")
		get_tree().quit(1)
		return

	# 根:全屏 Control;Theme 挂这里,子节点继承(工厂控件自带的 theme 打包前清掉)。
	var root := Control.new()
	root.name = "MainMenu"
	root.theme = theme
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# Bg:全屏 ColorRect;材质(shader)仍由 main_menu.gd 运行期挂。
	var bg := ColorRect.new()
	bg.name = "Bg"
	bg.color = UiFactory.C_BG
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)

	# 实时光影背景:游戏渲染管线(场景 TileMapLayer + ParallaxBg + PostProcess)+ 缓慢漂移;
	# 昼夜 120s = 24h 由 PostProcess 自己推进。地图读不到时它自己 push_warning,露出 Bg 兜底色。
	var backdrop := Control.new()
	backdrop.name = "Backdrop"
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.set_script(load(BACKDROP_SCRIPT))
	root.add_child(backdrop)

	# 标题:固定屏幕顶部(不跟菜单一起垂直居中),160 号青色、无背景。
	# TitleHost 用 top-wide 锚点(offset 全 0)+ MarginContainer 的 theme margin 表达"距顶 TITLE_TOP"。
	var title_host := MarginContainer.new()
	title_host.name = "TitleHost"
	title_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_host.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	title_host.add_theme_constant_override("margin_top", TITLE_TOP)
	title_host.add_theme_constant_override("margin_left", 0)
	title_host.add_theme_constant_override("margin_right", 0)
	root.add_child(title_host)
	var title := UiFactory.label("The Cyancular Ruins", UiFactory.T_TITLE, UiFactory.C_ACCENT)
	title.name = "Title"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_host.add_child(title)

	# 内容:居中 → 四周留白(SP_6) → 垂直一列(SP_5)。
	var center := CenterContainer.new()
	center.name = "Center"
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, UiFactory.SP_6)
	center.add_child(margin)

	var content := VBoxContainer.new()
	content.name = "Content"
	content.alignment = BoxContainer.ALIGNMENT_CENTER
	content.add_theme_constant_override("separation", UiFactory.SP_5)
	margin.add_child(content)

	# 菜单按钮列:列宽上限 MENU_COL_W,自己按内容定高。
	var menu_box := VBoxContainer.new()
	menu_box.name = "MenuBox"
	menu_box.custom_minimum_size = Vector2(MENU_COL_W, 0)
	menu_box.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	menu_box.add_theme_constant_override("separation", UiFactory.SP_5)
	content.add_child(menu_box)

	var play := VBoxContainer.new()
	play.name = "PlayGroup"
	play.add_theme_constant_override("separation", UiFactory.SP_3)
	menu_box.add_child(play)
	play.add_child(_menu_btn("StartBtn", "单 人 模 式", "primary"))
	play.add_child(_menu_btn("MultiBtn", "多 人 模 式", "primary"))
	play.add_child(_menu_btn("BetaBtn", "Beta", "quiet"))

	menu_box.add_child(_menu_sep("SepA"))

	var opt := VBoxContainer.new()
	opt.name = "OptGroup"
	opt.add_theme_constant_override("separation", UiFactory.SP_3)
	menu_box.add_child(opt)
	opt.add_child(_menu_btn("SettingsBtn", "设 置", "quiet"))
	opt.add_child(_menu_btn("VerBtn", "信 息", "quiet"))

	menu_box.add_child(_menu_sep("SepB"))
	menu_box.add_child(_menu_btn("QuitBtn", "退 出", "quiet"))

	# 版本号:运行期由 main_menu.gd 填 AppInfo.version_string();这里是占位。
	# ★ Theme 没有 16 号弱化 Label variation(Dim=32),故走 label() + token 色(不写色字面量)。
	var ver := UiFactory.label("", UiFactory.T_LABEL, UiFactory.C_TEXT_DIM)
	ver.name = "Version"
	ver.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(ver)

	# 弹层宿主:与迁移前一致(CanvasLayer 140 + 全屏 Control),运行期挂 sp_launch_panel。
	var ui_layer := CanvasLayer.new()
	ui_layer.name = "UILayer"
	ui_layer.layer = 140
	root.add_child(ui_layer)
	var ui_root := Control.new()
	ui_root.name = "UIRoot"
	ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui_layer.add_child(ui_root)

	root.set_script(menu_script)
	_strip_runtime_fonts(root)   # PixelFont.shared() 是运行期字体,存盘只剩裸 ttf(丢 CJK 回退)⇒ 不序列化
	_clear_child_themes(root)    # 只留根节点一份 Theme;variation 属性已单独存
	_name_nodes(root)            # 代码建的节点没有显式名字(@Label@9 这类)→ 起成 Label1 这样的稳定名
	_set_owner(root, root)
	for nm in MAIN_MENU_UNIQUE:
		var n := _find_named(root, nm)
		if n != null:
			n.unique_name_in_owner = true

	_verify_main_menu(root)
	_save_main_menu(root)


func _menu_btn(node_name: String, text: String, variant: String) -> Button:
	var b: Button = UiFactory.ui_button(text, UiFactory.T_H1,
			Vector2(0, MENU_BTN_H), variant)
	b.name = node_name
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# variation 已给字号(T_H2);去掉逐按钮字号 override ⇒ 以后改 token 按钮会跟着变。
	b.remove_theme_font_size_override("font_size")
	return b


func _menu_sep(node_name: String) -> ColorRect:
	var sep := ColorRect.new()
	sep.name = node_name
	sep.color = UiFactory.C_BORDER_DIM
	sep.custom_minimum_size = Vector2(0, UiFactory.BORDER_W)
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return sep


# ui_* 工厂会把 PixelFont.shared() 作为 font override 挂到控件上;它靠运行时算 CJK 回退链,
# 存进 .tscn 只剩裸 ttf(汉字没有字形、静默换字体)⇒ 打包前一律去掉,字体统一走 Theme.default_font。
func _strip_runtime_fonts(n: Node) -> void:
	if n is Control and (n as Control).has_theme_font_override("font"):
		(n as Control).remove_theme_font_override("font")
	for c in n.get_children():
		_strip_runtime_fonts(c)


func _clear_child_themes(n: Node) -> void:
	for c in n.get_children():
		if c is Control:
			(c as Control).theme = null
		_clear_child_themes(c)


func _find_named(n: Node, nm: String) -> Node:
	if String(n.name) == nm:
		return n
	for c in n.get_children():
		var r := _find_named(c, nm)
		if r != null:
			return r
	return null


# 生成后自检(每条都答得出「去掉什么才会红」):
#   ① 缺任一 unique name / 没设 unique_name_in_owner ⇒ main_menu.gd 的 % 取节点崩、布局探针红;
#   ② 按钮文本或 PlayGroup/MenuBox 顺序变了 ⇒ menu_autotest 按文本点不到、焦点/手柄 Tab 链顺序变;
#   ③ 任一 Control 带非 0 offset ⇒ 违反「0 绝对 offset」的迁移硬约束。
func _verify_main_menu(root: Node) -> void:
	for nm in MAIN_MENU_UNIQUE:
		var n := _find_named(root, nm)
		if n == null:
			_fails.append("缺少节点 %s" % nm)
		elif not n.unique_name_in_owner:
			_fails.append("%s 没设 unique_name_in_owner" % nm)
	var title := _find_named(root, "Title")
	if title == null or not (title is Label):
		_fails.append("Title 不是 Label(用户口径:无背景标题)")
	else:
		var tl := title as Label
		if tl.text != TITLE_TEXT:
			_fails.append("Title 文本不对:实得「%s」" % tl.text)
		if tl.get_theme_font_size("font_size") != UiFactory.T_TITLE:
			_fails.append("Title 字号不是 T_TITLE(160)")
		if tl.get_theme_color("font_color") != UiFactory.C_ACCENT:
			_fails.append("Title 颜色不是 C_ACCENT(青色)")
	var play := _find_named(root, "PlayGroup")
	var menu_box := _find_named(root, "MenuBox")
	if play == null or menu_box == null:
		_fails.append("缺 PlayGroup / MenuBox,无法验按钮顺序")
	else:
		var texts: Array[String] = []
		for c in play.get_children():
			if c is Button:
				texts.append((c as Button).text)
		var want_play: Array[String] = ["单 人 模 式", "多 人 模 式", "Beta"]
		if texts != want_play:
			_fails.append("PlayGroup 按钮顺序/文本不对:实得 %s,应为 %s" % [texts, want_play])
		var order: Array[String] = []
		for c in menu_box.get_children():
			order.append(String(c.name))
		var want_order: Array[String] = ["PlayGroup", "SepA", "OptGroup", "SepB", "QuitBtn"]
		if order != want_order:
			_fails.append("MenuBox 子节点顺序不对:实得 %s,应为 %s" % [order, want_order])
	var all_texts: Array[String] = []
	for nm in ["StartBtn", "MultiBtn", "BetaBtn", "SettingsBtn", "VerBtn", "QuitBtn"]:
		var b := _find_named(root, nm)
		if b is Button:
			all_texts.append((b as Button).text)
	if all_texts != MAIN_MENU_BTN_TEXTS:
		_fails.append("按钮文本漂了:实得 %s,应为 %s" % [all_texts, MAIN_MENU_BTN_TEXTS])
	var bad_offsets := _count_offsets(root)
	if bad_offsets > 0:
		_fails.append("有 %d 个 Control 带非 0 绝对 offset(容器化页面必须全 0)" % bad_offsets)


func _count_offsets(n: Node) -> int:
	var bad := 0
	if n is Control:
		var c := n as Control
		if c.offset_left != 0.0 or c.offset_top != 0.0 \
				or c.offset_right != 0.0 or c.offset_bottom != 0.0:
			bad += 1
	for c in n.get_children():
		bad += _count_offsets(c)
	return bad


func _save_main_menu(root: Node) -> void:
	if not _fails.is_empty():
		for f in _fails:
			print("  FAIL " + f)
		print("GEN SCENE: FAIL(%d) —— 结构自检没过,不写盘" % _fails.size())
		get_tree().quit(1)
		return
	var ps := PackedScene.new()
	var perr := ps.pack(root)
	if perr != OK:
		print("GEN SCENE[main_menu]: FAIL pack 返回 %d" % perr)
		get_tree().quit(1)
		return
	var serr := ResourceSaver.save(ps, MAIN_MENU_OUT)
	if serr != OK:
		print("GEN SCENE[main_menu]: FAIL 保存 %s 返回 %d" % [MAIN_MENU_OUT, serr])
		get_tree().quit(1)
		return
	# 产物层自检:从**磁盘文本**验绝对定位行与 unique name 行数(别靠"我以为写进去了")
	var text := FileAccess.get_file_as_string(MAIN_MENU_OUT)
	var abs_lines := 0
	var unique_lines := 0
	for line in text.split("\n"):
		var l := line.strip_edges()
		if l.begins_with("offset_") or l.begins_with("position =") or l.begins_with("size ="):
			abs_lines += 1
		if l.begins_with("unique_name_in_owner = true"):
			unique_lines += 1
	if text.is_empty():
		_fails.append("读回 %s 失败(保存成功但文件为空?)" % MAIN_MENU_OUT)
	if abs_lines > 0:
		_fails.append("产物里有 %d 行绝对定位(offset_* / position = / size =)" % abs_lines)
	if unique_lines < MAIN_MENU_UNIQUE.size():
		_fails.append("产物里 unique_name_in_owner 只有 %d 个(< %d)" % [unique_lines, MAIN_MENU_UNIQUE.size()])
	print("GEN SCENE[main_menu]: → %s(节点 %d / unique %d / 绝对 offset 行 %d)"
			% [MAIN_MENU_OUT, _count_nodes(root), unique_lines, abs_lines])
	for f in _fails:
		print("  FAIL " + f)
	print("GEN SCENE: %s" % ("OK" if _fails.is_empty() else "FAIL(%d)" % _fails.size()))
	root.free()   # 树没在场景里,得自己释放;否则退出时满屏 RID/ObjectDB 泄漏噪声
	get_tree().quit(0 if _fails.is_empty() else 1)


func _count_nodes(n: Node) -> int:
	var k := 1
	for c in n.get_children():
		k += _count_nodes(c)
	return k


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
