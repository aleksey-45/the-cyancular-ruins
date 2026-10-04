extends SceneTree

# Settings 的「显示」面(分辨率档 + 全屏开关 + apply_display)冒烟。
# 跑法: timeout 60 "$GODOT" --headless --path . -s res://tests/smoke/settings_display_smoke.gd
# 判据: 文本 `SETTINGS DISPLAY SMOKE OK`(**不看退出码**);失败打 `SETTINGS DISPLAY SMOKE FAILED`。
#
# ★★ 为什么整份都用 `load()` + `get()`/`set()`/`has_method()`,不写 `Settings.display_res_index`:
#   ① `-s` 阶段 **autoload 未实例化**,且 `-s` 脚本**编译期不能引用 autoload 标识符**
#      (仓内先例: tests/smoke/ai_input_source_smoke.gd:18 / tests/smoke/spawn_pool_smoke.gd:43);
#   ② 更要紧的是**挂起风险** —— 本仓硬规则:`-s` 冒烟里任何一处脚本错误会**结束当前函数**,
#      于是走不到 `quit()`,进程**永久挂起**(外层 `timeout` 是唯一安全网)。而直接取一个
#      **还不存在**的属性(实现还没落的时候正是常态)就是这种错误 ⇒ 一律走 `Object.get/set`
#      (GDScript 里 `get()` 对不存在的属性返回 null、**不报错**)与 `has_method()` 门卫,
#      让"还没实现"干净地打 FAILED + quit(1),而不是挂死。
#
# ★ 四条断言(每条都答得出"去掉什么才红"):
#   ① 档位表(单一来源):非空 / 含基准档 1920×1440 / 每档都是 4:3。
#      红于:删空数组 / 删掉(或改掉)1920×1440 那一档 / 换任一档成非 4:3(如 1920×1080)。
#      ★ 4:3 是**设计前提**:aspect="keep" 下窗口与逻辑空间同比例才没有黑边。
#   ② 出厂默认:全新实例(**没读任何 cfg**)的 `display_res_index` **指向**1920×1440、
#      `display_fullscreen == false`。红于:默认档改指别处 / 全屏默认翻成 true。
#      ★ 刻意用**全新实例**而不是 autoload:autoload 的两个值来自**玩家的 user://settings.cfg**,
#        拿它当"出厂默认"会在玩家自己改过之后变成一条假红。
#   ③ 越界回落(照 core/config/settings.gd 里 `royale_match_min` 的 clamp 惯例)+ 两档的持久化面:
#      ③a 直写 99 → 上端回落;③b 直写 -5 → 下端回落(**只钳一边**的实现在另一条上必红);
#      ③c 临时 cfg 存 `res_index=99` → `load_settings(临时路径)` 读回来仍在合法档
#          (load 忘了读 display 段 ⇒ 停在默认档 2 ⇒ 红);
#      ③d 同一份临时 cfg 的 `fullscreen=true` 读得回来(load 少写这行 ⇒ 红);
#      ③e `save(临时路径)` 落盘后 `[display]` 段里两键都在且值对(save 少写一行 ⇒ 红)。
#      ★ ③c~③e 用**临时文件**,不碰玩家**真的** user://settings.cfg:冒烟不该有"写坏玩家存档"
#        的副作用(为此 `save()` / `load_settings()` 各带一个可选 `path` 参数,默认值即原路径)。
#   ④ `apply_display()` 在 headless 下:
#      ④a 方法存在(不存在则红 —— 不在这里直接 call,否则 `_initialize` 会中断 ⇒ **永久挂起**);
#      ④b **前提**:本进程的 DisplayServer 名字确实是 "headless"(否则这一组没测到真东西);
#      ④c **源码**:`apply_display()` 里"headless 早退"排在 `window_set_*` **之前**,
#          且两个窗口调用都在(去掉早退 / 把它挪到窗口调用之后 / 删掉全屏那一支 ⇒ 红);
#      ④d **源码**:`_ready()` 在 `load_settings()` **之后**调 `apply_display()`(删掉这行 ⇒ 红)。
#      ★★ 覆盖上限(照实登记,别把它读大了):④a 的**运行时**那一半在 headless 下**结构性无法证伪** ——
#         dummy DisplayServer 的 `window_set_size`/`window_set_mode` 是空实现,调了也不报错;而 GDScript
#         的错误只结束**出错的那个函数**,调用方(`_initialize`)照常往下走 ⇒ "调了没抛错"这件事在
#         进程内**没有可读的失败信号**(本仓硬规则,见 AGENTS.md §3 / tests/lib/probe_base.gd 文件头)。
#         故"早退真的存在、真的排在前面"由 ④c 的**源码半边**钉住;运行时半边只保证调用点没被挡住。
#      ★ 另一条覆盖上限:④d 只钉**顺序与存在**,钉不住"传对了档位/开关"(那是窗口行为,headless 下不可测;
#        OS 层真窗口/真全屏行为已登记为未验证 —— 见计划的 Task 4)。
#   ⑤(2026-10-04 Task 5 加,= 那份 brief 的 ①②③④)`Settings.fit_resolution(可用区)` 的四条 ——
#      **纯函数**(不读 DisplayServer、不写字段)⇒ 这四条在 headless 下**可真红真绿**:
#      ⑤a 可用区 2560×1528(默认档 1920×1440 放得下)⇒ 返回默认档(→ brief ①);
#      ⑤b 可用区 1920×1080(1080p 类;1600×1200 的高 1200 放不下)⇒ 1280×960(→ brief ②);
#      ⑤c 可用区 640×480(四档全放不下)⇒ 最小档 1280×960,不是 0 也不崩(→ brief ③);
#      ⑤d 四条可用区各验一次:返回值**永远在 `DISPLAY_RESOLUTIONS` 里**(→ brief ④),
#          外加"可用区**恰好**等于某档时原样返回该档"(钉住 `<=` 与 `<` 之别)。
#      红于:去掉"默认档放得下就照存档档" / 只比宽不比高 / 去掉"都放不下 ⇒ 最小档"那一支 /
#            返回值不在档表里 / 把"恰好放得下"写成放不下。
#      ⚠ ⑤c 的牙齿**比读起来少**一点(照实登记):档表里**下标 0 恰好就是最小档**,所以"兜底写成
#        `DISPLAY_RESOLUTIONS[0]`"与"按面积现算最小"给的值相同 ⇒ 这一相证伪的只是"兜底返回
#        0 / 可用区本身 / 最大档 / 越界崩",**证伪不了兜底是不是真的按最小算**。
#      ★ 覆盖上限(与 ④ 同界,并见 docs/eng/registered-debt.md §五.13):本组只保证**选出来的档**对;
#        "真窗口真的变成这个尺寸 / 改尺寸后真的居中"仍**只在源码层有证据**,非 headless 未实测
#        (非 headless 会抢焦点);`apply_display()` 里"存档档放得下就照它"那两行同理。本步做的是
#        把**选择逻辑**变成 headless 可真红真绿的纯函数。

const SETTINGS_PATH := "res://core/config/settings.gd"
const TMP_LOAD_CFG := "user://settings_display_smoke_load.cfg"
const TMP_SAVE_CFG := "user://settings_display_smoke_save.cfg"

# 基准档 = project.godot 的 display/window/size/viewport_*(1920×1440)。
# 单独抄一份在这里,是因为它同时是"出厂默认必须指向的那一档"这条**需求**的判据。
const BASE_RES := Vector2i(1920, 1440)

# 本文件在**绿**路径上应跑满的 check 条数 —— 见文件头 AGENTS.md 那条:
# "ALL-OK 只证明没有一条失败,不证明该跑的都跑过"。少跑一条就红。
# ★ 本值随相的增加而变(2026-10-04 Task 5 加 ⑤a~⑤d 共 4 条:16 → **20**)。
const EXPECTED_CHECKS := 20

var _checks := 0
var _failed := 0


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if ok:
		print("  ok   " + what)
	else:
		_failed += 1
		print("  FAIL " + what)


func _initialize() -> void:
	# ── 空载守卫(第一道):脚本载不动就别往下走 ──
	var gs: GDScript = load(SETTINGS_PATH)
	if gs == null:
		print("SETTINGS DISPLAY SMOKE FAILED: 载不到 %s" % SETTINGS_PATH)
		quit(1)
		return
	var consts: Dictionary = gs.get_script_constant_map()

	# ── 空载守卫(第二道,同时就是 Step 2 期望的那条红)──
	# ★ 少了这道守卫,下一行的 Dictionary 取缺失键会抛错 ⇒ `_initialize` 中断 ⇒ 走不到 quit ⇒ **永久挂起**。
	if not consts.has("DISPLAY_RESOLUTIONS"):
		print("SETTINGS DISPLAY SMOKE FAILED: settings.gd 没有 DISPLAY_RESOLUTIONS 常量(实现还没落?)")
		quit(1)
		return
	var res: Array = consts["DISPLAY_RESOLUTIONS"]

	# ── ① 档位表 ──
	_check(res.size() > 0, "DISPLAY_RESOLUTIONS 非空")
	var has_base := false
	var bad_ratio: Array[String] = []
	var bad_type: Array[String] = []
	for v in res:
		if not (v is Vector2i):
			bad_type.append(str(v))
			continue
		var sz: Vector2i = v
		if sz == BASE_RES:
			has_base = true
		if sz.x * 3 != sz.y * 4:
			bad_ratio.append(str(sz))
	_check(has_base, "含基准档 %s(project.godot 的 viewport 尺寸)" % str(BASE_RES))
	_check(bad_ratio.is_empty() and bad_type.is_empty(),
			"每档都是 4:3(aspect=\"keep\" 下非 4:3 会有黑边);比例不对 %s,非 Vector2i %s"
					% [str(bad_ratio), str(bad_type)])
	# 档表为空 ⇒ 下面 ③ 的 `res[i]` 全无意义,干净退出而不是在空数组上索引(那会中断 ⇒ 挂起)。
	if res.is_empty():
		_finish()
		return

	# ── ② 出厂默认(全新实例:不读 cfg、不入树)──
	var s: Node = gs.new()
	if s == null:
		print("SETTINGS DISPLAY SMOKE FAILED: settings.gd 实例化不出来")
		quit(1)
		return
	var i_top := res.size() - 1
	var idx_default: Variant = s.get("display_res_index")
	if not (idx_default is int):
		_check(false, "出厂默认有 display_res_index 字段(实得 %s)" % str(idx_default))
	else:
		var di := int(idx_default)
		if di < 0 or di >= res.size():
			_check(false, "出厂默认 display_res_index=%d 越界(档表 %d 档)" % [di, res.size()])
		else:
			_check(res[di] == BASE_RES,
					"出厂默认 display_res_index=%d 指向基准档 %s(实得 %s)"
							% [di, str(BASE_RES), str(res[di])])
	var fs_default: Variant = s.get("display_fullscreen")
	_check(fs_default is bool and bool(fs_default) == false,
			"出厂默认 display_fullscreen == false(实得 %s)" % str(fs_default))

	# ── ③a/③b 直写越界值 → 回落 ──
	s.set("display_res_index", 99)
	var got: Variant = s.get("display_res_index")
	_check(got is int and int(got) == i_top,
			"直写 99 → 上端回落到 %d(实得 %s;只钳下端的实现会红)" % [i_top, str(got)])
	s.set("display_res_index", -5)
	got = s.get("display_res_index")
	_check(got is int and int(got) == 0,
			"直写 -5 → 下端回落到 0(实得 %s;只钳上端的实现会红)" % str(got))

	# ── ③c/③d load 路径(临时 cfg,不碰玩家的 settings.cfg)──
	var cf := ConfigFile.new()
	cf.set_value("display", "res_index", 99)
	cf.set_value("display", "fullscreen", true)
	var lerr := cf.save(TMP_LOAD_CFG)
	var s2: Node = null
	if lerr != OK or not FileAccess.file_exists(TMP_LOAD_CFG):
		_check(false, "临时 cfg 写得下去(%s,err=%d)" % [TMP_LOAD_CFG, lerr])
	else:
		s2 = gs.new()
		if not s2.has_method("load_settings"):
			_check(false, "load_settings() 存在")
		else:
			s2.call("load_settings", TMP_LOAD_CFG)
			var got2: Variant = s2.get("display_res_index")
			_check(got2 is int and int(got2) == i_top,
					"临时存档 res_index=99 → load 路径回落到 %d(实得 %s;load 没读 display 段会停在默认档 %s)"
							% [i_top, str(got2), str(idx_default)])
			var got2fs: Variant = s2.get("display_fullscreen")
			_check(got2fs is bool and bool(got2fs) == true,
					"临时存档 fullscreen=true → load 读进了 display_fullscreen(实得 %s)" % str(got2fs))

	# ── ③e save 路径(write 半边)──
	s.set("display_res_index", 0)
	s.set("display_fullscreen", true)
	if not s.has_method("save"):
		_check(false, "save() 存在")
	else:
		s.call("save", TMP_SAVE_CFG)
		var back := ConfigFile.new()
		if back.load(TMP_SAVE_CFG) != OK:
			_check(false, "save() 落盘的 cfg 读得回来(%s)" % TMP_SAVE_CFG)
		else:
			_check(int(back.get_value("display", "res_index", -1)) == 0
					and bool(back.get_value("display", "fullscreen", false)) == true,
					"save() 把两档写进 [display] 段(实得 res_index=%s fullscreen=%s;少写一行会红)"
							% [str(back.get_value("display", "res_index", "<无此键>")),
								str(back.get_value("display", "fullscreen", "<无此键>"))])

	# ── ④ apply_display() 在 headless ──
	# ★ 本 check 的牙齿就是"方法存在":存在 ⇒ 门卫为真;不存在 ⇒ 红。
	#   **不**在这里直接 call 一个可能不存在的方法(那会中断 `_initialize` ⇒ 永久挂起)。
	#   "调了没抛错"那半边在进程内读不到(见文件头 ④ 的覆盖上限),故也不假造一条恒真的 `_check(true, …)`。
	var s3: Node = gs.new()
	_check(s3.has_method("apply_display"),
			"apply_display() 存在(不存在则红;此处先门卫再调,免得挂起)")
	if s3.has_method("apply_display"):
		s3.call("apply_display")
	_check(DisplayServer.get_name() == "headless",
			"本进程 DisplayServer 是 headless(实得 %s)—— ④ 这一组只对 headless 成立"
					% DisplayServer.get_name())

	# ── ④c/④d 源码半边(headless 早退无法从运行时读到,见文件头)──
	var src := FileAccess.get_file_as_string(SETTINGS_PATH)
	var body := _func_body(src, "apply_display")
	_check(body != "", "源码里找得到 func apply_display(…)(源码半边的前提)")
	if body != "":
		# ★ 用**归一化**(去掉空格/制表)后的表达式判"早退真的是一行分支",而不是判 `headless` 这个词 ——
		#   否则把 `if` 那一行删掉、注释里留个 "headless 早退" 就能骗过这条守卫(典型"查子串不查分支")。
		var norm := body.replace(" ", "").replace("\t", "")
		var i_guard := norm.find("DisplayServer.get_name()==\"headless\"")
		var i_size := norm.find("window_set_size")
		var i_mode := norm.find("window_set_mode")
		_check(i_guard >= 0 and i_size > i_guard and i_mode > i_guard,
				"apply_display():headless 早退排在 window_set_size/window_set_mode **之前**"
						+ "(位置: 早退 %d / size %d / mode %d;去掉早退或挪到窗口调用之后 ⇒ 红)"
								% [i_guard, i_size, i_mode])
	var rbody := _func_body(src, "_ready")
	_check(rbody != "", "源码里找得到 func _ready(…)(源码半边的前提)")
	if rbody != "":
		var i_load := rbody.find("load_settings(")
		var i_apply := rbody.find("apply_display(")
		_check(i_load >= 0 and i_apply > i_load,
				"_ready() 在 load_settings() 之后调 apply_display()(位置: load %d / apply %d;删掉这行 ⇒ 红)"
						% [i_load, i_apply])

	# ── ⑤ `fit_resolution(可用区)` —— 纯函数,四条(= brief 的 ①②③④)──
	# ★ 为什么要这四条:装不下基准逻辑空间(1920×1440)的屏(如 1080p,高 1080 < 1440)上,
	#   `apply_display()` 照存档档开窗 ⇒ 窗口超出屏幕被 OS 钳位 ⇒ 玩家看到"既不全屏也不居中"。
	#   修法是把**选择逻辑**抽成纯函数(不读 DisplayServer、不写字段)⇒ 它在 headless 下
	#   **可真红真绿** —— 而"真开窗 / 改尺寸后真居中"仍不可测(见文件头 ④/⑤ 的覆盖上限)。
	# 每条答得出"去掉什么才红"(逐条写在文件头的 ⑤ 段里)。
	var has_fit: bool = s3.has_method("fit_resolution")
	_fit_check(has_fit, s3, Vector2i(2560, 1528), Vector2i(1920, 1440),
			"⑤a 可用区 2560×1528(默认档 1920×1440 放得下)⇒ 能放下的最大档正是默认档")
	_fit_check(has_fit, s3, Vector2i(1920, 1080), Vector2i(1280, 960),
			"⑤b 可用区 1920×1080(1600×1200 的高 1200 放不下)⇒ 能放下的最大档 1280×960")
	_fit_check(has_fit, s3, Vector2i(640, 480), Vector2i(1280, 960),
			"⑤c 可用区 640×480(四档全放不下)⇒ 最小档 1280×960(不是 0、不崩)")
	var fit_areas: Array[Vector2i] = [Vector2i(2560, 1528), Vector2i(1920, 1080),
			Vector2i(640, 480), Vector2i(2560, 1920)]
	var fit_bad: Array[String] = []
	if not has_fit:
		fit_bad.append("fit_resolution() 不存在(实现没落)")
	else:
		for a in fit_areas:
			var got5: Variant = s3.call("fit_resolution", a)
			if not (got5 is Vector2i):
				fit_bad.append("%s → %s(不是 Vector2i)" % [str(a), str(got5)])
			elif not res.has(got5):
				fit_bad.append("%s → %s(不在档表里)" % [str(a), str(got5)])
			elif res.has(a) and (got5 as Vector2i) != a:
				fit_bad.append("%s 恰好是一档 ⇒ 实得 %s(恰好放得下必须算放得下)"
						% [str(a), str(got5)])
	_check(fit_bad.is_empty(),
			"⑤d 四条可用区 %s 的返回值都在 DISPLAY_RESOLUTIONS 里,且恰好是一档时原样返回该档%s"
					% [str(fit_areas),
						"" if fit_bad.is_empty() else "(问题:%s)" % str(fit_bad)])

	# ── 收尾:删掉自己造的两个临时 cfg(不留垃圾在 user://),并 free 掉三个 Node 实例 ──
	# ★ `Settings` 是 Node(不是 RefCounted):`gs.new()` 出来的实例**不入树** ⇒ 不手工 free 会
	#   在退出时刷 "ObjectDB instances were leaked at exit" 警告,淹掉真正的 FAIL 行。
	for n in [s, s2, s3]:
		if n != null and is_instance_valid(n):
			n.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_LOAD_CFG))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_SAVE_CFG))
	_finish()


# 取某个函数的源码正文:从 `func <name>(` 到下一个顶层 `\nfunc `(settings.gd 里没有内联 lambda,
# 故这个粗切法够用;切不出来返回 "")。
static func _func_body(src: String, name: String) -> String:
	var start := src.find("func %s(" % name)
	if start < 0:
		return ""
	var nxt := src.find("\nfunc ", start + 1)
	if nxt < 0:
		nxt = src.length()
	return src.substr(start, nxt - start)


# 跑一条 `fit_resolution(可用区)` 断言。
# ★ 门卫为假时**绝不调用**:实现还没落时 `call()` 一个不存在的方法会中断 `_initialize`
#   ⇒ 走不到 quit ⇒ 进程**永久挂起**(见文件头);这里改成**打红**,于是"实现没落"的改前跑
#   能干净地看到四条 FAIL,且那几条照记进 `_checks`(计数闸不因缺实现而失真)。
func _fit_check(has_fit: bool, inst: Node, area: Vector2i, want: Vector2i, what: String) -> void:
	if not has_fit:
		_check(false, what + " —— fit_resolution() 还不存在(实现没落)")
		return
	var got: Variant = inst.call("fit_resolution", area)
	_check(got is Vector2i and (got as Vector2i) == want,
			"%s(want %s,got %s)" % [what, str(want), str(got)])


func _finish() -> void:
	if _checks < EXPECTED_CHECKS:
		_failed += 1
		print("  FAIL 只跑了 %d 条断言(期望 ≥ %d)" % [_checks, EXPECTED_CHECKS])
	if _failed == 0:
		print("SETTINGS DISPLAY SMOKE OK（%d 条断言）" % _checks)
		quit(0)
	else:
		print("SETTINGS DISPLAY SMOKE FAILED:%d 条(共跑 %d)" % [_failed, _checks])
		quit(1)
