extends SceneTree

# `project.godot` 的 `[debug]` 文件日志三键 —— **常驻守卫**。
# 跑法: source tests/env.sh && timeout 60 "$GODOT" --headless --path . \
#           -s res://tests/smoke/project_settings_smoke.gd
# 判据: 文本 `SMOKE OK`(**不看退出码** —— 挂住时一行裁决都不打印)。
#
# ═══ 为什么需要它(source of truth: 实测,不是文档)═══
# `d6d2440`(B10「加速键位改为鼠标右键」)本意只改一个按键,却把整个 `[debug]` 段搬了位置、
# **把两行中文注释并进了键名**(中文还被双重编码),于是 `project.godot` 里那两条键
# `debug/回到主菜单…file_logging/enable_file_logging` 成了**合法但无用**的设置名 ——
# 真键**一条都不存在**。后果是**静默**的:`max_log_files` 读不到就回落默认,不报错、不红、
# 没人看得见(真机文件日志只剩 5 份配额,崩溃现场会被轮转挤掉)。
#
# ═══ ★★ 本文件里哪条断言是承重的(2026-10-04 实测,别照抄结论)═══
# 在**空工程**里跑同一段探针,引擎(4.7.1 stable,console/debug 模板)报:
#     debug/file_logging/enable_file_logging     has=true  默认 **false**
#     debug/file_logging/enable_file_logging.pc  has=true  默认 **true**
#     debug/file_logging/max_log_files           has=true  默认 **5**
# 由此:
#   · ① 的 `has_setting(...)` 段 **恒真** —— 这三个键都是**引擎内置**设置,`has_setting` 与
#     project.godot 里写没写**无关**(实测:`debug/file_logging/log_path` 本仓从没写过,
#     `has_setting` 照样 true;连上面那两条乱码键也被当作"有"的设置列了出来)。
#     ⇒ **去掉什么它才会红:去掉什么都不会** —— 它给不了任何保证,只留作"键名还在引擎里"的记号。
#   · ② 的 `.pc` 的**值**同样是引擎默认值(true),与 project.godot 无关 ⇒ **也没有鉴别力**。
#     (它的意义是"意图落纸":`6b5f3fb` 当初就是为导出客户端显式开的这一条。)
#   · ③ 是这三条里**唯一**能跟着 project.godot 走的:`max_log_files` 从 64 改回 32 或删掉整行,
#     它当场红(已做变异,见 task-1-report)。
#   · ④(读 `project.godot` 原文)才是**真正拦得住 `d6d2440` 那次事故**的那条:键名被乱码吞掉时,
#     ③ 会红是因为**顺带丢了值**,而 ④ 直接判"这一行必须逐字长这样" —— 值改对了但键名被拼错
#     也拦得住。
# ⚠ 覆盖上限(照实登记):本守卫只判**这个文件里这三行的字面量与 ProjectSettings 读回来的值**。
#   它**测不到**"日志真的落到了 user://logs/" —— 那要真起一个进程看文件;也测不到导出模板的
#   release 半边的行为(本处跑的是 debug 模板)。这两档的拦截手段不在这里。
#
# ★ 空载守卫:本文件不 `load()` 任何脚本,但**同样**需要它 —— Godot 在 `-s` 下 `push_error`/
#   抛错只会中断**当前函数**,走不到 `quit()` ⇒ 进程**永久挂起**(本仓踩过)。故 ④ 的 RegEx
#   编译失败、以及最后兜底的分支都必须自己 `quit(1)`。
const G := "debug/file_logging/"
const CFG := "res://project.godot"

var _fails: Array[String] = []


func _initialize() -> void:
	# ── ① 文件日志总开关:存在且为 true ──
	if not ProjectSettings.has_setting(G + "enable_file_logging"):
		_fails.append("① 不认「%senable_file_logging」这个设置名" % G)
	elif ProjectSettings.get_setting(G + "enable_file_logging") != true:
		_fails.append("① %senable_file_logging = %s(要 true;实测默认 false,故这一条**必须**由 project.godot 给)"
				% [G, str(ProjectSettings.get_setting(G + "enable_file_logging"))])

	# ── ② 导出模板(release)那一半:存在且为 true ──
	if not ProjectSettings.has_setting(G + "enable_file_logging.pc"):
		_fails.append("② 不认「%senable_file_logging.pc」这个设置名" % G)
	elif ProjectSettings.get_setting(G + "enable_file_logging.pc") != true:
		_fails.append("② %senable_file_logging.pc = %s(要 true)"
				% [G, str(ProjectSettings.get_setting(G + "enable_file_logging.pc"))])

	# ── ③ 轮转配额必须是 64(唯一跟着 project.godot 走的数值断言)──
	if not ProjectSettings.has_setting(G + "max_log_files"):
		_fails.append("③ 不认「%smax_log_files」这个设置名" % G)
	else:
		var got := int(ProjectSettings.get_setting(G + "max_log_files"))
		if got != 64:
			_fails.append("③ %smax_log_files = %d(要 64;引擎默认 5 ⇒ 5 会把崩溃现场轮转吃掉)"
					% [G, got])

	# ── ④ 原文:这三行必须**逐字**长在 project.godot 里(唯一拦得住 d6d2440 那次事故的形状)──
	_check_raw_lines()

	if _fails.is_empty():
		print("SMOKE OK(project_settings:[debug] 文件日志三键)")
		quit(0)
	else:
		print("PROJECT SETTINGS SMOKE: %d 条失败" % _fails.size())
		for f in _fails:
			print("  ✗ " + f)
		quit(1)


func _check_raw_lines() -> void:
	var f := FileAccess.open(CFG, FileAccess.READ)
	if f == null:
		# ★ 连文件都读不到 ⇒ 本守卫已失明,直接红,不静默跳过(否则下面会"零失败"假绿)。
		_fails.append("④ 读不到 %s(%s)⇒ 本守卫失明" % [CFG, error_string(FileAccess.get_open_error())])
		return
	var text := f.get_as_text()
	f.close()
	# ★★ 两侧都用**换行**当边界,不用 `^`/`$`(2026-10-04 踩过):Godot 的 `RegEx` 里 `$` 是
	#   **整个字符串的末尾**(不自动按行),实测 `"\n" + kv + "$"` 对文件中间那一行**永不匹配**
	#   —— 那样写出来的守卫会**一动不动地红**(假红),比恒绿更误导。`\nX\n` 是这里正解。
	#   两侧夹住 ⇒ 键名前面再粘中文(`d6d2440` 的形状)或尾部多粘一个字都匹配不上。
	for kv in ["file_logging/enable_file_logging=true",
			"file_logging/enable_file_logging.pc=true",
			"file_logging/max_log_files=64"]:
		var re := RegEx.new()
		# ★ 编译失败必须**自己收口**:Godot 在 `-s` 下报错只中断当前函数,不 quit 就永久挂起。
		if re.compile("\n" + kv + "\n") != OK:
			print("PROJECT SETTINGS SMOKE: FAIL(RegEx 编译不过:%s ⇒ 本守卫失明)" % kv)
			quit(1)
			return
		if re.search(text) == null:
			_fails.append("④ project.godot 里没有**独立一整行**「%s」(键名被注释/乱码吞掉,或值被改)" % kv)
