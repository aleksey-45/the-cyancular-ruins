extends Node

# 【一次性工具】把「代码里建的菜单屏」导出成 .tscn 骨架。
# ★ 为什么是「导出」而不是手写:判据是外观不变,而手抄一棵几十节点的树(锚点/尺寸/容器参数/样式)几乎必然抄错一两处,且抄错不报错 —— 本工具让现有代码自己把树建出来。
#   样式从 theme_override_* 转成 theme_type_variation 时逐值与 Theme 比对:只有「这个节点显式设的每一样都恰好等于某个变体的取值」才换,换不掉的原样留在 .tscn 里(诚实的兜底,外观也不变)。
# 跑法:"$GODOT" --headless --path . --quit-after 600 res://tools/gen_menu_scene.tscn -- <屏名>;输出 res://tests/_gen/<屏名>.tscn(不带脚本,纯骨架)。屏名与要剥的动态子树见 SCREENS。
# 生成物落进 .superpowers/(整目录 gitignore)⇒ 是校验用骨架、不是产物;产物是人工把校验过的骨架整理成 scenes/*.tscn 之后那一份。
# ★★ 重跑前必须还原输入:生成器读的就是 SCREENS[名].scene —— 它一旦已被覆盖成迁移版,拿到的是「已迁移的场景」:strip 全失败 + 换成变体 0 个,而照样写出一个文件。
#   还原用 git show HEAD:<路径> 把 .tscn 与 .gd 两个文件都拿回迁移前。
# ★★ 改名必须连同后代的 parent= 路径一起改(那一段是父节点名):只改父不改子 ⇒ 实例化时整棵子树静默消失。
# ★★ 别写死 theme 的 ext_resource id(每次生成都会变,如 1_m75q5):写死 ⇒ str.replace 一声不响什么都不做 ⇒ 脚本没挂上、动态行全空而零报错。用正则取 id,并对两处替换都加断言。
# ★★ 落地时把「导出那一刻代码写下的值」清回中性(本机 IP / 昵称 / 服务器地址 / 状态栏输出 / Settings 派生的局时与色片颜色 / 筛选选中态):只清「代码会写」的那些,静态设计值一个字不动(清错会真改行为)。
# ★★ 动态宿主在骨架里必须是空的:代码运行时往里填的容器(房卡格 / 禁用武器块 / 地图选择器宿主 / %BetaBlock)逐个断言「骨架里没孩子」;%BetaBlock 不能走 strip 谓词 —— beta 关着时它常态为空,而 strip 把「容器本来就空」也算失败,它有孩子的后果是静默重复。

const THEME_PATH := "res://ui/theme/menu_theme.tres"
const OUT_DIR := "res://.superpowers/sdd/_gen"

# 候选变体表:节点类 -> 候选名(按优先次序;末尾那个是「基础类本身」= 不挂变体)。取值照抄 tools/gen_menu_theme.gd 建出来的那套,加了新变体要在这里补一行。
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

# 屏名 -> { scene, strip: [定位谓词名] }:strip 里每一项都是本文件的一个 _strip_<名字>(),返回要从骨架里剥掉的子树根(动态行:每个玩家的 / 每次开局的 / 随设置变的);列表为空 = 该屏全是静态骨架。
const SCREENS := {
	"settings_menu": {"scene": "res://scenes/settings_menu.tscn", "strip": ["bind_grid"]},
	# 信息页:三块都得剥(提交历史 / 开发团队 / 致谢)—— 后两块虽是常量,但「名单行留代码」是本屏的边界;剥空后编辑器里那两块面板是空的,这条代价照实接受。
	"info_menu": {"scene": "res://scenes/info_menu.tscn",
			"strip": ["commit_list", "info_team", "info_credits"]},
	# Beta 页:两张卡片是数据驱动的(CARDS 常量)且图标是运行时生成的贴图 ⇒ 卡片留在代码里,骨架只留页面框架。
	"beta_menu": {"scene": "res://scenes/beta_menu.tscn", "strip": ["beta_cards"]},
	# 结算页:_ready() 建的全是静态的(压暗罩 / 面板 / 标题 / 副题 / 空的 Sections / 返回键),名次表要等 show_result() 拿到载荷才建 ⇒ 这一屏没有可剥的东西。
	"match_result": {"scene": "res://ui/screens/match_result.tscn", "strip": []},
	"main_menu": {"scene": "res://scenes/main_menu.tscn", "strip": []},
	# 大厅:T1 起三个弹层启动即建(默认隐藏),故这棵树里有三处动态容器要剥(房卡格 / 禁用武器网格 / 地图选择器)。
	"mp_lobby": {"scene": "res://scenes/mp_lobby.tscn",
			"strip": ["lobby_dynamic", "lobby_weapon_grid", "lobby_map_picker"]},
}

var _fails: Array[String] = []
var _converted := 0
var _kept := 0
var _fonts_dropped := 0
# ★★ 必须显式持有 theme:Control.theme 是本节点的局部 theme,子节点上它是 null(生效值靠父链回退)。拿它去比 ⇒ 子节点全部匹配不上 ⇒ 表现为「一个都没换、全部保留」(实测:换成变体 0 / 保留 66)。
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

	# 1) 让现有代码把树建出来(等价于真跑一次这一屏);★ 根不一定是 Control —— 结算页的根是 CanvasLayer,用 Node,别写死。
	var root: Node = packed.instantiate()
	add_child(root)
	await get_tree().process_frame
	await get_tree().process_frame

	# 2) 挂上 Theme(变体才解析得到值),再把可换的 override 换成变体。★ Theme 只能挂在 Control/Window 上 ⇒ 根是 CanvasLayer 时挂到第一个 Control(结算页就是那个 Root),挂上后整棵子树都解析得到变体。
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

	# 2b) --full:不剥动态行,导一份「完整骨架」—— 它是与改前截图逐像素比对用的(剥了动态行就没法直接比:那部分本来就该空着,等 .gd 填)。
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

	# 3b) ★★ 清掉所有 material:材质里挂的是运行时资源(主菜单背景那张 TerrainAtlas.terrain_texture() 烘出来的 4800×3200 贴图),PackedScene.pack 会把它整张内嵌进 .tscn;这类资源本来就得由代码在 _ready 里重建,清掉只是让 .tscn 不背死重量。★ 清的是属性不是节点:那个 ColorRect 还在(位置/尺寸/底色都保留),只是 material 为空。
	_clear_materials(root)

	# 4) 起名 + 设 owner(没 owner 的节点不会被 pack 收进去)。
	_name_nodes(root)
	_set_owner(root, root)
	# 去掉脚本:导出的是一份纯骨架,实例化它不会再有代码去建第二遍(生产 .tscn 由调用方在文本上补回 script = ExtResource(...))。
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


# ── 把 theme_override_* 换成 theme_type_variation ── 判据:这个节点显式设的每一样,都恰好等于某个候选变体在同名槽上的取值 ⇒ 换;任何一样对不上就整节点不动(宁可留 override,也不猜)。
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
				c.set(p, null)   # 清掉全部 override(*/font 除外,见下)
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


# 纹理按像素比。★ 不能写 have != theme.get_icon(...):_make_switch() 画出来的是运行时 ImageTexture,而 Theme 引用的是文件里的 PNG(CompressedTexture2D)—— 两者像素相同、对象不同,Resource 的 == 是同一性 ⇒ 那条比对恒假,CheckButton 永远换不成变体(实测:0 个转换)。两条 PNG 的 .import 已把 fix_alpha_border 关掉(见 gen_menu_theme 文件头),故逐像素可相等。
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


# StyleBoxFlat 逐属性比,不用 ==(Resource 的 == 是同一性,不是值)。
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


# 信息页:左栏滚动区里那棵提交历史 VBox(行随 AppInfo.commit_log() 变)。★ 剥的是 VBox 的子节点,VBox 自己留着 —— 它带 custom_minimum_size = (ROW_W, 0)。
func _strip_commit_list(root: Node) -> Node:
	var scroll := _find(root, func(n: Node) -> bool: return n is ScrollContainer)
	if scroll == null:
		return null
	return _find(scroll, func(n: Node) -> bool: return n is VBoxContainer)


# 信息页右栏两节(开发团队 / 致谢):按标题带的文字定位(比按层级稳 —— 换了嵌套也找得到),返回标题带所在的那个内容 VBox(要清空的就是它)。
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


# Beta 页:卡片行(整行剥掉 —— 卡片本身由 CARDS 在代码里建)。判据:第一个孩子是 PanelContainer 的那个 HBox —— 返回行也是 HBox,但它的孩子是 Button。
func _strip_beta_cards(root: Node) -> Node:
	return _find(root, func(n: Node) -> bool:
		return n is HBoxContainer and n.get_child_count() > 0 and n.get_child(0) is PanelContainer)


func _strip_result_grid(root: Node) -> Node:
	return _find(root, func(n: Node) -> bool: return n is GridContainer)


# 大厅房卡格:mp_lobby._grid。容器留着(columns / 两个间距 / 位置都是静态版式),剥的是它的行(房卡由 _make_card 一族按载荷画,「暂无房间」那句同理)。
# ★★ 这个谓词原先写的是「第一个 ScrollContainer」,T1 让三个弹层启动即建之后,弹层子树里也有 ScrollContainer(地图选择器内部的)⇒ 它静默命中错了:该剥的房卡格没剥、
#   不该剥的地图列表被剥成空盒,两边都不报错,只有取图看得出来。故改成结构上无歧义的定位:根下面那个 4 列 GridContainer(唯一),且必须在根下(不在任何弹层里)。
func _strip_lobby_dynamic(root: Node) -> Node:
	var box := _unique(root, func(n: Node) -> bool:
		return n is GridContainer and (n as GridContainer).columns == 4,
		"大厅房卡格(4 列 GridContainer)")
	if box == null:
		return null
	# 这条断言是「打到弹层里去」那道闸:根的孩子 ⇒ 必定不是三个弹层的后代。★ 只判 columns == 4 不足以挡住「弹层里将来也出现一个 4 列格」这种漂移。
	if box.get_parent() != root:
		_fails.append("大厅房卡格定位到了非根节点之下(parent=%s)⇒ 谓词有歧义(可能是弹层子树)"
				% str((box.get_parent() as Node).name))
		return null
	return box


# 创建弹层右列的「禁用武器」块(LobbyPage._add_weapon_grid 在代码里 new 一个 GridContainer 填进去,行 = WeaponRegistry,勾选态与 type_id 记账都要在代码里重接)⇒ 剥块的孩子。
# ★★ 返回父容器而不是那个 2 列 GridContainer(证据:_add_weapon_grid 自己 new 网格,骨架里不能留一个网格,留了就会变成两个);★ 只判「2 列」不够 —— 地图选择器内部的网格也是 2 列(实测命中 2 个候选),判据再加「不在 ScrollContainer 里」,这样与 strip 列表的先后顺序无关。
func _strip_lobby_weapon_grid(root: Node) -> Node:
	var grid := _unique(root, func(n: Node) -> bool:
		return n is GridContainer and (n as GridContainer).columns == 2 and not _under_scroll(n),
		"禁用武器网格(2 列 GridContainer,且不在 ScrollContainer 里)")
	return grid.get_parent() if grid != null else null


# 创建弹层右列的「地图选择器」整块(LobbyPage._add_map_picker 在代码里 new 一个 MapPicker 并 setup() 出缩略图网格)⇒ 剥宿主容器(map_block)的孩子 = 把整块选择器从骨架拿走。
# ★★ 返回的不是 ScrollContainer 自己的父节点:那一层是 MapPicker 本人(setup() 里 add_child(scroll)),而代码会 new 一个 ⇒ 骨架里连选择器节点都不能留,否则运行时是两个选择器;★ 中间那一层的形状要断一下(两个直接孩子,且第一个是标题带)—— 否则「祖父」只是碰巧对。
func _strip_lobby_map_picker(root: Node) -> Node:
	var scroll := _unique(root, func(n: Node) -> bool: return n is ScrollContainer,
			"地图选择器内部的 ScrollContainer")
	if scroll == null:
		return null
	var picker := scroll.get_parent()
	if picker == null or picker.get_parent() == null or picker.get_child_count() != 2 \
			or not (picker.get_child(0) is PanelContainer):
		_fails.append("地图选择器:ScrollContainer 的父节点形状不像 `MapPicker`"
				+ "(期望 2 个直接孩子、首子是标题带)⇒ 无法安全定位宿主容器")
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


# 定位一个唯一的结构候选:0 个(结构改了)或 ≥2 个(谓词有歧义)都算失败。★★ 为什么要它而不是直接用 _find:_find 返回第一个匹配 —— 谓词一旦有歧义,它会静默剥掉一棵本不该剥的子树,骨架里少一块而一条日志都没有(实测:大厅那条「第一个 ScrollContainer」命中到弹层里的地图选择器)。
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


# n 的任一祖先是不是 ScrollContainer?用于把「地图选择器滚动区里的那个网格」与「禁用武器网格」分开(见 _strip_lobby_weapon_grid)。
func _under_scroll(n: Node) -> bool:
	var p := n.get_parent()
	while p != null:
		if p is ScrollContainer:
			return true
		p = p.get_parent()
	return false


# ── 起名 + owner ── 代码建的节点名是 @VBoxContainer@12 这种,进 .tscn 之后在编辑器里没法读 ⇒ 按「类型 + 同类序号」重起一个稳定的名字。★ 只影响可读性,不影响任何取值。
func _name_nodes(root: Node) -> void:
	_name_children(root)


func _name_children(n: Node) -> void:
	var used := {}
	for c in n.get_children():
		# ★★ 只给「自动名」起名:代码建的节点若没显式 name = …,Godot 给的是 @HBoxContainer@12 这种;而显式起过名的(如结算页的 Panel / TitleLabel)本来就是语义名,再改一遍等于把作者的意思抹掉。判据就是那个 @ 前缀。
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
