extends SceneTree

# 跨语言黄金夹具探针(`-s`,headless):JS 编辑器产出的字节 → GDScript 解 → 重编码必须**逐字节相等**。
# 夹具与生产命令见 tests/fixtures/cyrm/README.md(生成脚本已随浏览器编辑器退役;夹具冻结)。
# 去掉什么它才会红:
#   ① 调色板顺序不再按「描述符首次出现」⇒ 无压缩夹具的字节相等断言红;
#   ② 头部字段/层块顺序/压缩位写错 ⇒ 字节相等或 compression 断言红;
#   ③ legacy 读时迁移规则漂了 ⇒ v4_legacy_migrated.cyrm 的字节比对红;
#   ④ v3 文本/旧字母格式迁移漂了(16px 展开、spawn÷2)⇒ v4_from_*.cyrm 比对红;
#   ⑤ 真实地图(maps/*.cyrm)解不开或重编码不稳定 ⇒ ⑤ 组红。
# ★ 它证明的是「GDScript 与 JS 的字节契约一致」,不证明编辑器 UI 能用(UI 见 tests/probe/editor_*)。

const EXPECTED_CHECKS := 26
const FIXTURES := "res://tests/fixtures/cyrm"

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)
		print("  ✗ " + msg)


func _initialize() -> void:
	for p in ["res://core/editor/editor_codec.gd", "res://core/editor/editor_v3.gd",
			"res://core/editor/editor_legacy.gd", "res://core/editor/editor_map.gd"]:
		if load(p) == null:
			print("CYRM GOLDEN PROBE: FAIL | 空载守卫 load(%s) 为 null(-s 不 quit 会挂死)" % p)
			quit(1)
			return
	if not DirAccess.dir_exists_absolute(FIXTURES):
		print("CYRM GOLDEN PROBE: FAIL | 夹具目录不存在 %s" % FIXTURES)
		quit(1)
		return

	_check_uncompressed_fixtures()
	_check_deflate_fixture()
	_check_legacy_fixture()
	_check_max_fixture()
	_check_v3_fixtures()
	_check_real_maps()

	if _checks < EXPECTED_CHECKS:
		print("CYRM GOLDEN PROBE: FAIL | 只跑了 %d 条 < %d(脚本中途中止)" % [_checks, EXPECTED_CHECKS])
		quit(1)
		return
	if not _fails.is_empty():
		print("CYRM GOLDEN PROBE: FAIL(%d/%d)" % [_fails.size(), EXPECTED_CHECKS])
		for f in _fails:
			print("  - " + f)
		quit(1)
		return
	print("CYRM GOLDEN PROBE: ALL-OK(%d 条断言)" % _checks)
	quit(0)


func _read_fixture(name: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(FIXTURES.path_join(name))


func _read_text(name: String) -> String:
	return FileAccess.get_file_as_string(FIXTURES.path_join(name))


func _roundtrip(name: String) -> Dictionary:
	var raw := _read_fixture(name)
	if raw.is_empty():
		return {"ok": false, "error": "夹具 %s 读不到/为空" % name}
	var dec := EditorCodec.decode_map(raw)
	if not bool(dec["ok"]):
		return {"ok": false, "error": "夹具 %s 解码失败: %s" % [name, dec["error"]]}
	var enc := EditorCodec.encode_map(dec["map"], {"compress": false})
	if not bool(enc["ok"]):
		return {"ok": false, "error": "夹具 %s 重编码失败: %s" % [name, enc["error"]]}
	return {"ok": true, "raw": raw, "decoded": dec["map"], "bytes": enc["bytes"]}


func _check_uncompressed_fixtures() -> void:
	# 1×1 手推 golden:CRC 之外每个字节都能从规格推出来;总长 181。
	var r1 := _roundtrip("v4_golden_1x1.cyrm")
	_chk(bool(r1["ok"]), "① v4_golden_1x1 解码+重编码: %s" % r1.get("error", ""))
	if bool(r1["ok"]):
		var raw: PackedByteArray = r1["raw"]
		_chk(raw.size() == 181, "① v4_golden_1x1 长度 %d(期望 181)" % raw.size())
		_chk(raw == r1["bytes"], "① v4_golden_1x1 逐字节相等(实得 %d 字节,期望 %d)" % [
				(r1["bytes"] as PackedByteArray).size(), raw.size()])
		var m: Dictionary = r1["decoded"]
		_chk(m["comments"] == ["hi"] and m["players"] == [{"x": 1, "y": 2}],
				"① v4_golden_1x1 meta: comments=%s players=%s" % [
					JSON.stringify(m["comments"]), JSON.stringify(m["players"])])

	# 稀疏 layer_flags:只有场景层,其余 6 层必须是 null(不能被「补空层」)。
	var r2 := _roundtrip("v4_sparse_scene_only.cyrm")
	_chk(bool(r2["ok"]), "② v4_sparse_scene_only 解码+重编码: %s" % r2.get("error", ""))
	if bool(r2["ok"]):
		_chk((r2["raw"] as PackedByteArray) == r2["bytes"], "② sparse 逐字节相等")
		var layers: Array = (r2["decoded"] as Dictionary)["layers"]
		_chk(layers[0] == null and layers[1] != null and layers[2] == null and layers[3] == null
				and layers[4] == null and layers[5] == null and layers[6] == null,
				"② sparse 层 0/2/3/4/5/6 为 null、层 1 存在")

	# 七层齐全:7 个层对象都在,纹理/颜色 kind 与层号一致。
	var r3 := _roundtrip("v4_mixed_7layers.cyrm")
	_chk(bool(r3["ok"]), "③ v4_mixed_7layers 解码+重编码: %s" % r3.get("error", ""))
	if bool(r3["ok"]):
		_chk((r3["raw"] as PackedByteArray) == r3["bytes"], "③ mixed 逐字节相等")
		var kinds: Array = []
		for layer in (r3["decoded"] as Dictionary)["layers"]:
			kinds.append(null if layer == null else String((layer as Dictionary)["kind"]))
		_chk(kinds == ["tex", "tex", "tex", "color", "color", "color", "color"],
				"③ mixed 七层 kind=%s" % str(kinds))


func _check_deflate_fixture() -> void:
	var raw := _read_fixture("v4_mixed_7layers_deflate.cyrm")
	_chk(raw.size() > 20 and raw[5] == 1, "④ 压缩夹具 compression 位=%d(期望 1)" % (raw[5] if raw.size() > 5 else -1))
	var dec := EditorCodec.decode_map(raw)
	_chk(bool(dec["ok"]), "④ 压缩夹具可解: %s" % dec.get("error", ""))
	if bool(dec["ok"]):
		var enc := EditorCodec.encode_map(dec["map"], {"compress": false})
		_chk(bool(enc["ok"]) and (enc["bytes"] as PackedByteArray) == _read_fixture("v4_mixed_7layers.cyrm"),
				"④ 压缩夹具解→无压缩重编码 == 无压缩孪生夹具")


func _check_legacy_fixture() -> void:
	var dec := EditorCodec.decode_map(_read_fixture("v4_legacy_tex.cyrm"))
	_chk(bool(dec["ok"]), "⑤ legacy 夹具可解: %s" % dec.get("error", ""))
	if not bool(dec["ok"]):
		return
	var m: Dictionary = dec["map"]
	# 文件里就该有 legacy id:解码端**不**迁移(decodeMap 不迁移是格式契约)。
	var scene: PackedInt32Array = (m["layers"][1] as Dictionary)["desc"]
	var has_legacy := false
	for d in scene:
		var tex := EditorDesc.tex_of(d)
		if tex == 2 or tex == 3 or tex == 4 or tex == 5 or tex == 16 or tex == 17 or tex == 18:
			has_legacy = true
			break
	_chk(has_legacy, "⑤ 解码后内存里仍是 legacy 纹理 id(decode 不迁移)")
	# 未迁移直接编码:validateMap 必须把它当 error 硬拒。
	var bad := EditorCodec.encode_map(m, {"compress": false})
	_chk(not bool(bad["ok"]) and String(bad.get("error", "")).contains("不在 tile_defs"),
			"⑤ 未迁移 legacy id 直接 encode 被拒: %s" % bad.get("error", ""))
	# 迁移后重编码 == JS 侧迁移后的期望字节。
	EditorLegacy.migrate_map(m)
	var enc := EditorCodec.encode_map(m, {"compress": false})
	_chk(bool(enc["ok"]) and (enc["bytes"] as PackedByteArray) == _read_fixture("v4_legacy_migrated.cyrm"),
			"⑤ legacy 迁移后重编码 == v4_legacy_migrated.cyrm")


func _check_max_fixture() -> void:
	# 最大尺寸边界:400×300 格 = 1600×1200 子格 = 1,920,000 子格/层(格式允许的上界)。空图 deflate 后很小。
	var raw := _read_fixture("v4_max_400x300_empty.cyrm")
	_chk(raw.size() > 20 and raw[5] == 1, "⑧ 最大尺寸夹具是 deflate 件(compression=%d)" % (raw[5] if raw.size() > 5 else -1))
	var dec := EditorCodec.decode_map(raw)
	_chk(bool(dec["ok"]), "⑧ 400×300 最大尺寸空图可解: %s" % dec.get("error", ""))
	if bool(dec["ok"]):
		var m: Dictionary = dec["map"]
		var n := 1600 * 1200
		var layers: Array = m["layers"]
		_chk(int(m["sub_cols"]) == 1600 and int(m["sub_rows"]) == 1200
				and layers.size() == 7
				and (layers[0] as Dictionary)["desc"].size() == n
				and (layers[3] as Dictionary)["rgba"].size() == n
				and layers[4] == null,
				"⑧ 400×300:sub 1600×1200、四层各 %d 子格、层 4-6 null" % n)


func _check_v3_fixtures() -> void:
	var v3_text := _read_text("v3_simple.txt")
	var parsed := EditorV3.parse_v3_text(v3_text)
	_chk(bool(parsed["ok"]), "⑥ v3 文本解析: %s" % parsed.get("error", ""))
	if bool(parsed["ok"]):
		var migrated: Dictionary = EditorV3.migrate_v3(parsed["parsed"])
		var enc := EditorCodec.encode_map(migrated, {"compress": false})
		_chk(bool(enc["ok"]) and (enc["bytes"] as PackedByteArray) == _read_fixture("v4_from_v3_simple.cyrm"),
				"⑥ v3 迁移后重编码 == v4_from_v3_simple.cyrm")

	var legacy_text := _read_text("legacy_letters.txt")
	var lp := EditorV3.parse_v3_text(legacy_text)
	_chk(bool(lp["ok"]), "⑦ 旧字母格式解析: %s" % lp.get("error", ""))
	if bool(lp["ok"]):
		var lm: Dictionary = EditorV3.migrate_v3(lp["parsed"])
		var enc2 := EditorCodec.encode_map(lm, {"compress": false})
		_chk(bool(enc2["ok"]) and (enc2["bytes"] as PackedByteArray) == _read_fixture("v4_from_legacy_letters.cyrm"),
				"⑦ 旧字母格式迁移后重编码 == v4_from_legacy_letters.cyrm")


func _check_real_maps() -> void:
	var maps: Array[String] = []
	var d := DirAccess.open("res://maps")
	if d != null:
		for f in d.get_files():
			if f.ends_with(".cyrm"):
				maps.append("res://maps".path_join(f))
	if maps.is_empty():
		_chk(false, "⑤ res://maps 下没有 .cyrm")
		return
	var all_ok := true
	var stable := true
	for path in maps:
		var raw := FileAccess.get_file_as_bytes(path)
		var dec := EditorCodec.decode_map(raw)
		if not bool(dec["ok"]):
			all_ok = false
			_chk(false, "⑤ 真实地图 %s 解码失败: %s" % [path, dec["error"]])
			continue
		var m: Dictionary = dec["map"]
		EditorLegacy.migrate_map(m)
		var enc := EditorCodec.encode_map(m, {"compress": false})
		if not bool(enc["ok"]):
			all_ok = false
			_chk(false, "⑤ 真实地图 %s 重编码失败: %s" % [path, enc["error"]])
			continue
		var dec2 := EditorCodec.decode_map(enc["bytes"])
		if not bool(dec2["ok"]):
			all_ok = false
			continue
		var enc2 := EditorCodec.encode_map(dec2["map"], {"compress": false})
		if not bool(enc2["ok"]) or (enc2["bytes"] as PackedByteArray) != (enc["bytes"] as PackedByteArray):
			stable = false
	_chk(all_ok, "⑤ 真实地图全部可解且可重编码(%d 份)" % maps.size())
	_chk(stable, "⑤ 真实地图重编码稳定(解→编→解→编 字节相等)")
