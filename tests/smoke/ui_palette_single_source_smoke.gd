extends SceneTree

# UI 配色单一数据源完整性校验：
# 源码级静态验证主界面、HUD 及主题样式中的颜色字面量均统一定义于配色配置表，杜绝散落硬编码颜色。
# 运行方式：
#   source tests/env.sh && timeout 120 "$GODOT" --headless --path . -s res://tests/smoke/ui_palette_single_source_smoke.gd

const PALETTE := "res://ui/factory/ui_factory.gd"
# 底板色字面量归一化形态
const PLATE_LITERAL := "Color(0,0,0,0.1)"
# 队伍 A 颜色字面量归一化形态
const TEAM_A_LITERAL := "Color(99.0/255.0,155.0/255.0,1.0)"

# 引用 C_PLATE 的 .gd 脚本位置
const GD_SITES := [
	"res://ui/hud/hud.gd",
	"res://ui/hud/weapon_slots.gd",
	"res://ui/factory/world_label.gd",
	"res://ui/hud/royale_hud.gd",
]
# 包含底板样式的 .tscn 场景文件
const TSCN_SITES := [
	"res://ui/hud/pvp_hud.tscn",
	"res://ui/hud/team_hud.tscn",
]
const BODY_BASE_SITE := "res://scenes/pvp_match_client.gd"

# Theme 资源：内部所有 Color 字面量均须对应调色板中的常量
const THEME_SITE := "res://ui/theme/menu_theme.tres"
const THEME_COLOR_MIN := 20
const COLOR_TOL := 1.0 / 65536.0
# 白名单：允许出现底板色字面量的源文件（调色板自身及场景配置）
const LITERAL_ALLOWED := [PALETTE, "res://ui/hud/pvp_hud.tscn", "res://ui/hud/team_hud.tscn",
		"res://tests/smoke/ui_palette_single_source_smoke.gd"]
const SCAN_DIRS := ["res://ui", "res://scenes", "res://core", "res://server", "res://tests"]
# 标识符字符集
const IDENT_CHARS := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"
const MIN_SCANNED := 250


func _initialize() -> void:
	var fails: Array[String] = []

	# ── ① 唯一源接口已声明且生效,并取出它的值(原文) ──
	var pal_code := ScanUtil.code_only(ScanUtil.read(PALETTE))
	if pal_code.is_empty():
		print("  FAIL ① 读不到 %s(读不到就是红,不是静默跳过)" % PALETTE)
		print("UI PALETTE: FAIL(1 条)")
		quit(1)
		return
	var plate_rhs := _rhs_of(pal_code, "const C_PLATE")
	if plate_rhs == "":
		fails.append("① %s 中未找到 const C_PLATE 定义" % PALETTE)
	elif _norm(plate_rhs) != PLATE_LITERAL:
		fails.append("① C_PLATE 的值与底板色不符(实得「%s」)" % plate_rhs)

	# ── ② 校验 .gd 脚本引用统一源，不留硬编码字面量 ──
	for path in GD_SITES:
		var code := ScanUtil.code_only(ScanUtil.read(path))
		if code.is_empty():
			fails.append("② 读不到 %s" % path)
			continue
		if not code.contains("UiFactory.C_PLATE"):
			fails.append("② %s 未引用 UiFactory.C_PLATE" % path)
		if _norm(code).contains(PLATE_LITERAL):
			fails.append("② %s 中存在硬编码底板色字面量" % path)

	# ── ③ BODY_BASE_COLOR 必须引用 UiFactory.C_TEAM_A ──
	var body := ScanUtil.code_only(ScanUtil.read(BODY_BASE_SITE))
	if body.is_empty():
		fails.append("③ 读不到 %s" % BODY_BASE_SITE)
	else:
		if not body.contains("UiFactory.C_TEAM_A"):
			fails.append("③ %s 的 BODY_BASE_COLOR 未引用 UiFactory.C_TEAM_A" % BODY_BASE_SITE)
		if _norm(body).contains(TEAM_A_LITERAL):
			fails.append("③ %s 中存在硬编码队伍色字面量" % BODY_BASE_SITE)

	# ── ④ 场景文件校验：.tscn 中的 bg_color 与 C_PLATE 逐位相等 ──
	for path in TSCN_SITES:
		var raw := ScanUtil.read(path)
		if raw.is_empty():
			fails.append("④ 读不到 %s" % path)
			continue
		var found := _tscn_bg_colors(raw)
		if found.is_empty():
			fails.append("④ %s 中未找到 bg_color = Color(...) 定义" % path)
			continue
		if found.size() > 1:
			fails.append("④ %s 中存在多处 bg_color 定义(%d 处)" % [path, found.size()])
			continue
		var got := found[0]
		# 缺少基准值时提示比对失败
		if plate_rhs == "":
			fails.append("④ %s 无法比对: 未获取到 C_PLATE 基准值" % path)
		elif _norm(got) != _norm(plate_rhs):
			fails.append("④ %s 的 bg_color 与 C_PLATE 不符(实得「%s」,期望「%s」)"
					% [path, got, plate_rhs])
		if _norm(got) != PLATE_LITERAL:
			fails.append("④ %s 的 bg_color 与底板色不符(实得「%s」)" % [path, got])

	# ── ⑤ 反向扫描：全工程除白名单外禁止出现游离的底板色字面量 ──
	var scanned := ScanUtil.collect(SCAN_DIRS)
	for root in SCAN_DIRS:
		var n := 0
		for p in scanned:
			if p.begins_with(root + "/"):
				n += 1
		if n == 0:
			fails.append("⑤ 扫描目录 %s 未发现有效文件" % root)
	if scanned.size() < MIN_SCANNED:
		fails.append("⑤ 扫描文件数不足(实得 %d, 下限 %d)" % [scanned.size(), MIN_SCANNED])
	for path in scanned:
		if LITERAL_ALLOWED.has(path):
			continue
		var raw := ScanUtil.read(path)
		if raw.is_empty():
			fails.append("⑤ 读不到 %s" % path)
			continue
		var code := ScanUtil.code_only(raw)
		if _norm(code).contains(PLATE_LITERAL):
			fails.append("⑤ %s 中存在未纳入统一管理的底板色字面量" % path)

	# ── ⑥ Theme 资源颜色对账 ──
	_check_theme_colors(pal_code, fails)

	if fails.is_empty():
		print("UI PALETTE: ALL-OK")
		quit(0)
	else:
		for f in fails:
			print("  FAIL " + f)
		print("UI PALETTE: FAIL(%d 条)" % fails.size())
		quit(1)


# 提取 code 中指定常量的右值（:= 之后的字符串）
func _rhs_of(code: String, needle: String) -> String:
	for l in code.split("\n"):
		var i := l.find(needle)
		if i < 0:
			continue
		var end := i + needle.length()
		# 单词边界检查：避免匹配到拥有相同前缀的兄弟常量
		if end < l.length() and l[end] in IDENT_CHARS:
			continue
		var j := l.find(":=")
		return "" if j < 0 else l.substr(j + 2).strip_edges()
	return ""


func _tscn_bg_colors(raw: String) -> Array[String]:
	var out: Array[String] = []
	var re := RegEx.create_from_string("bg_color\\s*=\\s*(Color\\([^)]*\\))")
	for line in raw.split("\n"):
		if line.strip_edges().begins_with(";"):
			continue
		for m in re.search_all(line):
			out.append(m.get_string(1))
	return out


# 字符串空白与换行归一化
func _norm(s: String) -> String:
	return s.replace(" ", "").replace("\t", "").replace("\n", "")


# 校验 Theme 资源中每个 Color 与调色板常量逐项对齐
func _check_theme_colors(pal_code: String, fails: Array[String]) -> void:
	var raw := ScanUtil.read(THEME_SITE)
	if raw.is_empty():
		fails.append("⑥ 读不到 %s(读不到就是红,不是静默跳过)" % THEME_SITE)
		return
	var palette := _palette_colors(pal_code)
	if palette.is_empty():
		fails.append("⑥ 无法从调色板 %s 解析出颜色常量" % PALETTE)
		return
	var re := RegEx.create_from_string("Color\\([^)]*\\)")
	var n := 0
	for m in re.search_all(raw):
		var lit := m.get_string(0)
		var c = _parse_color(lit)
		if c == null:
			fails.append("⑥ %s 中的 %s 无法解析为合法颜色" % [THEME_SITE, lit])
			continue
		n += 1
		if not _color_in(c, palette):
			fails.append("⑥ %s 里的 %s 不等于任何调色板常量(Theme 的颜色必须只来自 UiFactory)" % [THEME_SITE, lit])
	if n < THEME_COLOR_MIN:
		fails.append("⑥ %s 里只抽到 %d 个 Color(...)（下限 %d）"
				% [THEME_SITE, n, THEME_COLOR_MIN])


# 从调色板源码提取所有 C_* 常量
func _palette_colors(code: String) -> Array[Color]:
	var out: Array[Color] = []
	var re := RegEx.create_from_string("const\\s+C_\\w+\\s*:=\\s*(Color\\([^)]*\\))")
	for m in re.search_all(code):
		var c = _parse_color(m.get_string(1))
		if c != null:
			out.append(c)
	return out


# 解析 Color(...) 表达式为 Color 实例
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


# 解析单项数值表达式（支持除法算式）
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
