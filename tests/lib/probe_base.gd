class_name ProbeBase
extends Node

# 源码级测试探针基类：
# 提供断言收集、测试结果汇总与退出管理，并转发静态代码分析工具（ScanUtil）。
# 派生类需继承此类并覆写 probe_id() 方法返回探针标识（如 "L5"）。
#
# 架构设计说明：
# - 纯文本/路径解析函数统一定义在 ScanUtil 中，解耦 Node 场景依赖，便于单测与 -s 模式复用。
# - 本基类提供同名转发方法（如 _read()），保持探针代码风格简洁统一。
#
# 测试判定与退出规范：
# - 全部断言通过时打印 "KH <id> PROBE: ALL-OK" 并以退出码 0 退出；
# - 任一断言失败时打印 "KH <id> PROBE: FAIL | <失败原因列表>" 并以退出码 1 退出。
# - CI 脚本以控制台输出中的 ALL-OK 标记作为通过判定，不得仅依据进程退出码。
#
# 异常处理注意事项：
# - GDScript 在发生运行时错误（如空引用）时会中断当前函数并恢复调用方执行，
#   可能导致后续断言被跳过却依然打印 ALL-OK（假阳性漏检）。
# - 因此重要断言前应先校验引用有效性（如 _check(node != null)），或在测试块末尾设置执行完成标志。

var _failures: Array[String] = []


# 子类必须覆写：返回探针短标识（如 "L5"），用于生成汇总与判定日志。
func probe_id() -> String:
	push_error("ProbeBase: 子类未覆写 probe_id()")
	return ""


# 记录单条断言结果。ok 为 false 时将 msg 记录至失败列表。
func _check(ok: bool, msg: String) -> void:
	if not ok:
		_failures.append(msg)


# 打印测试块汇总：若本步骤无新增失败输出 ✓，否则输出 ✗。
# 参数 fails_before：本测试步骤开始前 _failures 数组的初始长度。
func _summary(fails_before: int, msg: String) -> void:
	print("[%s] " % probe_id() + ("✓ " if _failures.size() == fails_before else "✗ ") + msg)


func _finish() -> void:
	if _failures.is_empty():
		print("KH %s PROBE: ALL-OK" % probe_id())
		get_tree().quit(0)
	else:
		print("KH %s PROBE: FAIL | %s" % [probe_id(), "; ".join(_failures)])
		get_tree().quit(1)


# ── 静态代码扫描接口转发（底层实现在 ScanUtil）──
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

# 仅匹配行首定义的顶层函数体（防止内部类同名方法干扰），输入 code 需为保留缩进的 code_view。
func _top_func_body(code: String, name: String) -> String:
	return ScanUtil.top_func_body(code, name)

func _match_paren(src: String, open: int) -> int:
	return ScanUtil.match_paren(src, open)

func _split_args(s: String) -> Array[String]:
	return ScanUtil.split_args(s)

func _method_info(gs: GDScript, name: String) -> Variant:
	return ScanUtil.method_info(gs, name)
