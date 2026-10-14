extends SceneTree

const SCAN_ROOTS := ["res://core", "res://scenes", "res://server", "res://ui",
	"res://tests"]
const ALLOW_PATH := "res://tests/path_integrity_allow.txt"
const SCAN_UTIL_PATH := "res://tests/lib/scan_util.gd"
const SH_ROOT := "res://tests"

var _su: GDScript = null      # - 显式 load,不用全局类名 —— 本仓所有 -s 冒烟都走这条路

# 递归收 res://tests 下所有 *.sh(跳过点目录,与 ScanUtil.walk 相同处理逻辑)。
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

# 读取 Shell 脚本内容。因 .sh 文件非引擎资源，需直接通过 FileAccess 读取
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
	# 豁免文件为纯文本文件，直接通过 FileAccess 读取
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
	# 目录或资源存在性校验：优先通过 FileAccess 验证普通文件，再通过 ResourceLoader 验证已导入资源，最后检查目录
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
	# - 空载防御性校验:load() 失败还往下走会在 null 上抛错,而 -s 抛错走不到 quit() -> 永久挂起
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
		print("PATH INTEGRITY: FAILED: %s 下没扫到任何 .sh,扫描根可疑" % SH_ROOT)
		quit(1)
		return

	for f in files:
		# .sh 走 FileAccess(见 _read_sh 的注释);.gd/.tscn 仍走 ScanUtil.read。
		var src: String = _read_sh(f) if f.ends_with(".sh") else _su.read(f)
		if src.is_empty():
			# - 不许静默跳过。tests/lib/scan_util.gd 的文件头明写:「调用方必须自己判空
			#   并报红 —— 静默返回 "" 是这类探针最典型的扫描失效（未读取到源文件）方式」。ScanUtil.read 既在"文件不存在"
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
	# 三个数缺一个,都看不出"防御性校验是不是哪天静默少扫了一半"。
	var tally := "扫描 %d 个文件，其中 .sh %d 个，跳过 %d 个读不到" % [files.size(), sh_files.size(), skipped.size()]
	if bad.is_empty():
		print("PATH INTEGRITY: ALL-OK（%s）" % tally)
		quit(0)
	else:
		for b in bad:
			print("[FAIL] ", b)
		print("PATH INTEGRITY: FAILED: %d（%s）" % [bad.size(), tally])
		quit(1)
