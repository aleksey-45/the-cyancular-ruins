extends Node

# KH 合并 L4 验收探针(场景模式:autoload 必须已实例化,不能用 -s 跑)。
# 跑法:
#   "$GODOT" --headless --path . --quit-after 600 res://tests/kh_l4_probe.tscn
# 期望:打印 "KH L4 PROBE: ALL-OK" 且退出码 0。
#
# 存在理由:L4(菜单/暂停层换装 + 演示世界退役 + 退役 esc_menu + 「倒地按 R 原地重启」)
# 的验收项大多是**"某样东西从此不存在"**或**"某样东西只剩一处"**——这类断言没有运行时
# 入口,只能在源码层机械扫描。本探针就是那台扫描仪:
#   1) ★ 零演示残留(生产目录 .gd/.tscn 不含 menu demo / revive demo / demo level0 /
#      demo spawn / build_permanent_region / enter_game_staged / leave_menu / MenuDemoAi /
#      --demo-noai / DemoCollision —— 共 10 条针,见 _demo_needles)
#   2) ★ 打击反馈层挂载点全仓生产路径恰好 1 处,且必须是 scenes/level_0.gd
#   3) ★ 字号规范:全仓所有字号载体都是 16 的倍数(见下方四类载体)
#   4) 退役的 ESC 菜单零引用(类不存在、文件不存在、无代码引用)
#   5) L4 新接口在位(Level0.safe_change_scene 必须 static / restart_single /
#      Player.restart_at / WeaponComponent.refill_current_weapon+reset_mag_state)
#   6) 主菜单的大乱斗入口恰 1 处且指向 royale_lobby.tscn(L4 约束 2 已到期反转:
#      L4 那版是「零 royale 字样」,L5 连场景一起加后改为正向钉「必须恰有 1 个入口」)
#
# --quit-after 是安全网:本脚本引用 Level0 等 autoload 标识符;若某个 autoload 被删掉,
# 脚本编译失败 → 场景根节点无脚本 → 一行都不打印、命令挂死。有它最坏只是超时退出。
#
# ⚠ CI 判据必须是 **grep 文本 `KH L4 PROBE: ALL-OK`**,不能只看退出码:
#    探针中途脚本报错(解析失败/函数中断)时 --quit-after 仍会以 exit 0 退出,
#    且**不会**打印 ALL-OK(也不打 FAIL)——只看退出码会把"没跑完"读成"通过"。
#
# ⚠⚠ 自伤防护(本文件被自己扫描,务必守住):凡是本探针**要找的字面量**,一律用
#    `"前" + "后"` 碎片拼出来,绝不整段写在源码里 —— 否则:
#      · 演示残留/esc 这类"零命中"断言会被本文件自己命中(假红);
#      · 字号那类"扫字面量"的断言也会把本文件里的示例当数据。
#    `tests/` 只在第 1 条里被排除(那条扫描根就不含它),3/4 两条是**全仓**扫描,含本文件。

# 生产目录(第 1/2 条只扫这些;排除 tests/ 以免探针自身的负断言文本自伤)
const PROD_DIRS := ["res://core", "res://scenes", "res://server", "res://ui", "res://render"]
# 全仓扫描根(第 3/4 条:字号与退役引用要看整仓,含 tests/)
const ALL_DIRS := ["res://core", "res://scenes", "res://server", "res://ui",
		"res://render", "res://tests"]

# 扫描到的源文件数下限:防止"扫描根本坏了 → 一个文件都没扫到 → 零命中 = 假绿"
const MIN_PROD_FILES := 40
const MIN_ALL_FILES := 60

var _failures: Array[String] = []


func _ready() -> void:
	_check_no_demo_residue()
	_check_feedback_mount_point()
	_check_font_size_law()
	_check_old_escape_menu_retired()
	_check_new_api()
	_check_royale_entry()
	_finish()


# ── 1) ★ 零演示残留(只扫生产目录)────────────────────────────────────
# L4 把"主菜单背后挂一个真 Level0 演示世界"整条链退役了。留下来就是**成本与风险**:
# 演示世界要建全量碰撞、要吃 MenuDemoAi 的注入式手柄、还要在进出菜单时反复建/拆大世界
# (实测偶发原生段错误)。这条断言保证它不会被"为了好看"再搬回来。
func _check_no_demo_residue() -> void:
	var files := _collect(PROD_DIRS)
	_check(files.size() >= MIN_PROD_FILES,
			"演示残留扫描:只收到 %d 个生产源文件(扫描根坏了?期望 ≥%d)" % [files.size(), MIN_PROD_FILES])
	var hits: Array[String] = []
	for f in files:
		var low := _read(f).to_lower()
		for needle in _demo_needles():
			if low.contains(needle):
				hits.append("%s ← %s" % [f, needle])
	_check(hits.is_empty(), "演示世界残留 %d 处: %s" % [hits.size(), ", ".join(hits)])
	print("[L4] 零演示残留:扫 %d 个生产源文件,命中 %d" % [files.size(), hits.size()])


# ── 2) ★ 打击反馈层唯一挂载点(生产路径恰好 1 处)─────────────────────
# L2 修过的洞:CombatFeedback.current 必须由**对局世界**创建一次。多一处(比如菜单又建
# 一个)→ 两份反馈层抢 current;少一处 → 击杀播报/命中标记全哑。另:调用点必须留在
# _ready 顶部、建图之前(carry-forward 1:世界构建可能早退,反馈层不该被它带着一起跳过)。
func _check_feedback_mount_point() -> void:
	var files := _collect(PROD_DIRS)
	var needle := "Combat" + "Feedback.spawn("
	var hits: Array[String] = []
	for f in files:
		var n := _read(f).count(needle)
		for _i in range(n):
			hits.append(f)
	_check(hits.size() == 1,
			"打击反馈层挂载点在生产路径应恰好 1 处(实际 %d): %s" % [hits.size(), ", ".join(hits)])
	if hits.size() == 1:
		_check(hits[0] == "res://scenes/level_0.gd",
				"唯一挂载点应是 res://scenes/level_0.gd(实际 %s)" % hits[0])
	# 位置:必须在 WorldBuilder.load_grid() 之前(_ready 顶部;建图失败会 push_error 早退)
	var lv := _read("res://scenes/level_0.gd")
	var i_spawn := lv.find(needle)
	var i_world := lv.find("World" + "Builder.load_grid()")
	if i_spawn < 0 or i_world < 0:
		_failures.append("位置断言前置不足:spawn=%d world=%d(源码里找不到?)" % [i_spawn, i_world])
	else:
		_check(i_spawn < i_world,
				"打击反馈层挂载点被挪到了建图之后(应留在 _ready 顶部;建图早退会连它一起跳过)")
	print("[L4] 打击反馈挂载点:命中 %d 处" % hits.size())


# ── 3) ★ 字号规范:全仓所有字号载体都是 16 的倍数 ─────────────────────
# 本项目的像素字体(less_perfect_dos_vga)只在 16 的整数倍下与渲染缩放整数对齐,
# 非 16 倍数会糊 —— 这是 ui/ui_factory.gd 文件头写下的硬约定,必须**机械可查**。
# 四类载体(前三类是 brief 点名的,第四类是被 KH 菜单大量使用的实际载体,漏了它等于没扫):
#   A) add_theme_font_size_override("…", N) 的最后一个实参(含 normal_/bold_font_size 键)
#   B) 字面赋值 `...font_size = N`(.tscn 的 theme_override_font_sizes/font_size = N 走这条)
#   C) `const …FONT_SIZE… := N` 这类常量(世界空间文本/ HUD 走这条,没有 A/B 可查)
#   D) UiFactory 的 label/button/style_control 的字号实参 + WeaponComponent.make_weapon_check
#      —— 全仓菜单控件的字号**都是**从这几个口进去的,是最大的一类载体。
func _check_font_size_law() -> void:
	var files := _collect(ALL_DIRS)
	_check(files.size() >= MIN_ALL_FILES,
			"字号扫描:只收到 %d 个源文件(期望 ≥%d)" % [files.size(), MIN_ALL_FILES])
	var bad: Array[String] = []
	_scan_theme_override(files, bad)
	_scan_literal_assign(files, bad)
	_scan_const_decl(files, bad)
	_scan_factory_arg(files, bad)
	_check(bad.is_empty(), "字号规范违例 %d 处(必须 16 的倍数): %s" % [bad.size(), "; ".join(bad)])
	print("[L4] 字号规范:扫 %d 个源文件,违例 %d 处" % [files.size(), bad.size()])


# A) add_theme_font_size_override(键, N):取最后一个实参
func _scan_theme_override(files: Array[String], bad: Array[String]) -> void:
	_scan_call_arg(files, "add_theme" + "_font_size_override(", -1, bad, "字号覆盖调用")


# D) 控件工厂的字号实参(第 1 个实参;make_weapon_check 是第 2 个)
func _scan_factory_arg(files: Array[String], bad: Array[String]) -> void:
	var factory := "Ui" + "Factory."
	for m in ["label", "button", "style_control"]:
		_scan_call_arg(files, factory + m + "(", 1, bad, "控件工厂 " + m + "()")
	_scan_call_arg(files, "make_weapon" + "_check(", 2, bad, "武器剪刻格的字号实参")


# B) 字面赋值:任何以「…font_size = 数字」出现的行(.gd 与 .tscn 共用一条)
func _scan_literal_assign(files: Array[String], bad: Array[String]) -> void:
	var re := RegEx.new()
	re.compile("font" + "_size\\s*=\\s*([0-9]+)")
	for f in files:
		for m in re.search_all(_read(f)):
			var v := int(m.get_string(1))
			if v % 16 != 0:
				bad.append("%s: 字号 %d(行首近处「%s」)" % [f, v, m.get_string(0).strip_edges()])


# C) const 常量声明:形如 `const …FONT_SIZE… := 数字` / `= 数字`
func _scan_const_decl(files: Array[String], bad: Array[String]) -> void:
	var needle := "FONT" + "_SIZE"
	var re := RegEx.new()
	re.compile("^\\s*const\\s+\\w*" + needle + "\\w*\\s*:?=\\s*([0-9]+)")
	for f in files:
		var src := _read(f)
		for line in src.split("\n"):
			var l: String = line
			if not l.strip_edges().begins_with("const") or not l.contains(needle):
				continue
			var m := re.search(l)
			if m == null:
				bad.append("%s: const 字号声明读不出数值「%s」" % [f, l.strip_edges()])
				continue
			var v := int(m.get_string(1))
			if v % 16 != 0:
				bad.append("%s: const 字号 %d(「%s」)" % [f, v, l.strip_edges()])


# 通用:扫 needle 调用,取第 arg_index 个实参(0 基;arg_index < 0 = 检查全部实参)。
# 是纯整数字面量就查 16 的倍数;变量实参(如 style_control(x, WEAPON_FONT_SIZE))一律
# 跳过 —— 它们的值由 C) 那条常量表兜住。
func _scan_call_arg(files: Array[String], needle: String, arg_index: int,
		bad: Array[String], label: String) -> void:
	for f in files:
		var src := _read(f)
		var from := 0
		while true:
			var i := src.find(needle, from)
			if i < 0:
				break
			from = i + needle.length()
			var open := src.find("(", i + needle.length() - 1)
			if open < 0:
				break
			var close := _match_paren(src, open)
			if close < 0:
				break
			var args := _split_args(src.substr(open + 1, close - open - 1))
			var idxs: Array = range(args.size()) if arg_index < 0 else [arg_index]
			for k in idxs:
				if int(k) >= args.size():
					continue
				var a: String = args[int(k)].strip_edges()
				if not a.is_valid_int():
					continue
				var v := int(a)
				if v % 16 != 0:
					bad.append("%s: %s 第 %d 个实参 = %d(「%s」)" % [f, label, int(k), v, needle])


# 与 open 处 '(' 配对的 ')' 下标(跳过字符串内的括号;找不到返回 -1)
func _match_paren(src: String, open: int) -> int:
	var depth := 0
	var in_str := false
	for j in range(open, src.length()):
		var ch := src[j]
		if in_str:
			if ch == "\\":
				continue
			if ch == "\"":
				in_str = false
			continue
		if ch == "\"":
			in_str = true
		elif ch == "(":
			depth += 1
		elif ch == ")":
			depth -= 1
			if depth == 0:
				return j
	return -1


# 顶层逗号切分实参(括号/方括号/花括号内、字符串内的逗号不算分隔符)
func _split_args(s: String) -> Array[String]:
	var out: Array[String] = []
	var depth := 0
	var in_str := false
	var cur := ""
	for j in range(s.length()):
		var ch := s[j]
		if in_str:
			cur += ch
			if ch == "\"" and (j == 0 or s[j - 1] != "\\"):
				in_str = false
			continue
		match ch:
			"\"":
				in_str = true
				cur += ch
			"(", "[", "{":
				depth += 1
				cur += ch
			")", "]", "}":
				depth -= 1
				cur += ch
			",":
				if depth == 0:
					out.append(cur)
					cur = ""
				else:
					cur += ch
			_:
				cur += ch
	if not cur.strip_edges().is_empty():
		out.append(cur)
	return out


# ── 4) 退役的 ESC 菜单零引用 ─────────────────────────────────────────
# L4 用 ui/pause_menu.gd(PauseMenu,单机暂停树 / PvP 只弹层+断连)替掉了原来的 esc_menu。
# 判据取**代码视图**(剥掉整行注释):pvp_client.gd 里有两行"旧 EscMenu 靠 X 挡"的**历史
# 注释**,那是解释设计动机的,不是引用;把它们算成引用会让这条断言永远红。
func _check_old_escape_menu_retired() -> void:
	var cls := "Esc" + "Menu"
	var low := "esc_" + "menu"
	var files := _collect(ALL_DIRS)
	var hits: Array[String] = []
	for f in files:
		var code := _code_only(_read(f)).to_lower()
		if code.contains(cls.to_lower()):
			hits.append("%s ← %s" % [f, cls])
		if code.contains(low):
			hits.append("%s ← %s" % [f, low])
	_check(hits.is_empty(), "退役 ESC 菜单仍有代码引用 %d 处: %s" % [hits.size(), ", ".join(hits)])
	_check(not ResourceLoader.exists("res://ui/" + low + ".gd"), "退役的 ui/%s.gd 文件还在" % low)
	# 全局类缓存里也不该再有这个类(文件删了但 project.godot/.godot 缓存没刷的话,这里会红)
	for entry in ProjectSettings.get_global_class_list():
		if str(entry.get("class", "")) == cls:
			_failures.append("全局类缓存里仍有 %s(来自 %s)" % [cls, str(entry.get("path", ""))])
	# 替身必须在位
	var pm := "res://ui/pause_menu.gd"
	_check(ResourceLoader.exists(pm), "替身 %s 不存在" % pm)
	var pm_src := _read(pm)
	_check(pm_src.contains("class_name " + "Pause" + "Menu"), "%s 缺 class_name PauseMenu" % pm)
	_check(pm_src.contains("func open(") and pm_src.contains("func close(") \
			and pm_src.contains("func go_menu("), "%s 缺 open/close/go_menu 三个口" % pm)
	print("[L4] 退役 ESC 菜单:扫 %d 个源文件,代码引用 %d 处" % [files.size(), hits.size()])


# ── 5) L4 新接口在位 ────────────────────────────────────────────────
# 这些口是 L4 的交付内容本身(A 阶段评审逐条点过名),缺一个就有调用方会编译不过:
#   Level0.safe_change_scene —— 必须是 **static**:调用方之一是菜单里的 PauseMenu(那时
#     场上是游戏世界退役后的新场景/甚至无 Level0 实例),实例方法在那儿根本调不到。
#   Level0.restart_single(单人倒地按 R 的原地复位)、Player.restart_at(回出生点+满血满氧+
#     武器回默认槽)、WeaponComponent.refill_current_weapon / reset_mag_state(复活满弹;
#     refill 必须 deferred,见其注释:要在 _restore_mag 之后写才不被覆盖)。
func _check_new_api() -> void:
	var lv_path := "res://scenes/level_0.gd"
	var lv := load(lv_path) as GDScript
	_check(lv != null, "载入 %s 失败" % lv_path)
	if lv != null:
		_check(_code_only(_read(lv_path)).contains("static func safe_change_scene("),
				"%s 里没有 `static func safe_change_scene(`(PauseMenu 调不到实例方法)" % lv_path)
		var m: Variant = _method_info(lv, "safe_change_scene")
		_check(m != null, "Level0 的方法表里没有 safe_change_scene")
		if m != null:
			_check(int(m.get("flags", 0)) & METHOD_FLAG_STATIC != 0,
					"Level0.safe_change_scene 不是 static(flags=%d)" % int(m.get("flags", 0)))
	var specs := [
		[lv_path, "restart_single"],
		["res://scenes/player/player.gd", "restart_at"],
		["res://scenes/player/weapon_component.gd", "refill_current_weapon"],
		["res://scenes/player/weapon_component.gd", "reset_mag_state"],
	]
	for spec in specs:
		var path: String = spec[0]
		var name: String = spec[1]
		var gs := load(path) as GDScript
		if gs == null:
			_failures.append("载入 %s 失败" % path)
			continue
		if _method_info(gs, name) == null:
			_failures.append("%s 缺方法 %s" % [path, name])
	# 组件边界:复活的"满弹"不许绕过组件去直接摸私有状态
	_check(_read("res://scenes/player/weapon_component.gd").contains("_refill_mag.call_deferred("),
			"weapon_component.refill_current_weapon 未用 call_deferred(会被 _restore_mag 覆盖 = 复活不满弹)")
	print("[L4] 新接口:Level0.safe_change_scene(static)/restart_single、Player.restart_at、WeaponComponent.refill_current_weapon+reset_mag_state 全部在位")


# ── 6) 主菜单的大乱斗入口:L4 约束 2 的到期日已到(断言反转)───────────
# L4 那版这条断言是「零 royale 字样」,理由写在 L4 硬约束 2 里:**那时 royale_lobby.tscn
# 还不存在**,菜单先加按钮就是悬空引用(点了没反应的按钮 = 假入口),所以约定
# 「L4 加了就是悬空引用,L5 连场景一起加」。L5 已把场景与按钮一起落地,断言随之反转:
# 不再是「不许有」,而是**必须恰好有 1 处、且指向 royale_lobby.tscn**——入口漏加/被删
# (0 处)或指向别处(路径写错、指回已退役场景)都算红。反向约束与正向约束一样是约束,
# 删掉这条就等于把入口的存在性放空。
# 判据取**场景路径**而不是 royale 字样:实现里还有 PvpSession.royale 这类标识符,
# 数字样会连带命中、数不准;数「指向该场景的字符串」才等于数「入口个数」。
func _check_royale_entry() -> void:
	var src := _read("res://scenes/main_menu.gd")
	_check(not src.is_empty(), "读不到 scenes/main_menu.gd")
	var needle := "res://scenes/" + "roy" + "ale" + "_lobby.tscn"
	var n := src.count(needle)
	_check(n == 1, "主菜单大乱斗入口应恰好 1 处指向 %s(实际 %d 处)" % [needle, n])
	# 悬空引用守卫:L4 那条「零 royale 字样」的动机正是**不让菜单指向不存在的场景**(按钮
	# 点了没反应 = 假入口)。只数字符串会把「场景被删/改名」读成绿 —— 必须让路径本身可解析
	# (同 _check_old_escape_menu_retired 里 ResourceLoader.exists 的用法)。
	_check(ResourceLoader.exists(needle), "大乱斗入口指向的场景 %s 不存在(悬空引用)" % needle)
	print("[L4] 主菜单大乱斗入口:命中 %d 处(%s)" % [n, needle])


# ── 工具 ────────────────────────────────────────────────────────────
func _demo_needles() -> Array[String]:
	# 碎片拼接:见文件头「自伤防护」
	return [
		"menu" + "_demo",
		"revive" + "_demo",
		"_demo" + "_level0",
		"_demo" + "_spawn",      # 演示世界布点(与 _demo_level0 一起被删;曾单独存活)
		"build_permanent" + "_region",
		"enter_game" + "_staged",
		"leave" + "_menu",       # 演示世界里的"离开菜单"入口(退役后不该再有任何实现)
		"menudemo" + "ai",
		"demo" + "-noai",        # 启动参数开关(头两条针扫不到命令行长串)
		"demo" + "collision",    # 演示世界的独立碰撞层类名
	]


# 递归收集 roots 下所有 .gd / .tscn(跳过点目录;.git/.godot/.superpowers 都在其中)
func _collect(roots: Array) -> Array[String]:
	var out: Array[String] = []
	for r in roots:
		_walk(r, out)
	out.sort()
	return out


func _walk(dir_path: String, out: Array[String]) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if not name.begins_with("."):
			var p := dir_path.path_join(name)
			if d.current_is_dir():
				_walk(p, out)
			elif name.ends_with(".gd") or name.ends_with(".tscn"):
				out.append(p)
		name = d.get_next()
	d.list_dir_end()


func _read(path: String) -> String:
	if not ResourceLoader.exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_as_text() if f != null else ""


# 剥掉整行注释(允许缩进;GDScript 用 #)。供"零引用"类断言用:历史注释讲的是动机,
# 不是引用 —— 与 kh_l3_probe._code_only 同一做法。
func _code_only(src: String) -> String:
	var out: Array[String] = []
	for line in src.split("\n"):
		var s: String = (line as String).strip_edges()
		if s.is_empty() or s.begins_with("#"):
			continue
		out.append(s)
	return "\n".join(out)


# 脚本方法表里找方法(返回 null = 没有)。用方法表而非文本 contains:
# 函数名出现在注释/字符串里时文本法会假绿。
func _method_info(gs: GDScript, name: String) -> Variant:
	for m in gs.get_script_method_list():
		if str(m.get("name", "")) == name:
			return m
	return null


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_failures.append(msg)


func _finish() -> void:
	if _failures.is_empty():
		print("KH L4 PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("KH L4 PROBE: FAIL | " + "; ".join(_failures))
		get_tree().quit(1)
