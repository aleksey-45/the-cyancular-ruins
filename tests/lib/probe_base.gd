class_name ProbeBase
extends Node

# 源码级探针的**运行环境**:断言账本 + 汇总/收尾 + 一套扫描词汇(转发给 ScanUtil)。
# 用法:`extends ProbeBase`,然后覆写 `probe_id() -> String`(如返回 "L5")。
#
# ★ 为什么算法在 ScanUtil 而不在这里:那些是纯字符串/路径函数,不需要 Node,单独放便于
#   单测与 `-s` 阶段复用。这里保留同名转发,是为了**探针正文读起来还是 `_read(...)`
#   而不是 `ScanUtil.read(...)`** —— 正文里这类调用有上百处,包一层比到处改调用点值。
#
# ★ 收尾约定(仓内 CI 判据):**必须**打印 "KH <id> PROBE: ALL-OK" 且退出码 0,失败打印
#   "KH <id> PROBE: FAIL | <原因;原因>" 并退出 1。判据是 **grep 这行文本**,不能只看退出码
#   —— 探针中途脚本报错时 `--quit-after` 仍以 exit 0 退出且**不会**打印 ALL-OK,
#   只看退出码会把"没跑完"读成"通过"。

var _failures: Array[String] = []


# ★ 子类**必须**覆写:返回本探针的短名(如 "L5"),用于拼 ALL-OK / FAIL / [L5] 汇总行。
#   漏覆写会 push_error 且拼出 "KH  PROBE: ALL-OK" —— 那句 grep 不到 → 门变红,
#   不会静默变成"通过"(这正是想要的失败方向)。
func probe_id() -> String:
	push_error("ProbeBase: 子类未覆写 probe_id()")
	return ""


# 记一条断言失败。仓内惯例:第二条实参写**人话**——断言在守什么、坏了会怎样。
func _check(ok: bool, msg: String) -> void:
	if not ok:
		_failures.append(msg)


# 每条断言的汇总行:**本次断言全绿**才打 ✓,否则打 ✗。旧写法是裸 print,失败运行时
# 汇总行照样打印(措辞还像报喜),读者容易把"打印了 N 行 [L5] ..."读成"N 条都过了"。
# 参数 = 该条断言开始前的 _failures.size()(取差值判本组是否有新增失败)。
func _summary(fails_before: int, msg: String) -> void:
	print("[%s] " % probe_id() + ("✓ " if _failures.size() == fails_before else "✗ ") + msg)


func _finish() -> void:
	if _failures.is_empty():
		print("KH %s PROBE: ALL-OK" % probe_id())
		get_tree().quit(0)
	else:
		print("KH %s PROBE: FAIL | %s" % [probe_id(), "; ".join(_failures)])
		get_tree().quit(1)


# ── 扫描词汇(实现在 ScanUtil;见该文件头)──
func _read(path: String) -> String:
	return ScanUtil.read(path)

func _collect(roots: Array) -> Array[String]:
	return ScanUtil.collect(roots)

func _walk(dir_path: String, out: Array[String]) -> void:
	ScanUtil.walk(dir_path, out)

func _strip_line_comment(line: String) -> String:
	return ScanUtil.strip_line_comment(line)

func _code_only(src: String) -> String:
	return ScanUtil.code_only(src)

func _code_view(src: String) -> String:
	return ScanUtil.code_view(src)

func _func_body(code: String, name: String) -> String:
	return ScanUtil.func_body(code, name)

func _match_paren(src: String, open: int) -> int:
	return ScanUtil.match_paren(src, open)

func _split_args(s: String) -> Array[String]:
	return ScanUtil.split_args(s)

func _method_info(gs: GDScript, name: String) -> Variant:
	return ScanUtil.method_info(gs, name)
