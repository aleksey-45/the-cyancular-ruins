class_name ProbeBase
extends Node

# 源码级探针的运行环境:断言账本 + 汇总/收尾 + 扫描词汇(实现在 `ScanUtil`;这里保留同名转发,让探针正文
# 读起来仍是 `_read(...)`)。用法:`extends ProbeBase` 并覆写 `probe_id()` —— 漏覆写会 push_error 且拼出
# "KH  PROBE: ALL-OK"(grep 不到)⇒ 门变红而不会静默变绿,这正是想要的失败方向。
# 收尾约定:必须打印 "KH <id> PROBE: ALL-OK" 且退出码 0,失败打 "KH <id> PROBE: FAIL | 原因;原因" 退出 1;
# 判据是 grep 这行文本,**不是**退出码。
# ★★ 但 grep 到那行只证明"没有任何断言失败",**不证明每条断言都跑过**:脚本错误只让出错的那个函数当场结束、
#    调用方继续(两种形状都照常打 ALL-OK),而 `_summary()` 的 ✓ 在"整组一条都没跑"时**也会打** ⇒ 两行一起被
#    读成通过。想让 ✓ 有意义:组内第一条断言要空转不了(先判非 null 再解引用),或末尾补一条自检(它没跑 ⇒ 缺一条)。

var _failures: Array[String] = []


func probe_id() -> String:
	push_error("ProbeBase: 子类未覆写 probe_id()")
	return ""


# 记一条断言失败。第二条实参写**人话**:断言在守什么、坏了会怎样。
func _check(ok: bool, msg: String) -> void:
	if not ok:
		_failures.append(msg)


# 每条断言的汇总行:本次**没有新增失败**才打 ✓(参数 = 该条断言开始前的 `_failures.size()`)。
func _summary(fails_before: int, msg: String) -> void:
	print("[%s] " % probe_id() + ("✓ " if _failures.size() == fails_before else "✗ ") + msg)


func _finish() -> void:
	if _failures.is_empty():
		print("KH %s PROBE: ALL-OK" % probe_id())
		get_tree().quit(0)
	else:
		print("KH %s PROBE: FAIL | %s" % [probe_id(), "; ".join(_failures)])
		get_tree().quit(1)


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

# 只认行首的顶层函数定义(内部类会同名骗过 `func_body`);`code` 必须来自 `_code_view`(保留缩进),不能用 `_code_only`。
func _top_func_body(code: String, name: String) -> String:
	return ScanUtil.top_func_body(code, name)

func _match_paren(src: String, open: int) -> int:
	return ScanUtil.match_paren(src, open)

func _split_args(s: String) -> Array[String]:
	return ScanUtil.split_args(s)

func _method_info(gs: GDScript, name: String) -> Variant:
	return ScanUtil.method_info(gs, name)
