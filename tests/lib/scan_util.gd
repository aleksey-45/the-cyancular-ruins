class_name ScanUtil
extends RefCounted

# 源码级探针的**扫描算法**:读文件、走目录、剥注释视图、括号/实参切分、取函数体。
# ★ 纯静态、纯函数(入参进、结果出),不碰 Node / autoload —— 所以它在 `-s` 阶段也能用,
#   也便于单独验。**断言账本**在 ProbeBase(那个必须 extends Node,因为要 get_tree())。
# ★ 这些函数此前在 `tests/kh_l{1,3,4,5,6}_probe.gd` 里各抄一份(阶段 6.1 抽出)。

# 读 res:// 下的源文本;不存在(或打不开)返回 ""。调用方**必须**自己判空并报红 ——
# 静默返回 "" 是这类探针最典型的失明方式(读不到源文件 → 所有 contains 断言恒假/恒真)。
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


# 删掉一行里字符串字面量之外的 `#` 起、到行尾的注释(引号/反斜杠转义的处理与 match_paren 同法)。
# 行尾注释不是代码,却能把被删掉的调用名重新"喂"给按源码文本判在位的断言。
# ⚠ 已知边界:`"""…"""` 多行字符串**不跨行带状态**(本函数逐行调用)—— 它第 2 行起若出现 `#`,
#    会被当成注释起点截断。本仓唯一的多行字符串是 GLSL 着色器正文(水面板),里面没有 `#`,暂无影响。
static func strip_line_comment(line: String) -> String:
	var quote := ""            # 当前所处字符串的引号类型("" = 不在字符串里)
	var j := 0
	while j < line.length():
		var ch := line[j]
		if quote != "":
			if ch == "\\":
				j += 1        # 转义:连同下一字符一起跳过,免得 \" 被当成字符串结束
			elif ch == quote:
				quote = ""
		elif ch == "\"" or ch == "'":
			quote = ch
		elif ch == "#":
			return line.substr(0, j)
		j += 1
	return line


# 剥注释视图(整行注释与**行尾注释**都删,再 strip_edges、丢空行)。供"在位/唯一挂载点/顺序"
# 类断言用:注释讲的是动机,不是代码。
# ⚠ 只删**整行**注释是不够的(旧做法,实测):一句提到退役名的行尾注释能让「零引用」断言假红
#    (代码一行没改)。kh_l3 的旧版只剥整行,阶段 6.1 收口前**核过**它仅有的 2 条「零引用」断言
#    都盯代码串(`func _process`),两种视图在它那儿等价 —— 故连它一起统一到这里。
# ⚠ 两个方向**不单调**,别以为"剥得越干净越严":剥掉行尾注释会让「在位」类断言**更严**、
#    让「零引用」类断言**更松**。新写断言时想清楚它属于哪一类。
static func code_only(src: String) -> String:
	var out: Array[String] = []
	for line in src.split("\n"):
		var s: String = strip_line_comment(line).strip_edges()
		if s.is_empty():
			continue
		out.append(s)
	return "\n".join(out)


# 同上,但**保留行首缩进**(只 rstrip 行尾空白;丢掉只剩空白的行)。给需要按缩进做位置
# 分析的探针用(kh_l6 的"块在哪一层"类断言靠缩进定块)。
# 为什么不能只看裸文本:一句提到被删调用的**注释**能把"在位"类断言喂绿,反过来也能把
# "零引用"类断言弄红 —— 注释不是代码。
static func code_view(src: String) -> String:
	var out: Array[String] = []
	for raw in src.split("\n"):
		var s := strip_line_comment(raw)
		if s.strip_edges().is_empty():
			continue
		out.append(s.rstrip(" \t"))
	return "\n".join(out)


# 取某函数的函数体(从头到下一个 func 之前;找不到返回空串)。判据必须落在**体内**,
# 否则一条同名的调用/注释就能满足断言。
static func func_body(code: String, name: String) -> String:
	var i := code.find("func " + name + "(")
	if i < 0:
		return ""
	var j := code.find("\nfunc ", i + 1)
	return code.substr(i, (j - i) if j > 0 else code.length() - i)


# 与 open 处 '(' 配对的 ')' 下标(跳过字符串内的括号;找不到返回 -1)
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


# 顶层逗号切分实参(括号/方括号/花括号内、字符串内的逗号不算分隔符)
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


# 脚本方法表里找方法(返回 null = 没有)。用方法表而非文本 contains:
# 函数名出现在注释/字符串里时文本法会假绿;而 `has_method()` 对**脚本资源**看不见它自己的
# 实例方法(L4 撞过这个坑),故一律走 get_script_method_list()。
static func method_info(gs: GDScript, name: String) -> Variant:
	for m in gs.get_script_method_list():
		if str(m.get("name", "")) == name:
			return m
	return null
