extends SceneTree

# UI 调色板**单一来源**守卫(底板色 + 队色 + Theme .tres 的颜色字面量)。
# 纯源码级、`-s` 可跑、不占端口、**不需要渲染**。
#
# 跑法:  source tests/env.sh && timeout 120 "$GODOT" --headless --path . \
#            -s res://tests/smoke/ui_palette_single_source_smoke.gd
# 判据:  文本 `UI PALETTE: ALL-OK`(**不看退出码** —— 挂住时一行裁决都不打印)。
#
# ═══ 为什么需要它 ═══
# 底板色 `Color(0, 0, 0, 0.1)` 原先有 **6 个**独立落点(3 个 `.gd` 常量 + 1 处内联 +
# **2 个 `.tscn` 字面量**),而**一个守卫都没有** —— 漏改是**静默**的,只靠 `CLAUDE.md` 里
# 一条"手工 grep 对账"的纪律维持。本守卫钉死两件事:
#   ① 四个 `.gd` 落点**必须引用** `UiFactory.C_PLATE`(而不是又写一个字面量);
#   ② 两个 `.tscn` 的 `bg_color` **结构上引用不到 GDScript 的 const**(它是 StyleBoxFlat 的
#      属性,不是资源引用)⇒ 只能留字面量 —— 由本守卫**读文本**断言它与 `C_PLATE` **逐位相等**。
# 队色同理:`BODY_BASE_COLOR` 必须引用 `UiFactory.C_TEAM_A`(两份逐位相同的字面量 → 一份)。
#
# ★ 判据一律**剥注释后**匹配(`ScanUtil.code_only`) —— 否则那些"这是唯一源"的说明文字会把它
#   自己判红。
# ★ `.tscn` 不是 GDScript,`code_only` 不适用 ⇒ 那两处读**原文**,并归一化空白后比较。
# ★ 为什么另立 `-s` 而不并进 `hue_tint_probe`:后者是**真渲染**探针(headless 下
#   `get_image()` 给 null ⇒ 直接 FAIL 并 return),源码级断言不该寄生在它里面。
#
# ★ 2026-10-03 新增第 ⑥ 条:Theme 资源(`ui/theme/menu_theme.tres`)里的**每一个**
#   `Color(...)` 字面量都必须**逐位等于**调色板里某个 `const C_*`。成因同 ④:`.tres` 里的
#   StyleBoxFlat 颜色是字面量、引用不到 GDScript 的 const —— 只能读文本钉值。
#
# ★★ **已知的判据上限(登记,别当漏洞)**:
#    · 前半(②/⑤):本守卫只钉那 **6 处**具名落点 + 一条"全仓再无游离字面量"的反向断言。
#      将来新增第 7 处时,反向断言会红 —— **前提是它写成 `Color(0, 0, 0, 0.1)` 字面量**;
#      若写成第三种 `const` 名字,反向断言抓不到。**同一串字面量的等价改写也抓不到**
#      (如 `Color(0.0, 0.0, 0.0, 0.1)`) —— `_norm` 只去空白,**不做数值形态归一**,故 ②/⑤
#      是按**字面字符**比对的,不是按颜色值。
#    · ★★ 第 ⑥ 条(Theme)**钉的是值** —— 它保证"Theme 里出现的每个颜色都来自调色板",
#      **钉不住**"某个控件忘了挂 Theme 于是用了 Godot 默认样式":那种情况下控件画出来的
#      根本不经过这个 .tres,而本守卫只读 .tres 原文、看不到场景侧有没有引用它。
#      那一档的拦截手段是**逐屏真实渲染取图**(设计 §4.3),不是本守卫。
#      同理,它也不钉"某个颜色**该不该**出现在这里"(一个调色板常量用在错的控件上照样绿)。
#    · ★★ 第 ⑦ 类**今天不扫**(2026-10-03 实测后登记,别当没看见):`.tscn` 里**节点属性**上的
#      颜色字面量(`color = Color(...)` / `theme_override_colors/...`)。以 `scenes/` + `ui/` 为
#      root 实测共 **214** 处 `Color(...)`:**108** 处在 `[sub_resource]` 里(生成器产出的
#      StyleBoxFlat,**逐位**等于某个 `C_*`),另 **106** 处是节点属性,其中 **30 处按值不等于
#      任何常量** —— 而这 30 处**不是**待清理的漂移:`modulate` 的无染色值(10)、落地脚本的
#      可见性 hack(2)、HUD 专属文本色(4,`pvp_hud`/`team_hud` 从未走调色板)、战斗反馈色(4)、
#      武器激光色(3,玩法数据)、全屏压暗罩 `0,0,0,0.55`(2,`match_result.gd` 登记过的例外)、
#      大乱斗排行榜板底 `0,0,0,0.25`(1,`combat_hud_visual_probe` 登记过的例外)、
#      以及 4 处**孤儿页底色** `Color(0.07,0.09,0.13,1)`(`_add_lobby_background` 退役后全仓
#      **已无活体来源**,也不是任何 `C_*`)。
#      ★ 明细**必须自己加得起来**:10 + 2 + 4 + 4 + 3 + 2 + 1 + 4 = **30**(2026-10-04 订正:
#        此前那句把 HUD 专属文本色写成 8、又漏了 `0,0,0,0.25` 那条 ⇒ 明细加起来是 33)。
#      ⇒ 要把它们扫进来,只能挂一张 ~30 条的豁免表(= 让守卫的绿由豁免撑起),且那 4 处孤儿
#        得先在生产侧有家(本轮生产冻结)⇒ **登记为欠账,本轮不扩**。逐项清单见 T3b 报告 §7;
#        正式登记应进 `docs/eng/registered-debt.md`(该文件归另一会话,本轮未动)。

const PALETTE := "res://ui/factory/ui_factory.gd"
# 底板色字面量的**归一化后**形态(空白在 `_norm` 里被去掉)。
const PLATE_LITERAL := "Color(0,0,0,0.1)"
# 队 1 token 的重复字面量(改前 `BODY_BASE_COLOR` 就是这个) —— 归一化后。
const TEAM_A_LITERAL := "Color(99.0/255.0,155.0/255.0,1.0)"

# 四个 `.gd` 落点:三处 `const PLATE_COLOR` + 一处内联(`royale_hud._plate_box`)。
const GD_SITES := [
	"res://ui/hud/hud.gd",
	"res://ui/hud/weapon_slots.gd",
	"res://ui/factory/world_label.gd",
	"res://ui/hud/royale_hud.gd",
]
# 两个**结构上无法派生**的落点:`.tscn` 里 StyleBoxFlat 的 bg_color。
const TSCN_SITES := [
	"res://ui/hud/pvp_hud.tscn",
	"res://ui/hud/team_hud.tscn",
]
# 队色那一半。
const BODY_BASE_SITE := "res://scenes/pvp_match_client.gd"

# ⑥ Theme 资源:里面每个 `Color(...)` 必须等于调色板某个 `const C_*`。
const THEME_SITE := "res://ui/theme/menu_theme.tres"
# ⑥ 抽到的 `Color(...)` 个数**下限**(防空转):.tres 形状变了 / 读坏了 ⇒ 零命中 = 假绿。
#   今日实测 2026-10-03:menu_theme.tres 共 **34** 个 Color(...)(11 个 StyleBoxFlat 21 个 +
#   [resource] 13 个),取 20 留健康余量。
const THEME_COLOR_MIN := 20
# 颜色值比较的容差(逐位相等,但容忍 .tres 的浮点序列化位数):
#   ResourceSaver 把 float32 写成十进制再解析回来,噪声只有 ~1e-8 量级(float32 的十进制
#   表示相对误差 ~6e-8)。取 1/65536 ≈ 1.5e-5:比噪声大好几个数量级,又**远小于**
#   改一个十进制数字的最小差(如 0.902→0.903 = 0.001)⇒ 任何"改一位"都能被逮住。
#   ★ 起初取 1/512(≈0.00195)在变异实测里**放过**了 0.902→0.903(差 0.001)—— 那正是
#     本守卫要抓的东西,故收紧到这个值(实测:改一位即红)。
const COLOR_TOL := 1.0 / 65536.0
# ⑤ 反向断言的白名单 = 允许出现底板色**字面量**的文件:
#   调色板自己(它就是源)+ 两个 `.tscn`(结构上派生不了)+ **本文件自己**
#   (`PLATE_LITERAL` 这个常量本身就把那串字写在了源码里 —— 不白名单它,⑤ 会自己判自己红)。
const LITERAL_ALLOWED := [PALETTE, "res://ui/hud/pvp_hud.tscn", "res://ui/hud/team_hud.tscn",
		"res://tests/smoke/ui_palette_single_source_smoke.gd"]
# ⑤ 扫的目录(生产 + 测试)。
#   ★ `render/` 这个根曾必须在列(`camera_2d.gd` / `post_process.gd` 原住那里);Task 2 把
#     `render/` 并入 `core/present/` 后那两份文件由 `res://core` **递归**覆盖(`ScanUtil.walk`
#     是递归的)⇒ 该根已删 —— 留着它只会让下面那条"逐根 ≥1 文件"的检查报"根被搬走"。
const SCAN_DIRS := ["res://ui", "res://scenes", "res://core", "res://server", "res://tests"]
# `_rhs_of` 的词界判据用的标识符字符集(needle 后面紧跟其中任一个 = 命中的是兄弟常量)。
const IDENT_CHARS := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"
# ⑤ 扫描到的源文件数**下限**:防止"扫描根本坏了 → 一个文件都没扫到 → 零命中 = 假绿"
#   (照 `tests/probe/kh_l4_probe.gd:41-43` 的 `MIN_PROD_FILES` / `MIN_ALL_FILES` 先例)。
#   今日实测(Task 2 搬完 render/ 后)SCAN_DIRS 共 334 个(ui 26 / scenes 62 / core 41 /
#   server 16 / tests 189),取 250 留健康余量,只拦"整档坏掉"那一类。
const MIN_SCANNED := 250


func _initialize() -> void:
	var fails: Array[String] = []

	# ── ① 唯一源在位,并取出它的值(原文) ──
	var pal_code := ScanUtil.code_only(ScanUtil.read(PALETTE))
	if pal_code.is_empty():
		# 读不到 = 本守卫失明 ⇒ 直接红,不静默跳过。
		print("  FAIL ① 读不到 %s(读不到就是红,不是静默跳过)" % PALETTE)
		print("UI PALETTE: FAIL(1 条)")
		quit(1)
		return
	var plate_rhs := _rhs_of(pal_code, "const C_PLATE")
	if plate_rhs == "":
		fails.append("① `%s` 里没有 `const C_PLATE`(唯一源不存在)" % PALETTE)
	elif _norm(plate_rhs) != PLATE_LITERAL:
		fails.append("① `C_PLATE` 的值不是底板色(实得「%s」)" % plate_rhs)

	# ── ② 四个 `.gd` 落点:必须引用源,**且不许留字面量** ──
	for path in GD_SITES:
		var code := ScanUtil.code_only(ScanUtil.read(path))
		if code.is_empty():
			fails.append("② 读不到 %s(读不到就是红)" % path)
			continue
		if not code.contains("UiFactory.C_PLATE"):
			fails.append("② %s 没有引用 `UiFactory.C_PLATE`(它该是别名/引用,不是第二个源)" % path)
		if _norm(code).contains(PLATE_LITERAL):
			fails.append("② %s 里还有底板色**字面量**(别名里不该有字面量)" % path)

	# ── ③ `BODY_BASE_COLOR` 必须引用 `UiFactory.C_TEAM_A` ──
	var body := ScanUtil.code_only(ScanUtil.read(BODY_BASE_SITE))
	if body.is_empty():
		fails.append("③ 读不到 %s(读不到就是红)" % BODY_BASE_SITE)
	else:
		if not body.contains("UiFactory.C_TEAM_A"):
			fails.append("③ %s 的 `BODY_BASE_COLOR` 没有引用 `UiFactory.C_TEAM_A`" % BODY_BASE_SITE)
		if _norm(body).contains(TEAM_A_LITERAL):
			fails.append("③ `BODY_BASE_COLOR` 那份**重复字面量**还在(应改成别名)")

	# ── ④ 两个 `.tscn`:读原文,断言 bg_color 与 `C_PLATE` **逐位相等** ──
	#    ★ 比的是**调色板里那个值**(不是本文件里那串字) —— 这样"改了 C_PLATE 却没改 .tscn"
	#      才会红。① 已经失败时这里必然也红(没有可比的值),那是正确的连带。
	for path in TSCN_SITES:
		var raw := ScanUtil.read(path)
		if raw.is_empty():
			fails.append("④ 读不到 %s(读不到就是红)" % path)
			continue
		var found := _tscn_bg_colors(raw)
		if found.is_empty():
			fails.append("④ %s 里找不到 `bg_color = Color(...)`(形状变了 ⇒ 本守卫失明)" % path)
			continue
		if found.size() > 1:
			fails.append("④ %s 里有 **%d 处** `bg_color`(本守卫只认得出恰好一处 ⇒ 多出来的那几处没有任何断言看着)"
					% [path, found.size()])
			continue
		var got := found[0]
		# ★ ① 没读出 `C_PLATE` 时**没有可比的值**,但本条仍要红(闸门照旧) —— 只是判词改成
		#   "无法比对",别打 `期望「」`:那读起来像"期望是空串",把人往错方向引。
		if plate_rhs == "":
			fails.append("④ %s 无法比对:① 没读出 `C_PLATE`(见 ①)" % path)
		elif _norm(got) != _norm(plate_rhs):
			fails.append("④ %s 的 `bg_color` 与 `C_PLATE` 不等(实得「%s」,期望「%s」)"
					% [path, got, plate_rhs])
		# ★ 这一条**独立且无条件**(不并进上面的 if/elif):它比的是**字面量**,不依赖 ① 读到什么。
		if _norm(got) != PLATE_LITERAL:
			fails.append("④ %s 的 `bg_color` 不是底板色(实得「%s」)" % [path, got])

	# ── ⑤ 反向:全仓再无**游离**的底板色字面量(白名单见 LITERAL_ALLOWED) ──
	# ★★ 覆盖下限(两条,都是"扫描坏掉 ⇒ 零命中 = 假绿"的解药):`ScanUtil.walk` 在**根打不开时
	#    静默返回**(`DirAccess.open` 给 null 就直接 return,一个字都不打)⇒ 根被改名/搬走会让本条
	#    **无声收窄**:扫到的文件少了、命中自然少了,而 verdict 照打 `ALL-OK`。
	#      ① **逐根**:每个根都必须扫到 ≥1 个文件,点名是哪个根 —— 这才是"某个根打不开"的
	#         **精确**判据(全局下限单独一条抓不住"一个小根整个消失")。
	#      ② **全局下限** `MIN_SCANNED`:防"扫描整体坏掉"。
	#    ★ 两条都在**迭代之前**跑:先证明扫到了东西,再拿扫到的东西下结论。
	#    ★ 文件表**只收一次**并复用(不重复 walk —— 那也是两个判据看到不同世界的窗口)。
	var scanned := ScanUtil.collect(SCAN_DIRS)
	for root in SCAN_DIRS:
		var n := 0
		for p in scanned:
			# 带 "/" 才是**目录**前缀(res://ui 不得匹配到 res://ui_foo)
			if p.begins_with(root + "/"):
				n += 1
		if n == 0:
			fails.append("⑤ 扫描根 %s 一个文件都没扫到(根被改名/搬走?) —— `ScanUtil.walk` 打不开时**静默返回**,本条会无声收窄成假绿" % root)
	if scanned.size() < MIN_SCANNED:
		fails.append("⑤ 只扫到 %d 个源文件(下限 %d)—— 扫描坏掉时零命中是假绿" % [scanned.size(), MIN_SCANNED])
	for path in scanned:
		if LITERAL_ALLOWED.has(path):
			continue
		var raw := ScanUtil.read(path)
		if raw.is_empty():
			fails.append("⑤ 读不到 %s(读不到就是红)" % path)
			continue
		var code := ScanUtil.code_only(raw)
		if _norm(code).contains(PLATE_LITERAL):
			fails.append("⑤ %s 里有游离的底板色字面量(白名单只有调色板与两个 .tscn)" % path)

	# ── ⑥ Theme(.tres):每个 `Color(...)` 字面量必须逐位等于调色板某个 `const C_*` ──
	_check_theme_colors(pal_code, fails)

	if fails.is_empty():
		print("UI PALETTE: ALL-OK")
		quit(0)
	else:
		for f in fails:
			print("  FAIL " + f)
		print("UI PALETTE: FAIL(%d 条)" % fails.size())
		quit(1)


# 取 `code` 里含 `needle` 的那一行的**右值**(`:=` 之后的原文);找不到/没有 `:=` 给 ""。
# ★ 匹配是**整词**的(needle 后面必须紧跟非标识符字符),不是子串 —— 否则日后若出现
#   `const C_PLATE_DIM := ...` 这类**兄弟常量**并排在真身之前,①(以及拿 `plate_rhs` 当期望值的
#   ④)会**静默取到兄弟的右值**:守卫照样打 ALL-OK,而它钉的那个值已经不是源的值了。
func _rhs_of(code: String, needle: String) -> String:
	for l in code.split("\n"):
		var i := l.find(needle)
		if i < 0:
			continue
		var end := i + needle.length()
		# 词界:紧跟其后若是标识符字符(字母/数字/下划线),说明命中的是**兄弟常量**
		# (如 `const C_PLATE_DIM`),不是我们要的那个 —— 跳过,别把它的右值当成源的值。
		# ★ 边界:needle 恰好落在**行尾**时 end == 行长度,取不到字符;越界取字符会打引擎错误
		#   ⇒ 本脚本一行裁决都不打印(只能靠 timeout 看出来)⇒ 必须显式判长度。
		#   那种行没有值可取,落到下面的 `:=` 查找 ⇒ 返回 ""(与原语义一致)。
		if end < l.length() and l[end] in IDENT_CHARS:
			continue
		var j := l.find(":=")
		return "" if j < 0 else l.substr(j + 2).strip_edges()
	return ""


# 取 `.tscn` 原文里**所有** `bg_color = <Color(...)>` 的右值(按出现顺序),并**剔掉 `;` 注释行**。
# ★ 用正则而不是 `split("=")` —— 要容忍空格差异,且 `StyleBoxFlat` 段里还有别的 `=` 行。
# ★★ 为什么这**两件事都不可省**:
#    ① **剔注释** —— 属性行**正上方**就是一条说明注释(`; ... 改底板色必须同步这一行 ...`),
#       而注释不是代码、不受任何约束:它里面一旦出现 `bg_color = ...`,只取首个匹配的实现会读
#       **注释**、真属性漂了也报绿。那种静默漏报正是本守卫存在的理由。
#    ② **全取** —— 两个 `.tscn` 在 ⑤ 里是**整文件白名单** ⇒ 同文件里多出来的第二处 `bg_color`
#       ④(原先只看首个)与 ⑤ 都看不见。全取之后由调用方断言"**恰好一条**":0 条 = 形状变了、
#       多条 = 本守卫看不懂 —— 两种都要红,而不是静默钉住其中一条。
func _tscn_bg_colors(raw: String) -> Array[String]:
	var out: Array[String] = []
	var re := RegEx.create_from_string("bg_color\\s*=\\s*(Color\\([^)]*\\))")
	for line in raw.split("\n"):
		if line.strip_edges().begins_with(";"):
			continue
		for m in re.search_all(line):
			out.append(m.get_string(1))
	return out


# 归一化:去掉所有空白与换行 ⇒ `Color(0,0,0,0.1)` 与 `Color(0, 0, 0, 0.1)` 相等。
func _norm(s: String) -> String:
	return s.replace(" ", "").replace("\t", "").replace("\n", "")


# ── ⑥ Theme 颜色对账 ──
# 读 THEME_SITE 原文,抽出每个 `Color(...)`,断言它**按值**等于调色板里某个 `const C_*`。
# ★ 判据是值、不是文本:.tres 里写的是 `Color(0.105882354, 0.14117648, 0.17254902, 1)`,
#   而调色板源里是 `Color("#1B242C")` —— 逐字比较**恒不相等**,只有解析成 Color 再比才对。
# ★ 两条防空转(缺了它们,读不到/形状变了都会静默 ALL-OK):读不到 ⇒ 红;抽到的数量 < 下限 ⇒ 红。
func _check_theme_colors(pal_code: String, fails: Array[String]) -> void:
	var raw := ScanUtil.read(THEME_SITE)
	if raw.is_empty():
		fails.append("⑥ 读不到 %s(读不到就是红,不是静默跳过)" % THEME_SITE)
		return
	var palette := _palette_colors(pal_code)
	if palette.is_empty():
		fails.append("⑥ 从调色板 %s 解析不出任何 `const C_* := Color(...)`(解析坏了 ⇒ 本条会静默通过)" % PALETTE)
		return
	var re := RegEx.create_from_string("Color\\([^)]*\\)")
	var n := 0
	for m in re.search_all(raw):
		var lit := m.get_string(0)
		var c = _parse_color(lit)
		if c == null:
			fails.append("⑥ %s 里的 `%s` 解析不出颜色(形状变了 ⇒ 本条对这一处失明)" % [THEME_SITE, lit])
			continue
		n += 1
		if not _color_in(c, palette):
			fails.append("⑥ %s 里的 %s 不等于任何调色板常量(Theme 的颜色必须只来自 UiFactory)" % [THEME_SITE, lit])
	if n < THEME_COLOR_MIN:
		fails.append("⑥ %s 里只抽到 %d 个 `Color(...)`(下限 %d)—— 形状变了 / 读坏了时零命中是假绿"
				% [THEME_SITE, n, THEME_COLOR_MIN])


# 从调色板源码里取出所有 `const C_xxx := Color(...)` 的值。
func _palette_colors(code: String) -> Array[Color]:
	var out: Array[Color] = []
	var re := RegEx.create_from_string("const\\s+C_\\w+\\s*:=\\s*(Color\\([^)]*\\))")
	for m in re.search_all(code):
		var c = _parse_color(m.get_string(1))
		if c != null:
			out.append(c)
	return out


# 把一处 `Color(...)` 字面量解析成 Color;解析不了返回 **null**。
# 认两种形状(与调色板/`.tres` 实际用到的写法一致):
#   · `Color("#RRGGBB")` / `Color("#RRGGBBAA")` —— 单实参、十六进制串;
#   · `Color(a, b, c)` / `Color(a, b, c, d)` —— 数值实参,每个允许 `x / y` 算式。
func _parse_color(expr: String) -> Variant:
	var s := expr.strip_edges()
	if not s.begins_with("Color(") or not s.ends_with(")"):
		return null
	var inner := s.substr(6, s.length() - 7)
	var parts := inner.split(",")
	if parts.size() == 1:
		var t := (parts[0] as String).strip_edges()
		if t.begins_with("\"") and t.ends_with("\""):
			return Color(t.substr(1, t.length() - 2))
		return null
	if parts.size() < 3 or parts.size() > 4:
		return null
	var v0 = _eval_num((parts[0] as String).strip_edges())
	var v1 = _eval_num((parts[1] as String).strip_edges())
	var v2 = _eval_num((parts[2] as String).strip_edges())
	if v0 == null or v1 == null or v2 == null:
		return null
	var a := 1.0
	if parts.size() == 4:
		var va = _eval_num((parts[3] as String).strip_edges())
		if va == null:
			return null
		a = va
	return Color(v0, v1, v2, a)


# 求一个数值实参:`"0.1"` / `"99.0 / 255.0"` 这类;算不出返回 null。
func _eval_num(t: String) -> Variant:
	if t.is_valid_float():
		return t.to_float()
	if t.contains("/"):
		var halves := t.split("/")
		var lhs := (halves[0] as String).strip_edges()
		var rhs := (halves[1] as String).strip_edges()
		if halves.size() == 2 and lhs.is_valid_float() and rhs.is_valid_float():
			return lhs.to_float() / rhs.to_float()
	return null


# c 是否按值等于 palette 里任一个(带 COLOR_TOL 容差,见常量注释)。
func _color_in(c: Color, palette: Array[Color]) -> bool:
	for p in palette:
		if (absf(c.r - p.r) <= COLOR_TOL and absf(c.g - p.g) <= COLOR_TOL
				and absf(c.b - p.b) <= COLOR_TOL and absf(c.a - p.a) <= COLOR_TOL):
			return true
	return false
