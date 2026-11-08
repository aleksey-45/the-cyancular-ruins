class_name EditorIO
extends RefCounted

# P2 读写门面:磁盘字节 ↔ 地图字典(契约见 .tmp/editor-p2-contract.md §3)。
# ★ 读入口只有一个:二进制 v4 / v3 文本 / 旧字母格式都在这里分流,且**读成功后必须** EditorLegacy.migrate_map
#   (二进制分支)—— 与 JS 的四个读入口同规:迁移只发生在读时,内存即干净,写盘永远写迁移后的图。
#   文本分支走 EditorV3.parse_v3_text(它自己认旧字母格式)+ EditorV3.migrate_v3(拍 desc 时已迁 legacy id)。
# ★ 写入口先 EditorValidate.validate_map:只拒 errors、不拒 warnings(与 encode_map 同口径);errors 非空**不写盘**。
# ★ res:// 导出后只读 ⇒ 本模块只写 user:// 与 exe 同目录;读可以读 res://。
# ★ 禁止 RegEx(客户端导出裁剪了 regex 模块)。
# ★ 失败一律 {ok:false,error}(写入口拒写时额外带 errors/warnings),不 push_error 当失败路径。

const DEFAULT_DIR: String = "user://maps"
const RES_DIR: String = "res://maps"
const MAP_EXT: String = ".cyrm"


# 读一个地图文件。二进制按 magic 分流(decode_map 只认 v4),文本按 v3 标记行区分 v3 / 旧字母格式。
# 成功 {ok:true, map:Dictionary, warnings:Array[String], source:"v4"|"v3"|"legacy"};失败 {ok:false, error:String}。
static func open_path(path: String) -> Dictionary:
	if path.is_empty():
		return _fail("openPath: 路径为空")
	if not FileAccess.file_exists(path):
		return _fail("openPath: 文件不存在: " + path)
	var data := FileAccess.get_file_as_bytes(path)
	if data.is_empty():
		return _fail("openPath: 文件为空或读取失败: " + path)
	if _is_v4_data(data):
		var dec := EditorCodec.decode_map(data)
		if not bool(dec.get("ok", false)):
			return _fail("openPath: .cyrm 解码失败(%s): %s" % [path, String(dec.get("error", ""))])
		var map: Dictionary = dec["map"]
		EditorLegacy.migrate_map(map)
		return _opened(map, "v4")
	var text := data.get_string_from_utf8()
	var parsed := EditorV3.parse_v3_text(text)
	if not bool(parsed.get("ok", false)):
		return _fail("openPath: 既不是 v4 二进制也不是可识别的编辑器文本(%s): %s"
				% [path, String(parsed.get("error", ""))])
	var source := "v3" if EditorV3.is_v3_text(text) else "legacy"
	var migrated: Dictionary = EditorV3.migrate_v3(parsed["parsed"])
	if migrated.is_empty():
		return _fail("openPath: 文本迁移失败(尺寸非法): " + path)
	return _opened(migrated, source)


# 保存一张地图到 path。先 validate(只拒 errors)→ encode(默认压缩,opts 透传)→ 自动建父目录 → 写盘。
# 成功 {ok:true, path:String, bytes:int, warnings:Array[String]};
# 校验拒写 {ok:false, error, errors:Array[String], warnings:Array[String]};其它失败 {ok:false, error}。
static func save_path(path: String, map: Dictionary, opts: Dictionary = {}) -> Dictionary:
	if path.is_empty():
		return _fail("savePath: 路径为空")
	if path.begins_with("res://"):
		return _fail("savePath: 不能写 res://(导出后只读): %s —— 请存到 user:// 或 exe 同目录" % path)
	var report := EditorValidate.validate_map(map)
	var errors: Array[String] = _strings(report.get("errors", []))
	var warnings: Array[String] = _strings(report.get("warnings", []))
	if not errors.is_empty():
		return {
			"ok": false,
			"error": "savePath: 地图校验未通过,未写盘 —— " + ";".join(errors),
			"errors": errors,
			"warnings": warnings,
		}
	var enc := EditorCodec.encode_map(map, opts)
	if not bool(enc.get("ok", false)):
		return _fail("savePath: 编码失败: " + String(enc.get("error", "")))
	var bytes: PackedByteArray = enc["bytes"]
	var parent := path.get_base_dir()
	if not parent.is_empty() and not DirAccess.dir_exists_absolute(parent):
		var mk := DirAccess.make_dir_recursive_absolute(parent)
		if mk != OK:
			return _fail("savePath: 建目录失败(%s): %s" % [parent, error_string(mk)])
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return _fail("savePath: 打不开写入目标(%s): %s"
				% [path, error_string(FileAccess.get_open_error())])
	f.store_buffer(bytes)
	var write_err := f.get_error()
	f.close()
	if write_err != OK:
		return _fail("savePath: 写盘失败(%s): %s" % [path, error_string(write_err)])
	return {"ok": true, "path": path, "bytes": bytes.size(), "warnings": warnings}


# 默认保存落点:user://maps/<净化后的名字>.cyrm(名字净化规则单一真相源 = EditorGeometry.sanitize_name)。
static func default_target(name: String) -> String:
	return DEFAULT_DIR.path_join(EditorGeometry.sanitize_name(name) + MAP_EXT)


# 三处地图目录的 *.cyrm:user://maps、res://maps、exe 同目录。
# 用 ProjectSettings.globalize_path 的绝对路径去重(导出后 res:// 与 exe 目录可能是同一处),
# 展示串保留原前缀(res:// 仍是 res://),最后按展示串排序。
static func list_maps() -> Array[String]:
	var dirs: Array[String] = [DEFAULT_DIR, RES_DIR, OS.get_executable_path().get_base_dir()]
	var by_abs: Dictionary = {}
	for dir in dirs:
		if dir.is_empty():
			continue
		var d := DirAccess.open(dir)
		if d == null:
			continue
		for file_name in d.get_files():
			if not file_name.ends_with(MAP_EXT):
				continue
			var p := dir.path_join(file_name)
			var key := ProjectSettings.globalize_path(p)
			if key.is_empty():
				key = p
			if not by_abs.has(key):
				by_abs[key] = p
	var out: Array[String] = []
	for key in by_abs:
		out.append(String(by_abs[key]))
	out.sort()
	return out


# P3「导出」的目标目录动作:dir + <净化后的 base_name>.cyrm;校验/编码/写盘全走 save_path(只拒 errors)。
# 成功 {ok:true, path, dir, bytes, warnings};失败给原因(目录空 / res:// 只读 / 权限)。
static func export_to_dir(dir: String, map: Dictionary, base_name: String, opts: Dictionary = {}) -> Dictionary:
	if dir.is_empty():
		return _fail("exportToDir: 目标目录为空")
	if dir.begins_with("res://"):
		return _fail("exportToDir: 不能写 res://(导出后只读): %s —— 请选 user://maps 或 exe 同目录" % dir)
	var target := dir.path_join(EditorGeometry.sanitize_name(base_name) + MAP_EXT)
	var res := save_path(target, map, opts)
	if bool(res.get("ok", false)):
		res["dir"] = dir
	return res


# P3「复制到 exe 同目录」:写 exe 所在目录;只读位置写失败时把原因交回(绝不静默成功)。
static func copy_to_exe_dir(map: Dictionary, base_name: String, opts: Dictionary = {}) -> Dictionary:
	var exe_dir := OS.get_executable_path().get_base_dir()
	if exe_dir.is_empty():
		return _fail("copyToExeDir: 取不到 exe 所在目录")
	var res := export_to_dir(exe_dir, map, base_name, opts)
	if not bool(res.get("ok", false)):
		res["error"] = "copyToExeDir: 写 exe 同目录失败(%s): %s" % [exe_dir, String(res.get("error", ""))]
	return res


# ── 内部 ──

# 二进制 / 文本分流:EditorCodec 只提供 decode_map(没有 is_v4_data),这里只判 4 字节 magic 前缀;
# magic 的单一真相源仍是 EditorCodec.MAGIC,其余头部/CRC/尺寸/层校验全部交给 decode_map。
static func _is_v4_data(data: PackedByteArray) -> bool:
	if data.size() < EditorCodec.MAGIC.size():
		return false
	for i in EditorCodec.MAGIC.size():
		if data[i] != int(EditorCodec.MAGIC[i]):
			return false
	return true


# warnings 取 validate_map 的报告(纯报告、不阻止打开;errors 在读路径不拦 —— 坏图也需要能打开修)。
static func _opened(map: Dictionary, source: String) -> Dictionary:
	var report := EditorValidate.validate_map(map)
	return {
		"ok": true,
		"map": map,
		"warnings": _strings(report.get("warnings", [])),
		"source": source,
	}


static func _fail(msg: String) -> Dictionary:
	return {"ok": false, "error": msg}


# 把 validate_map 返回的 Array[String] 统一成显式 Array[String](契约返回类型,别把 Variant 漏出去)。
static func _strings(src: Variant) -> Array[String]:
	var out: Array[String] = []
	if src is Array:
		for item in src:
			out.append(String(item))
	return out
