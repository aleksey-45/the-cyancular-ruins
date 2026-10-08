class_name ScanUtil
extends RefCounted

# 源码级测试探针静态分析工具类：
# 提供源文件读取、目录递归遍历、去除注释、参数与括号匹配分析及函数体提取等静态扫描能力。
# 纯函数设计，不依赖 Node 或 Autoload 单例，适用于无头脚本（-s）与场景模式。

# 读取 res:// 路径下的文本文件，文件不存在或打开失败时返回空字符串。
# 调用方应校验返回值非空，防止因文件缺失导致后续静态断言失效。
static func read(path: String) -> String:
	if not ResourceLoader.exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_as_text() if f != null else ""


# 递归收集指定根目录下所有的 .gd 与 .tscn 文件路径（自动忽略点开头的隐藏目录）
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


# 剔除单行中字符串字面量以外的行尾注释（从 '#' 至行尾）。
# 正确处理转义引号，避免将字符串内容误截断为注释。
static func strip_line_comment(line: String) -> String:
	var quote := ""            # 当前所处字符串的引号类型("" = 不在字符串里)
	var j := 0
	while j < line.length():
		var ch := line[j]
		if quote != "":
			if ch == "\\":
				j += 1        # 转义字符：跳过后续字符，防止将 \" 识别为字符串结束
			elif ch == quote:
				quote = ""
		elif ch == "\"" or ch == "'":
			quote = ch
		elif ch == "#":
			return line.substr(0, j)
		j += 1
	return line


# 生成纯代码文本：剥离整行注释与行尾注释，去除首尾空白并移除空行。
# 适用于校验函数调用是否存在、特定废弃逻辑是否已被清理等断言。
static func code_only(src: String) -> String:
	var out: Array[String] = []
	for line in src.split("\n"):
		var s: String = strip_line_comment(line).strip_edges()
		if s.is_empty():
			continue
		out.append(s)
	return "\n".join(out)


# 生成保留缩进的代码视图：剥离注释并去除行尾空白，保留行首缩进层级。
# 适用于需要依据缩进判断代码嵌套块范围的测试断言。
static func code_view(src: String) -> String:
	var out: Array[String] = []
	for raw in src.split("\n"):
		var s := strip_line_comment(raw)
		if s.strip_edges().is_empty():
			continue
		out.append(s.rstrip(" \t"))
	return "\n".join(out)


# 提取指定函数名的函数体代码（从函数定义开始到下一个 func 出现前；未找到返回空串）。
static func func_body(code: String, name: String) -> String:
	var i := code.find("func " + name + "(")
	if i < 0:
		return ""
	var j := code.find("\nfunc ", i + 1)
	return code.substr(i, (j - i) if j > 0 else code.length() - i)


## 提取指定函数名的顶层函数体（仅匹配行首列 0 的函数定义）。
## 用于避免在文件包含内部类时，误将内部类中的同名方法匹配为顶层函数。
## 注意事项：输入参数 code 必须是保留缩进的 code_view 文本。
static func top_func_body(code: String, name: String) -> String:
	var i := code.find("\nfunc " + name + "(")
	if i < 0:
		return ""
	i += 1
	var j := code.find("\nfunc ", i + 1)
	return code.substr(i, (j - i) if j > 0 else code.length() - i)


# 查找与指定左括号 open 位置匹配的右括号索引（忽略字符串内部字符；未找到返回 -1）。
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


# 按顶层逗号切分函数实参列表（忽略嵌套括号及字符串内部的逗号）
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


# 从脚本方法列表中查询指定方法元数据（未找到返回 null）。
# 相比字符串包含匹配，通过方法列表校验能避免注释或同名字段引起的误判。
static func method_info(gs: GDScript, name: String) -> Variant:
	for m in gs.get_script_method_list():
		if str(m.get("name", "")) == name:
			return m
	return null
