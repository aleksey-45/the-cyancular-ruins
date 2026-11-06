class_name ScanUtil
extends RefCounted


# 读 res:// 下的源文本;不存在(或打不开)返回 ""。调用方必须自己判空并报红 —— 静默返回 "" 是这类探针最典型的失明方式(读不到源文件 → 所有 contains 断言恒假/恒真)。
static func read(path: String) -> String:
	if not ResourceLoader.exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_as_text() if f != null else ""


# 递归收集 roots 下所有 .gd / .tscn(跳过点目录;.git/.godot/.superpowers 都在其中)
static func collect(roots: Array) -> Array[String]:
	var out: Array[String] = []
	for r in roots:
		walk(r, out)
	out.sort()
	return out


static func walk(dir_path: String, out: Array[String]) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if not name.begins_with("."):
			var p := dir_path.path_join(name)
			if d.current_is_dir():
				walk(p, out)
			elif name.ends_with(".gd") or name.ends_with(".tscn"):
				out.append(p)
		name = d.get_next()
	d.list_dir_end()


static func strip_line_comment(line: String) -> String:
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


# 剥注释视图(整行注释与行尾注释都删,再 strip_edges、丢空行)。供「在位/唯一挂载点/顺序」类断言用:注释讲的是动机,不是代码。
# ⚠ 只删整行注释是不够的(实测):一句提到退役名的行尾注释能让「零引用」断言假红。⚠ 两个方向不单调,别以为「剥得越干净越严」:剥掉行尾注释会让「在位」类断言更严、让「零引用」类断言更松 —— 新写断言时想清楚它属于哪一类。
static func code_only(src: String) -> String:
	var out: Array[String] = []
	for line in src.split("\n"):
		var s: String = strip_line_comment(line).strip_edges()
		if s.is_empty():
			continue
		out.append(s)
	return "\n".join(out)


static func code_view(src: String) -> String:
	var out: Array[String] = []
	for raw in src.split("\n"):
		var s := strip_line_comment(raw)
		if s.strip_edges().is_empty():
			continue
		out.append(s.rstrip(" \t"))
	return "\n".join(out)


# 取某函数的函数体(从头到下一个 func 之前;找不到返回空串)。判据必须落在体内,否则一条同名的调用/注释就能满足断言。
static func func_body(code: String, name: String) -> String:
	var i := code.find("func " + name + "(")
	if i < 0:
		return ""
	var j := code.find("\nfunc ", i + 1)
	return code.substr(i, (j - i) if j > 0 else code.length() - i)


## 同上,但只认行首(列 0)的函数定义。
## ★★ 为什么必须有它:func_body 是裸子串搜索,而 code_only 会剥掉缩进 ⇒ 文件里若有内部类且它也有同名方法,那个缩进的方法会被当成顶层那个先命中 —— 取到的是错的那个体,而且不报错(实测:scenes/level_0.gd 的内部类 _Reaper 也有 func _ready())。
static func top_func_body(code: String, name: String) -> String:
	var i := code.find("\nfunc " + name + "(")
	if i < 0:
		return ""
	i += 1
	var j := code.find("\nfunc ", i + 1)
	return code.substr(i, (j - i) if j > 0 else code.length() - i)


static func match_paren(src: String, open: int) -> int:
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


static func split_args(s: String) -> Array[String]:
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


static func method_info(gs: GDScript, name: String) -> Variant:
	for m in gs.get_script_method_list():
		if str(m.get("name", "")) == name:
			return m
	return null
