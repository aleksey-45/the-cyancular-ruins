extends ProbeBase

const PROD_DIRS := ["res://core", "res://scenes", "res://server", "res://ui"]
# 全仓扫描根(第 3/4 条:字号与退役引用要看整仓,含 tests/)
const ALL_DIRS := ["res://core", "res://scenes", "res://server", "res://ui",
		"res://tests"]

# 扫描到的源文件数下限:防止"扫描根本坏了 -> 一个文件都没扫到 -> 零命中 = 测试漏报"
const MIN_PROD_FILES := 40
const MIN_ALL_FILES := 60


# 探针短名:拼 ALL-OK / FAIL / 汇总行的方括号前缀用(ProbeBase 的必需覆写项)。
func probe_id() -> String:
	return "L4"


func _ready() -> void:
	_check_no_demo_residue()
	_check_feedback_mount_point()
	_check_font_size_law()
	_check_old_escape_menu_retired()
	_check_new_api()
	_check_multi_entry()
	_check_menu_terrain()
	_finish()


func _check_menu_terrain() -> void:
	var menu := _code_only(_read("res://scenes/main_menu.gd"))
	_check(not menu.is_empty(), "读不到 scenes/main_menu.gd")
	var want := "TerrainAtlas." + "terrain_texture("
	_check(menu.count(want) >= 1,
			"主菜单背景必须走 %s(真实地形图);没找到 —— 怕是退回了简略色块图" % want)
	var banned := "MapCatalog." + "build_image("
	_check(menu.count(banned) == 0,
			"主菜单不该再调 %s(选图面板的示意缩略图:每格一个平色,放大多少都不是那个世界)" % banned)
	# 提取后的 Level0:图集构造必须只剩 TerrainAtlas 一处(回退成内联 = 又出现第二个真相源)
	var lvl := _code_only(_read("res://scenes/level_0.gd"))
	_check(not lvl.is_empty(), "读不到 scenes/level_0.gd")
	_check(lvl.count("TerrainAtlas." + "make_wall_tileset()") >= 1
			and lvl.count("TerrainAtlas." + "make_water_tileset(") >= 1,
			"Level0 的墙体/水体图集必须来自 TerrainAtlas(构造已上提,别再内联一份)")
	# 底色单一来源:菜单与对局的清屏色必须是同一个常量,不许各写一份字面量
	_check(lvl.count("TerrainAtlas." + "SKY_COLOR") >= 1,
			"Level0 的清屏色必须读 TerrainAtlas.SKY_COLOR(与菜单背景同源)")
	_check(not lvl.contains("b0e5f6") and not menu.contains("b0e5f6"),
			"底色不许再写字面量 #b0e5f6(必须走 TerrainAtlas.SKY_COLOR 单一来源)")
	print("[L4] 菜单背景:真实地形接线在位(%s),缩略图入口 %d 处" % [want, menu.count(banned)])


# ── 1) -  零演示残留(只扫生产目录)────────────────────────────────────
# L4 把"主菜单背后挂一个真 Level0 演示世界"整条链退役了。留下来就是成本与风险:
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


# ── 2) -  打击反馈层唯一挂载点(生产路径恰好 1 处)─────────────────────
# L2 修过的洞:CombatFeedback.current 必须由对局世界创建一次。多一处(比如菜单又建
# 一个) -> 两份反馈层抢 current;少一处 -> 击杀播报/命中标记全哑。另:调用点必须留在
# _ready 顶部、建图之前(carry-forward 1:世界构建可能提前返回,反馈层不该被它带着一起跳过)。
func _check_feedback_mount_point() -> void:
	var files := _collect(PROD_DIRS)
	var needle := "Combat" + "Feedback.spawn("
	var hits: Array[String] = []
	for f in files:
		var n := _code_only(_read(f)).count(needle)
		for _i in range(n):
			hits.append(f)
	_check(hits.size() == 1,
			"打击反馈层挂载点在生产路径应恰好 1 处(实际 %d): %s" % [hits.size(), ", ".join(hits)])
	if hits.size() == 1:
		_check(hits[0] == "res://scenes/level_0.gd",
				"唯一挂载点应是 res://scenes/level_0.gd(实际 %s)" % hits[0])
	var lv := _top_func_body(_code_view(_read("res://scenes/level_0.gd")), "_ready")
	var i_spawn := lv.find(needle)
	var i_world := lv.find("World" + "Builder.load_grid()")
	if i_spawn < 0 or i_world < 0:
		_failures.append("位置断言前置不足:spawn=%d world=%d(源码里找不到?)" % [i_spawn, i_world])
	else:
		_check(i_spawn < i_world,
				"打击反馈层挂载点被挪到了建图之后(应留在 _ready 顶部;建图早退会连它一起跳过)")
	print("[L4] 打击反馈挂载点:命中 %d 处" % hits.size())


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
		for m in re.search_all(_code_only(_read(f))):
			var v := int(m.get_string(1))
			if v % 16 != 0:
				bad.append("%s: 字号 %d(行首近处「%s」)" % [f, v, m.get_string(0).strip_edges()])


# C) const 常量声明扫描: 匹配 const ...FONT_SIZE... 声明语句
func _scan_const_decl(files: Array[String], bad: Array[String]) -> void:
	var needle := "FONT" + "_SIZE"
	var re := RegEx.new()
	re.compile("^\\s*const\\s+\\w*" + needle + "\\w*\\s*:?=\\s*([0-9]+)")
	for f in files:
		var src := _code_only(_read(f))
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
# 跳过 —— 它们的值由 C) 那条常量表提供容错保障。
func _scan_call_arg(files: Array[String], needle: String, arg_index: int,
		bad: Array[String], label: String) -> void:
	for f in files:
		var src := _code_only(_read(f))
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
	# 替身必须接口已声明且生效
	var pm := "res://ui/screens/pause_menu.gd"
	_check(ResourceLoader.exists(pm), "替身 %s 不存在" % pm)
	var pm_src := _read(pm)
	_check(pm_src.contains("class_name " + "Pause" + "Menu"), "%s 缺 class_name PauseMenu" % pm)
	var pm_gs := load(pm) as GDScript
	_check(pm_gs != null, "%s 载入失败(下面三个口无从判)" % pm)
	if pm_gs != null:
		for _fn in ["open", "close", "go_menu"]:
			_check(_method_info(pm_gs, _fn) != null, "%s 缺 %s 口" % [pm, _fn])
	print("[L4] 退役 ESC 菜单:扫 %d 个源文件,代码引用 %d 处" % [files.size(), hits.size()])


func _check_new_api() -> void:
	var lv_path := "res://scenes/level_0.gd"
	var lv := load(lv_path) as GDScript
	_check(lv != null, "载入 %s 失败" % lv_path)
	if lv != null:
		var m: Variant = _method_info(lv, "safe_change_scene")
		_check(m != null, "Level0 的方法表里没有 safe_change_scene")
		if m != null:
			_check(int(m.get("flags", 0)) & METHOD_FLAG_STATIC != 0,
					"Level0.safe_change_scene 不是 static(flags=%d)" % int(m.get("flags", 0)))
	var specs := [
		[lv_path, "restart_single"],
		["res://scenes/player/player.gd", "restart_at"],
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
	print("[L4] 新接口:Level0.safe_change_scene(static)/restart_single、Player.restart_at、WeaponComponent.reset_mag_state 全部在位")


func _check_multi_entry() -> void:
	var src := _read("res://scenes/main_menu.gd")
	_check(not src.is_empty(), "读不到 scenes/main_menu.gd")
	var needle := "res://scenes/" + "mp_" + "lobby.tscn"
	var n := _code_only(src).count(needle)
	_check(n == 1, "主菜单联机入口应恰好 1 处指向 %s(实际 %d 处)" % [needle, n])
	# 悬空引用防御性校验:这条的动机正是不让菜单指向不存在的场景(按钮点了没反应 = 假入口)。
	# 只数字符串会把「场景被删/改名」读成绿 —— 必须让路径本身可解析
	# (同 _check_old_escape_menu_retired 里 ResourceLoader.exists 的用法)。
	_check(ResourceLoader.exists(needle), "联机入口指向的场景 %s 不存在(悬空引用)" % needle)
	print("[L4] 主菜单联机入口:命中 %d 处(%s)" % [n, needle])


# ── 工具 ────────────────────────────────────────────────────────────
func _demo_needles() -> Array[String]:
	# 碎片拼接:见文件头「防止测试脚本字面量自匹配」
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
