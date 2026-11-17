extends SceneTree

# 显示分辨率适配守卫(纯逻辑,`-s` headless,**不真开窗**)。
# 守护 core/config/settings.gd 的 DISPLAY_RESOLUTIONS / fit_resolution()(契约 .tmp/ui-system-contract.md §5):
#   ① 在档位里选能放进可用区的最大 4:3 档;
#   ② 一档都放不下时按可用区等比缩成 4:3 窗口,**绝不超屏**(1366×768 / 1280×720 / 800×600 这类屏);
#   ③ 表增补 1024×768 / 1152×864 小屏档,且全表 4:3;
#   ④ 旧 settings.cfg 的 display/res_index 是**旧四档表**下标 ⇒ 读档先按旧表还原分辨率再查新表
#      (否则旧 2=1920×1440 会静默变成新 2=1280×960);新键 display/resolution 优先。
# 去掉什么会红:
#   - fit_resolution 退回「smallest 兜底」⇒ 小屏可用区(1280×720 / 800×600)的「≤ available」与 exact 红;
#   - 忘加小屏档 / 表被抄成第二份 ⇒ has(1024×768) / has(1152×864) / size==6 / default 在表里 红;
#   - 回退公式漏 4:3 或漏整数化 ⇒ 等比断言与 exact 红;
#   - 表里混进非 4:3 档 ⇒ 全表 4:3 红;
#   - 读档不认旧四档表 / 新键不优先 / 越界不回退默认 ⇒ ⑨ 组红;
#   - 存档不写新键或旧键写成新表下标(降级后错档)⇒ ⑨ 组末尾红。
# ★ 期望值来自契约 §5 的手算(最大拟合档 / 等比 4:3)与旧四档表顺序,不复用被测函数的返回值。
# ★ 只写临时 user://_display_resolution_smoke.cfg(结束删除),**不碰**真实 user://settings.cfg。

const EXPECTED_CHECKS := 59
const TMP_CFG := "user://_display_resolution_smoke.cfg"

# [可用区, 期望窗口]:能放下某档 ⇒ 该档(最大);一档都放不下 ⇒ 手算的等比 4:3 窗口。
const CASES := [
	[Vector2i(1366, 768), Vector2i(1024, 768)],   # 放得下 1024×768(高恰好)
	[Vector2i(1280, 720), Vector2i(960, 720)],    # 一档都放不下 ⇒ 等比 4:3
	[Vector2i(1024, 768), Vector2i(1024, 768)],   # 恰好最小档
	[Vector2i(1600, 900), Vector2i(1152, 864)],   # 放得下 1152×864,放不下 1280×960(高)
	[Vector2i(1920, 1080), Vector2i(1280, 960)],  # 放得下 1280×960,放不下 1600×1200
	[Vector2i(1800, 1400), Vector2i(1600, 1200)], # 放得下 1600×1200,放不下 1920×1440(宽)
	[Vector2i(2560, 1600), Vector2i(1920, 1440)], # 1920×1440 也放得下 ⇒ 最大档是它(不是 1600×1200)
	[Vector2i(3840, 2160), Vector2i(2560, 1920)],
	[Vector2i(800, 600), Vector2i(800, 600)],     # 一档都放不下 ⇒ 恰好等比铺满
	[Vector2i(1000, 700), Vector2i(932, 699)],    # 回退整数化:宽取 4 的倍数 ⇒ 严格 4:3(933×699 会差 1px 出黑边)
	[Vector2i(700, 480), Vector2i(640, 480)],     # 回退下限 640×480(仍 ≤ 可用区)
]

var _fails: Array[String] = []
var _checks := 0


func _chk(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_fails.append(msg)
		print("  ✗ " + msg)


func _is_4_3(r: Vector2i) -> bool:
	return r.x * 3 == r.y * 4


func _fits(r: Vector2i, available: Vector2i) -> bool:
	return r.x <= available.x and r.y <= available.y


func _initialize() -> void:
	# ★ 空载守卫(仓规):load() 失败还往下走会在 null 上抛错,而 `-s` 抛错走不到 quit() ⇒ 进程永久挂起。
	var script := load("res://core/config/settings.gd")
	if script == null or not script.can_instantiate():
		# can_instantiate:脚本解析失败时 load() 可能仍返回一个不可实例化的 GDScript(只判 null 会漏)。
		print("DISPLAY RESOLUTION SMOKE: FAIL | 空载守卫 load(settings.gd) 为 null 或不可实例化")
		quit(1)
		return
	var s = script.new()   # 不标 Node:纯逻辑实例上按动态调用 fit_resolution()/迁移纯函数(Settings 无 class_name)
	if s == null:
		print("DISPLAY RESOLUTION SMOKE: FAIL | settings 实例化失败")
		quit(1)
		return
	for m in ["fit_resolution", "_legacy_index_to_res", "_res_to_index", "_res_index_from_config",
			"save", "load_settings"]:
		if not s.has_method(m):
			print("DISPLAY RESOLUTION SMOKE: FAIL | settings 实例缺 %s()" % m)
			s.free()
			quit(1)
			return

	# ── 表本身:六档、全 4:3、含新小屏档、默认档仍在表内(默认索引靠 find)──
	var consts: Dictionary = script.get_script_constant_map()
	var tiers: Array = consts.get("DISPLAY_RESOLUTIONS", [])
	var default_res: Vector2i = consts.get("DEFAULT_DISPLAY_RESOLUTION", Vector2i.ZERO)
	_chk(tiers.has(Vector2i(1024, 768)), "表应含小屏档 1024×768(实得 %s)" % str(tiers))
	_chk(tiers.has(Vector2i(1152, 864)), "表应含小屏档 1152×864(实得 %s)" % str(tiers))
	_chk(tiers.size() == 6, "表应为六档(原四档 + 两个小屏档;实得 %d)" % tiers.size())
	var all_43 := not tiers.is_empty()
	for t in tiers:
		if not (t is Vector2i):
			all_43 = false
			break
		var v: Vector2i = t
		if not _is_4_3(v):
			all_43 = false
	_chk(all_43, "表里每一档都必须是 4:3(实得 %s)" % str(tiers))
	_chk(tiers.has(default_res), "默认档 %s 必须在表内(否则 display_res_index 会是 -1)" % str(default_res))

	# ── 每个可用区:不超屏 + 严格 4:3 + 期望值(最大拟合档 / 手算等比)──
	for c in CASES:
		var available: Vector2i = c[0]
		var expected: Vector2i = c[1]
		var got: Vector2i = s.fit_resolution(available)
		_chk(_fits(got, available),
				"可用区 %s:结果 %s 必须 ≤ 可用区(绝不超屏)" % [str(available), str(got)])
		_chk(_is_4_3(got),
				"可用区 %s:结果 %s 必须严格 4:3(否则 aspect=keep 出黑边)" % [str(available), str(got)])
		_chk(got == expected,
				"可用区 %s:应得 %s(最大拟合档 / 手算等比;实得 %s)"
						% [str(available), str(expected), str(got)])

	# ── ⑨ 旧存档迁移(表头插两档后 display/res_index 的语义位移是回归核心)──
	_chk(s._legacy_index_to_res(0) == Vector2i(1280, 960),
			"旧下标 0 应映射 1280×960(实得 %s)" % str(s._legacy_index_to_res(0)))
	_chk(s._legacy_index_to_res(1) == Vector2i(1600, 1200),
			"旧下标 1 应映射 1600×1200(实得 %s)" % str(s._legacy_index_to_res(1)))
	_chk(s._legacy_index_to_res(2) == Vector2i(1920, 1440),
			"旧下标 2 应映射 1920×1440(实得 %s)" % str(s._legacy_index_to_res(2)))
	_chk(s._legacy_index_to_res(3) == Vector2i(2560, 1920),
			"旧下标 3 应映射 2560×1920(实得 %s)" % str(s._legacy_index_to_res(3)))
	_chk(s._legacy_index_to_res(-1) == Vector2i(1920, 1440),
			"旧下标越界(-1)应回落默认 1920×1440(实得 %s)" % str(s._legacy_index_to_res(-1)))
	_chk(s._legacy_index_to_res(4) == Vector2i(1920, 1440),
			"旧下标越界(4,旧表只有 0-3)应回落默认 1920×1440(实得 %s)" % str(s._legacy_index_to_res(4)))
	_chk(s._legacy_index_to_res(999) == Vector2i(1920, 1440),
			"旧下标越界(999)应回落默认 1920×1440(实得 %s)" % str(s._legacy_index_to_res(999)))

	_chk(s._res_to_index(Vector2i(1024, 768)) == 0,
			"1024×768 应在新表 index 0(实得 %d)" % s._res_to_index(Vector2i(1024, 768)))
	_chk(s._res_to_index(Vector2i(1920, 1440)) == 4,
			"1920×1440 应在新表 index 4(旧表是 2;实得 %d)" % s._res_to_index(Vector2i(1920, 1440)))
	_chk(s._res_to_index(Vector2i(1, 1)) == -1,
			"不在表内的分辨率应返回 -1(实得 %d)" % s._res_to_index(Vector2i(1, 1)))

	# 内存 ConfigFile 注入(不落盘):新键优先 / 旧键按旧四档表 / 缺失与越界回退默认。
	var cf_both := ConfigFile.new()
	cf_both.set_value("display", "res_index", 2)                 # 旧键:旧表 index 2 = 1920×1440
	cf_both.set_value("display", "resolution", Vector2i(2560, 1920))
	_chk(int(s._res_index_from_config(cf_both)) == 5,
			"新旧键并存应以新键 2560×1920 为准(index 5;实得 %d)" % s._res_index_from_config(cf_both))
	var cf_old2 := ConfigFile.new()
	cf_old2.set_value("display", "res_index", 2)
	_chk(int(s._res_index_from_config(cf_old2)) == 4,
			"只有旧 res_index=2 ⇒ 旧表 1920×1440 = 新表 index 4(若当新下标用会错成 1280×960/index 2;实得 %d)"
					% s._res_index_from_config(cf_old2))
	var cf_old0 := ConfigFile.new()
	cf_old0.set_value("display", "res_index", 0)
	_chk(int(s._res_index_from_config(cf_old0)) == 2,
			"只有旧 res_index=0 ⇒ 旧表 1280×960 = 新表 index 2(实得 %d)" % s._res_index_from_config(cf_old0))
	_chk(int(s._res_index_from_config(ConfigFile.new())) == 4,
			"没有 display 段 ⇒ 默认 1920×1440(index 4;实得 %d)"
					% s._res_index_from_config(ConfigFile.new()))
	var cf_bad_old := ConfigFile.new()
	cf_bad_old.set_value("display", "res_index", 999)
	_chk(int(s._res_index_from_config(cf_bad_old)) == 4,
			"旧 res_index 越界(999)⇒ 默认 1920×1440(实得 %d)" % s._res_index_from_config(cf_bad_old))
	var cf_bad_new := ConfigFile.new()
	cf_bad_new.set_value("display", "res_index", 0)
	cf_bad_new.set_value("display", "resolution", Vector2i(1, 1))
	_chk(int(s._res_index_from_config(cf_bad_new)) == 4,
			"新键在但值不在表内 ⇒ 新键权威,回落默认 1920×1440(实得 %d)"
					% s._res_index_from_config(cf_bad_new))

	# ── ⑩ 存档兼容:写新键 + 旧键(旧四档表语义);只写临时文件,不碰真实 user://settings.cfg ──
	s.display_res_index = 4                                       # 1920×1440:新表 index 4 / 旧表 index 2(位移核心档)
	s.save(TMP_CFG)
	_chk(FileAccess.file_exists(TMP_CFG), "存档应写出临时配置 %s" % TMP_CFG)
	var tmp_cf := ConfigFile.new()
	var tmp_read_ok := tmp_cf.load(TMP_CFG) == OK
	_chk(tmp_read_ok, "临时配置应能读回")
	if tmp_read_ok:
		var saved_res: Variant = tmp_cf.get_value("display", "resolution", "")   # get_value 默认值不能传 null
		_chk(saved_res is Vector2i and saved_res == Vector2i(1920, 1440),
				"新键 display/resolution 应 = 1920×1440(实得 %s)" % str(saved_res))
		_chk(int(tmp_cf.get_value("display", "res_index", -1)) == 2,
				"旧键 display/res_index 应写**旧四档表**语义的下标(1920×1440 ⇒ 2,不是新表 index 4;实得 %s)"
						% str(tmp_cf.get_value("display", "res_index", -1)))
	var fresh = script.new()
	fresh.load_settings(TMP_CFG)
	_chk(int(fresh.display_res_index) == 4,
			"新格式读档应恢复 1920×1440(新表 index 4;实得 %d)" % int(fresh.display_res_index))
	fresh.free()
	if FileAccess.file_exists(TMP_CFG):
		DirAccess.remove_absolute(TMP_CFG)

	s.free()

	# ── 判词闸 ──
	if _checks < EXPECTED_CHECKS:
		print("DISPLAY RESOLUTION SMOKE: FAIL | 只跑了 %d 条 < %d(脚本中途中止)" % [_checks, EXPECTED_CHECKS])
		quit(1)
		return
	if not _fails.is_empty():
		print("DISPLAY RESOLUTION SMOKE: FAIL(%d/%d)" % [_fails.size(), EXPECTED_CHECKS])
		for f in _fails:
			print("  - " + f)
		quit(1)
		return
	print("DISPLAY RESOLUTION SMOKE: OK(%d 条断言):六档 4:3 · 最大拟合档 · 一档放不下时等比 4:3 不超屏 · "
			% _checks + "旧四档表存档迁移 · 新键优先 · 存档新旧键兼容")
	quit(0)
