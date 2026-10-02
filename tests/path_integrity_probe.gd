extends SceneTree

# 路径一致性守卫:全仓 .gd / .tscn 里出现的每个 `res://` 字面量都必须指向真实存在的
# 文件或目录。目录重构期间每搬一步跑一次。
#
# 跑法: "$GODOT" --headless --path . -s res://tests/path_integrity_probe.gd
# 通过 = `PATH INTEGRITY: ALL-OK` 退出 0。
#
# ★ 必须剥注释再扫:注释里的 `res://old/path` 不是代码(本仓 kh_l6 与 ui_palette 的
#   注释里就各有一句假路径)。直接 grep 会既假红又漏改。
# ★ .tscn 只查 ext_resource 的 path=;uid= 字段不查(uid 由 .gd.uid 边车与 .tscn 头承载)。
# ★ 豁免走 tests/path_integrity_allow.txt,每行一个完整路径 + 可选 `# 原因`。

# ★ 只扫这几根:ScanUtil.collect 只收 .gd / .tscn,所以放没有 GDScript 的目录
#   (tools/ level_editor/) 进去是白扫。Task 2 搬完 render/ 后要把 "res://render" 删掉。
const SCAN_ROOTS := ["res://core", "res://scenes", "res://server", "res://ui",
	"res://render", "res://tests"]
const ALLOW_PATH := "res://tests/path_integrity_allow.txt"
const SCAN_UTIL_PATH := "res://tests/lib/scan_util.gd"

var _fail := 0
var _su: GDScript = null      # ★ 显式 load,不用全局类名 —— 本仓所有 -s 冒烟都走这条路

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
	# ★ 不能用 _su.read():ScanUtil.read 首行是 `ResourceLoader.exists(path)`,而豁免文件是
	#   .txt —— **不是**已导入资源 ⇒ 恒返回 "" ⇒ 豁免表恒空、豁免形同虚设(实测:放进去的
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
	# ★ 必须**先**查 FileAccess.file_exists:ResourceLoader.exists 只认**已导入**的资源,
	#   而本仓有大量不算资源的普通文件被 GDScript 字符串引用 —— `maps/*.cyrm`(游戏用
	#   FileAccess 读)、`tests/*.txt`,以及探针运行时 save_png 出来的 .png。只查
	#   ResourceLoader/DirAccess 会把它们全判成"不存在"(实测 28 条假红),而把真文件
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
	# ★ 空载守卫:load() 失败还往下走会在 null 上抛错,而 -s 抛错走不到 quit() → 永久挂起
	_su = load(SCAN_UTIL_PATH)
	if _su == null:
		print("PATH INTEGRITY: FAILED: 找不到 ", SCAN_UTIL_PATH)
		quit(1)
		return

	var allow := _load_allow()
	var re := RegEx.new()
	re.compile("res://[A-Za-z0-9_./-]*")

	var bad: Array[String] = []
	var seen := {}
	var files: Array = _su.collect(SCAN_ROOTS)
	if files.size() < 50:
		# 扫到的文件太少 = 扫描根写错了,别静默放行
		print("PATH INTEGRITY: FAILED: 只扫到 %d 个文件,扫描根可疑" % files.size())
		quit(1)
		return

	for f in files:
		var src: String = _su.read(f)
		if src.is_empty():
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

	if bad.is_empty():
		print("PATH INTEGRITY: ALL-OK（扫描 %d 个文件）" % files.size())
		quit(0)
	else:
		for b in bad:
			print("[FAIL] ", b)
		print("PATH INTEGRITY: FAILED: %d" % bad.size())
		quit(1)
