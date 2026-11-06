class_name ProbeBase
extends Node


var _failures: Array[String] = []


func probe_id() -> String:
	push_error("ProbeBase: 子类未覆写 probe_id()")
	return ""


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_failures.append(msg)


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

func _top_func_body(code: String, name: String) -> String:
	return ScanUtil.top_func_body(code, name)

func _match_paren(src: String, open: int) -> int:
	return ScanUtil.match_paren(src, open)

func _split_args(s: String) -> Array[String]:
	return ScanUtil.split_args(s)

func _method_info(gs: GDScript, name: String) -> Variant:
	return ScanUtil.method_info(gs, name)
