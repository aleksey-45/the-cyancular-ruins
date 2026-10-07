extends SceneTree

# 路径一致性守卫:全仓 .gd / .tscn / .sh 里出现的每个 `res://` 字面量都必须指向真实存在的
# 文件或目录。目录重构期间每搬一步跑一次。
#
# 跑法: "$GODOT" --headless --path . -s res://tests/probe/path_integrity_probe.gd
# 通过 = `PATH INTEGRITY: ALL-OK` 退出 0。
#
# - 必须剥注释再扫:注释里的 `res://old/path` 不是代码(本仓 kh_l6 与 ui_palette 的
#   注释里就各有一句假路径)。直接 grep 会既虚假失败（测试用例误报）又漏改。
# - .tscn 只查 ext_resource 的 path=;uid= 字段不查(uid 由 .gd.uid 边车与 .tscn 头承载)。
# - 豁免走 tests/path_integrity_allow.txt,每行一个完整路径 + 可选 `# 原因`。
#
# 注意： 覆盖面边界 —— 本守卫能给的最强保证是什么、测不到什么:
#   扫的是 SCAN_ROOTS(core/ scenes/ server/ ui/ tests/)下的 .gd / .tscn
#   (走 ScanUtil.collect),**外加** tests/ 下递归收的 .sh(本文件自己用 DirAccess 收,
#   见 _collect_sh —— 刻意不动共享脚手架 ScanUtil,它另有 5 个探针依赖它"只收 .gd/.tscn"
#   的语义)。**看不见**的载体(已知边界,不是漏扫,不打算在本 Task 补):
#     - project.godot —— autoload 路径与 `main_scene` 里的 res:// 字面量都不在扫描面内;
#     - start_server.bat —— 仓库顶层启动脚本;
#     - tools/*.py —— 构建/导出脚本里写死的路径。
#   要盖住这三处得另加扫描根或另写扩展名,超出"路径一致性"这一个守卫的职责。
#
# 注意： **拆串 / `%`-格式化 / 变量拼接** —— 本守卫**结构性看不见**这一类(本分支真实咬到过
#   人的盲区,Task 3 的 kh_l6 5 处、Task 5 又两处):正则是 `res://[A-Za-z0-9_./-]*`,只取
#   **单个字符串字面量**  ->  `"res://ui/" + "pause_menu.gd"` 被削成 `res://ui/`,而那**是个
#   仍然存在的目录**  ->  通过、不报红;`"res://tests/%s.tscn" % x` 与 `"res://" + var` 同理。
#    ->  **每个搬迁 task 必须自己按形态扫一遍**(现成命令 + "活引用 vs 负向断言"的区分见
#   `docs/superpowers/plans/2026-10-02-directory-restructure.md` 的 Task 4 Step 3b)。
#   - 反向纪律:有些拆串是**负向断言**(断言"某字符串**不该**出现"),例如 `kh_l4_probe.gd`
#   里那处 —— **必须原样保留**;看到拆串先判它是活引用还是负向断言,再决定动不动。
#
# 注意： 豁免条目是**无条件**的:命中即放行,不看"这条路径今天还在不在"。 ->  豁免会**活过
#   自己的成因**。例:若 `seam_screenshot.gd` 被删、而 `seam_analyze.gd` 还在,则
#   `res://tests/_seam_a_old.png` 那条**读**路径**依旧豁免**,`seam_analyze` 指向一个
#   永不存在的输入的断链就此被藏住 —— 表里那一行还在,守卫一个字不说。
#    ->  改豁免表 / 删被豁免路径的生产者时,必须一并复核"它当初为什么被豁免"。

# - 只扫这几根:ScanUtil.collect 只收 .gd / .tscn,所以放没有 GDScript 的目录
#   (tools/ level_editor/) 进去是白扫。Task 2 已把 render/ 并入 core/present/  ->  该根已删。
const SCAN_ROOTS := ["res://core", "res://scenes", "res://server", "res://ui",
	"res://tests"]
const ALLOW_PATH := "res://tests/path_integrity_allow.txt"
const SCAN_UTIL_PATH := "res://tests/lib/scan_util.gd"
# - .sh 的扫描根。tests/ 下这批脚本是 Task 5 最大的搬动对象,而 ScanUtil.collect 看不见
#   它们,故单独收(递归)。
const SH_ROOT := "res://tests"

var _su: GDScript = null      # - 显式 load,不用全局类名 —— 本仓所有 -s 冒烟都走这条路

# 递归收 res://tests 下所有 *.sh(跳过点目录,与 ScanUtil.walk 相同机制)。
func _collect_sh(dir_path: String, out: Array[String]) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if not name.begins_with("."):
			var p := dir_path.path_join(name)
			if d.current_is_dir():
				_collect_sh(p, out)
			elif name.ends_with(".sh"):
				out.append(p)
		name = d.get_next()
	d.list_dir_end()

# - .sh **不能**走 _su.read:ScanUtil.read 的首行是 `ResourceLoader.exists(path)`,而 .sh
#   不是 Godot 认得的资源  ->  恒假  ->  恒返回 ""(实测 RL_exists_sh=false / FA_exists_sh=true)。
#   若用 _su.read,11 个 .sh 会**全部**落进 SKIP 分支  ->  扫描面看着扩了、其实一条没查。
#   (同一个已知缺陷 `_load_allow` 已经踩过一次 —— 那里读的是 .txt,注释就在它上方。)
func _read_sh(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_as_text() if f != null else ""

func _strip_line_comment(line: String) -> String:
	var quote := ""
	var j := 0
	while j < line.length():
		var ch := line[j]
		if quote != "":
			if ch == "\\":
				j += 1
			elif ch == quote:
				quote = ""
		elif ch == "\"" or ch == "'":
			quote = ch
		elif ch == "#":
			return line.substr(0, j)
		j += 1
	return line

func _code_only(src: String) -> String:
	var out: Array[String] = []
	for line in src.split("\n"):
		var s := _strip_line_comment(line).strip_edges()
		if not s.is_empty():
			out.append(s)
	return "\n".join(out)

func _load_allow() -> Dictionary:
	var allow := {}
	# - 不能用 _su.read():ScanUtil.read 首行是 `ResourceLoader.exists(path)`,而豁免文件是
	#   .txt —— **不是**已导入资源  ->  恒返回 ""  ->  豁免表恒空、豁免形同虚设(实测:放进去的
	#   res://__l5_synthetic__.gd 照样报红)。这里直接用 FileAccess 读。
	if not FileAccess.file_exists(ALLOW_PATH):
		# 豁免文件不存在 = 空豁免,不是错误
		return allow
	var f := FileAccess.open(ALLOW_PATH, FileAccess.READ)
	if f == null:
		return allow
	var src := f.get_as_text()
	for line in src.split("\n"):
		var s := _strip_line_comment(line).strip_edges()
		if not s.is_empty():
			allow[s] = true
	return allow

func _exists_any(p: String) -> bool:
	# `res://` 裸串与 `res://dir/` 这类是**目录**;ResourceLoader 只认资源。
	# 用 DirAccess.open 而不是 dir_exists_absolute:后者对 res:// 前缀不保证成立。
	# - 必须**先**查 FileAccess.file_exists:ResourceLoader.exists 只认**已导入**的资源,
	#   而本仓有大量不算资源的普通文件被 GDScript 字符串引用 —— `maps/*.cyrm`(游戏用
	#   FileAccess 读)、`tests/*.txt`,以及探针运行时 save_png 出来的 .png。只查
	#   ResourceLoader/DirAccess 会把它们全判成"不存在"(实测 28 条虚假失败（测试用例误报）),而把真文件
	#   塞进豁免文件正是这条守卫最该避免的事。
	# ⚠ 已知边界:Windows 文件系统不区分大小写,大小写写错的路径在这里**会通过**
	#   (导出成 .pck 后是区分大小写的)。本守卫只回答"有没有",不回答"大小写对不对"。
	if FileAccess.file_exists(p):
		return true
	if ResourceLoader.exists(p):
		return true
	var d := DirAccess.open(p)
	if d == null:
		return false
	d.list_dir_end()
	return true

func _initialize() -> void:
	# - 空载守卫:load() 失败还往下走会在 null 上抛错,而 -s 抛错走不到 quit() → 永久挂起
	_su = load(SCAN_UTIL_PATH)
	if _su == null:
		print("PATH INTEGRITY: FAILED: 找不到 ", SCAN_UTIL_PATH)
		quit(1)
		return

	var allow := _load_allow()
	var re := RegEx.new()
	re.compile("res://[A-Za-z0-9_./-]*")

	var bad: Array[String] = []
	var skipped: Array[String] = []
	var seen := {}
	var files: Array = _su.collect(SCAN_ROOTS)
	var sh_files: Array[String] = []
	_collect_sh(SH_ROOT, sh_files)
	files.append_array(sh_files)

	if files.size() < 50:
		# 扫到的文件太少 = 扫描根写错了,别静默放行
		print("PATH INTEGRITY: FAILED: 只扫到 %d 个文件,扫描根可疑" % files.size())
		quit(1)
		return
	if sh_files.is_empty():
		# .sh 一路一个都没收到 = _collect_sh 或 SH_ROOT 坏了  ->  别静默放行:那正是本 Task 要
		# 扩的那半个扫描面(Task 5 要搬这批脚本),静默成 0 就等于守卫看着扩了、其实没扫。
		print("PATH INTEGRITY: FAILED: %s 下没扫到任何 .sh,扫描根可疑" % SH_ROOT)
		quit(1)
		return

	for f in files:
		# .sh 走 FileAccess(见 _read_sh 的注释);.gd/.tscn 仍走 ScanUtil.read。
		var src: String = _read_sh(f) if f.ends_with(".sh") else _su.read(f)
		if src.is_empty():
			# - **不许静默跳过**。tests/lib/scan_util.gd 的文件头明写:「调用方**必须**自己判空
			#   并报红 —— 静默返回 "" 是这类探针最典型的失明方式」。ScanUtil.read 既在"文件不存在"
			#   时返回 ""、也在"打不开 / 内容为空"时返回 ""。
			#   今天不该发生(collect/_collect_sh 只返真实存在的文件),但真发生时必须看得见,
			#   否则那个文件里的字面量一条都不会被检查、而 verdict 照样 ALL-OK。
			skipped.append(f)
			print("[SKIP] %s（读不到内容,该文件的 res:// 字面量未被检查）" % f)
			continue
		var code := _code_only(src)
		for m in re.search_all(code):
			var p := m.get_string()
			if allow.has(p) or _exists_any(p):
				continue
			var key := "%s\t%s" % [p, f]
			if seen.has(key):
				continue
			seen[key] = true
			bad.append("[%s] %s" % [f, p])

	# 计数与 verdict 一起打:扫描面(.gd/.tscn + .sh)、.sh 的份额、以及被跳过的文件数 ——
	# 三个数缺一个,都看不出"守卫是不是哪天静默少扫了一半"。
	var tally := "扫描 %d 个文件，其中 .sh %d 个，跳过 %d 个读不到" % [files.size(), sh_files.size(), skipped.size()]
	if bad.is_empty():
		print("PATH INTEGRITY: ALL-OK（%s）" % tally)
		quit(0)
	else:
		for b in bad:
			print("[FAIL] ", b)
		print("PATH INTEGRITY: FAILED: %d（%s）" % [bad.size(), tally])
		quit(1)
