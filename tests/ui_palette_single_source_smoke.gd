extends SceneTree

# UI 调色板**单一来源**守卫(底板色 + 队色)。纯源码级、`-s` 可跑、不占端口、**不需要渲染**。
#
# 跑法:  source tests/env.sh && timeout 120 "$GODOT" --headless --path . \
#            -s res://tests/ui_palette_single_source_smoke.gd
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
# ★★ **已知的判据上限(登记,别当漏洞)**:本守卫只钉这 **6 处**具名落点 + 一条"全仓再无
#    游离字面量"的反向断言。将来新增第 7 处时,反向断言会红 —— **前提是它写成
#    `Color(0, 0, 0, 0.1)` 字面量**;若写成第三种 `const` 名字,反向断言抓不到。
#    **同一串字面量的等价改写也抓不到**(如 `Color(0.0, 0.0, 0.0, 0.1)`) —— `_norm` 只去空白,
#    **不做数值形态归一**,故 ②/⑤ 是按**字面字符**比对的,不是按颜色值。

const PALETTE := "res://ui/ui_factory.gd"
# 底板色字面量的**归一化后**形态(空白在 `_norm` 里被去掉)。
const PLATE_LITERAL := "Color(0,0,0,0.1)"
# 队 1 token 的重复字面量(改前 `BODY_BASE_COLOR` 就是这个) —— 归一化后。
const TEAM_A_LITERAL := "Color(99.0/255.0,155.0/255.0,1.0)"

# 四个 `.gd` 落点:三处 `const PLATE_COLOR` + 一处内联(`royale_hud._plate_box`)。
const GD_SITES := [
	"res://ui/hud.gd",
	"res://ui/weapon_slots.gd",
	"res://ui/world_label.gd",
	"res://ui/royale_hud.gd",
]
# 两个**结构上无法派生**的落点:`.tscn` 里 StyleBoxFlat 的 bg_color。
const TSCN_SITES := [
	"res://ui/pvp_hud.tscn",
	"res://ui/team_hud.tscn",
]
# 队色那一半。
const BODY_BASE_SITE := "res://scenes/pvp_match_client.gd"
# ⑤ 反向断言的白名单 = 允许出现底板色**字面量**的文件:
#   调色板自己(它就是源)+ 两个 `.tscn`(结构上派生不了)+ **本文件自己**
#   (`PLATE_LITERAL` 这个常量本身就把那串字写在了源码里 —— 不白名单它,⑤ 会自己判自己红)。
const LITERAL_ALLOWED := [PALETTE, "res://ui/pvp_hud.tscn", "res://ui/team_hud.tscn",
		"res://tests/ui_palette_single_source_smoke.gd"]
# ⑤ 扫的目录(生产 + 测试)。
const SCAN_DIRS := ["res://ui", "res://scenes", "res://core", "res://server", "res://tests"]


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
		if plate_rhs == "" or _norm(got) != _norm(plate_rhs):
			fails.append("④ %s 的 `bg_color` 与 `C_PLATE` 不等(实得「%s」,期望「%s」)"
					% [path, got, plate_rhs])
		if _norm(got) != PLATE_LITERAL:
			fails.append("④ %s 的 `bg_color` 不是底板色(实得「%s」)" % [path, got])

	# ── ⑤ 反向:全仓再无**游离**的底板色字面量(白名单见 LITERAL_ALLOWED) ──
	for path in ScanUtil.collect(SCAN_DIRS):
		if LITERAL_ALLOWED.has(path):
			continue
		var raw := ScanUtil.read(path)
		if raw.is_empty():
			fails.append("⑤ 读不到 %s(读不到就是红)" % path)
			continue
		var code := ScanUtil.code_only(raw)
		if _norm(code).contains(PLATE_LITERAL):
			fails.append("⑤ %s 里有游离的底板色字面量(白名单只有调色板与两个 .tscn)" % path)

	if fails.is_empty():
		print("UI PALETTE: ALL-OK")
		quit(0)
	else:
		for f in fails:
			print("  FAIL " + f)
		print("UI PALETTE: FAIL(%d 条)" % fails.size())
		quit(1)


# 取 `code` 里含 `needle` 的那一行的**右值**(`:=` 之后的原文);找不到/没有 `:=` 给 ""。
func _rhs_of(code: String, needle: String) -> String:
	for l in code.split("\n"):
		if not l.contains(needle):
			continue
		var i := l.find(":=")
		return "" if i < 0 else l.substr(i + 2).strip_edges()
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
