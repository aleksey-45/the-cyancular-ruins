extends SceneTree

# P2 读写门面 EditorIO 冒烟守卫(`-s`,headless;可写 user://,结束时删自己造的文件)。
# 覆盖:① v4 7 层夹具读入 ② v4 legacy 夹具读时迁移 ③ v3 / 旧字母文本读入
#       ④ 坏文件失败给原因 ⑤ save→open→save 字节确定性 ⑥ validate errors 拒写且不落盘
#       ⑦ list_maps 三处来源 ⑧ default_target 名字净化与目录。
# 去掉什么会红(逐组):
#   ① open_path 解码错位 / 层结构或 meta 四段回读错 ⇒ 红。
#   ② open_path 不调 EditorLegacy.migrate_map ⇒ legacy id 残留在内存、保存字节 ≠ v4_legacy_migrated ⇒ 红。
#   ③ 文本分支 source 判错 / 不走 parse_v3_text + migrate_v3 ⇒ source、尺寸、spawn 坐标 ⇒ 红。
#   ④ 坏文件被当成合法图(ok:true)或 error 为空 ⇒ 红。
#   ⑤ save_path 的 encode 不确定 / 二次保存内容漂移 ⇒ 两次落盘字节不等 ⇒ 红。
#   ⑥ save_path 不先 validate、或 errors 后仍写盘 ⇒ 目标文件存在 ⇒ 红。
#   ⑦ list_maps 漏 res://maps / user://maps 来源、或不去重排序 ⇒ 红。
#   ⑧ default_target 漏 sanitize_name / 落错目录 / 漏 .cyrm ⇒ 红。
# ★ 期望值来自 tests/fixtures/cyrm/README.md 的确定性构图与本文件手算,不复用被测函数的返回值。

const EXPECTED_CHECKS := 47

const FIXTURES := "res://tests/fixtures/cyrm"
const PROBE_A := "user://maps/_editor_io_probe.cyrm"
const PROBE_B := "user://maps/_editor_io_probe2.cyrm"
const PROBE_LEGACY := "user://maps/_editor_io_legacy_probe.cyrm"
const PROBE_BAD_BIN := "user://maps/_editor_io_bad_bin.cyrm"
const PROBE_BAD_TEXT := "user://maps/_editor_io_bad_text.cyrm"
const PROBE_REJECT := "user://maps/_editor_io_reject.cyrm"
const LEGACY_TEX_IDS := [2, 3, 4, 5, 16, 17, 18]

var _fails: Array[String] = []
var _checks := 0


func _chk(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_fails.append(msg)
		print("  ✗ " + msg)


func _initialize() -> void:
	# ★ 空载守卫(仓规):load() 失败还往下走会在 null 上抛错,而 `-s` 抛错走不到 quit() ⇒ 进程永久挂起。
	for p in [
		"res://core/editor/editor_io.gd",
		"res://core/editor/editor_codec.gd",
		"res://core/editor/editor_legacy.gd",
		"res://core/editor/editor_v3.gd",
		"res://core/editor/editor_validate.gd",
		"res://core/editor/editor_map.gd",
		"res://core/editor/editor_desc.gd",
		"res://core/editor/editor_geometry.gd",
		"res://core/editor/editor_meta.gd",
		"res://core/editor/editor_constants.gd",
	]:
		if load(p) == null:
			print("EDITOR IO SMOKE: FAIL | 空载守卫 load(%s) 为 null(-s 不 quit 会挂死)" % p)
			quit(1)
			return

	_check_v4_mixed()
	_check_legacy_migration()
	_check_v3_texts()
	_check_deterministic_save()
	_check_bad_files()
	_check_validate_reject()
	_check_list_maps()
	_check_default_target()

	# 自清:只删本冒烟造的文件,user://maps 目录与其他地图不动。
	for p in [PROBE_A, PROBE_B, PROBE_LEGACY, PROBE_BAD_BIN, PROBE_BAD_TEXT, PROBE_REJECT]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)

	if _checks < EXPECTED_CHECKS:
		print("EDITOR IO SMOKE: FAIL | 只跑了 %d 条 < %d(脚本中途中止)" % [_checks, EXPECTED_CHECKS])
		quit(1)
		return
	if not _fails.is_empty():
		print("EDITOR IO SMOKE: FAIL(%d/%d)" % [_fails.size(), EXPECTED_CHECKS])
		for f in _fails:
			print("  - " + f)
		quit(1)
		return
	print(("EDITOR IO SMOKE: OK(%d 条断言):v4 7 层读入 · legacy 读时迁移 · v3/旧字母文本 · 坏文件 · "
			+ "保存确定性 · 校验拒写 · 三处地图目录 · 默认落点") % _checks)
	quit(0)


# ══ ① 读 res://tests/fixtures/cyrm/v4_mixed_7layers.cyrm:source=v4、7 层、meta 四段、层内容 ══
func _check_v4_mixed() -> void:
	var res := EditorIO.open_path(FIXTURES.path_join("v4_mixed_7layers.cyrm"))
	_chk(bool(res.get("ok", false)), "① 读 v4_mixed_7layers 应成功(实得 error=%s)" % res.get("error", ""))
	_chk(String(res.get("source", "")) == "v4",
			"① source 应 = \"v4\"(实得 \"%s\")" % res.get("source", ""))
	var map: Dictionary = res.get("map", {})
	var layers: Array = map.get("layers", [])
	var kinds: Array = []
	var all_present := layers.size() == 7
	for layer in layers:
		if layer == null:
			all_present = false
			kinds.append("<null>")
		else:
			kinds.append(String((layer as Dictionary).get("kind", "")))
	_chk(all_present, "① 7 层应全在(实得 %s)" % str(kinds))
	_chk(kinds == ["tex", "tex", "tex", "color", "color", "color", "color"],
			"① 层 kind 顺序应 = tex/tex/tex/color×4(实得 %s)" % str(kinds))
	_chk(int(map.get("sub_cols", -1)) == 12 and int(map.get("sub_rows", -1)) == 12,
			"① 尺寸应 12×12 子格(实得 %s×%s)"
					% [map.get("sub_cols", -1), map.get("sub_rows", -1)])
	# 层 0 前景:README 构图 i%7==0 → neutralDesc(1)、i%11==5 → packDesc(6,2,5,6,7)。
	# 只挑只命中一条规则的站位(0/1/5/7),避开 77 这种两条都命中的歧义格。
	var front := _layer_arr(map, 0, "desc")
	var front_ok := front.size() == 144 \
			and _at(front, 0) == EditorDesc.neutral_desc(1) \
			and _at(front, 1) == EditorDesc.DESC_AIR \
			and _at(front, 5) == EditorDesc.pack_desc(6, 2, 5, 6, 7) \
			and _at(front, 7) == EditorDesc.neutral_desc(1)
	_chk(front_ok, "① 前景层构图应 = 手推的 i%%7 / i%%11 规则(实得 0=%d 1=%d 5=%d 7=%d,长度 %d)"
			% [_at(front, 0), _at(front, 1), _at(front, 5), _at(front, 7), front.size()])
	# 层 3 背景 100%:偶 0x102030FF / 奇 0x40506080(README §2)。
	var bg := _layer_arr(map, 3, "rgba")
	var bg_ok := bg.size() == 144 \
			and _at(bg, 0) == 0x102030FF and _at(bg, 1) == 0x40506080 \
			and _at(bg, 2) == 0x102030FF and _at(bg, 3) == 0x40506080
	_chk(bg_ok, "① 背景 100%% 层应偶 0x102030FF / 奇 0x40506080(实得 %d/%d/%d/%d,长度 %d)"
			% [_at(bg, 0), _at(bg, 1), _at(bg, 2), _at(bg, 3), bg.size()])
	_chk(_strings_equal(map.get("comments", []), ["alpha", "beta"]),
			"① comments 应 = [alpha, beta](实得 %s)" % str(map.get("comments", [])))
	_chk(_points_equal(map.get("players", []), [{"x": 0, "y": 0}, {"x": 2, "y": 2}]),
			"① players 应 = (0,0)(2,2)(实得 %s)" % str(map.get("players", [])))
	_chk(_points_equal(map.get("respawns", []), [
			{"side": 1, "x": 1, "y": 0}, {"side": 1, "x": 0, "y": 1}, {"side": 1, "x": 0, "y": 2},
			{"side": 2, "x": 2, "y": 0}, {"side": 2, "x": 2, "y": 1}, {"side": 2, "x": 2, "y": 2},
	]), "① respawns 应按侧分组回读(实得 %s)" % str(map.get("respawns", [])))
	_chk(_points_equal(map.get("enemies", []),
			[{"type": "slime", "x": 1, "y": 1}, {"type": "bat", "x": 2, "y": 0}]),
			"① enemies 应 = slime(1,1)/bat(2,0)(实得 %s)" % str(map.get("enemies", [])))


# ══ ② 读 v4_legacy_tex.cyrm:读时迁移(不再有 legacy tex id),保存字节 == JS 迁移后期望字节 ══
func _check_legacy_migration() -> void:
	var res := EditorIO.open_path(FIXTURES.path_join("v4_legacy_tex.cyrm"))
	_chk(bool(res.get("ok", false)), "② 读 v4_legacy_tex 应成功(实得 error=%s)" % res.get("error", ""))
	_chk(String(res.get("source", "")) == "v4",
			"② source 应 = \"v4\"(实得 \"%s\")" % res.get("source", ""))
	var map: Dictionary = res.get("map", {})
	var scene := _layer_arr(map, 1, "desc")
	var known := EditorValidate._known_textures()
	var clean := scene.size() > 0
	var legacy_hit := 0
	var unknown_hit := 0
	for d in scene:
		var tex := EditorDesc.tex_of(d)
		if tex == 0:
			continue
		if LEGACY_TEX_IDS.has(tex):
			legacy_hit += 1
		if not known.is_empty() and not known.has(tex):
			unknown_hit += 1
	clean = clean and legacy_hit == 0 and unknown_hit == 0
	_chk(clean, "② 内存里应已迁移:不再有 legacy tex id(实得 %d 个)/ 也不该有不存在的 tex id(实得 %d 个)"
			% [legacy_hit, unknown_hit])
	var saved := EditorIO.save_path(PROBE_LEGACY, map, {"compress": false})
	_chk(bool(saved.get("ok", false)), "② 迁移后的图应可保存(实得 error=%s)" % saved.get("error", ""))
	var expected := _read_bytes(FIXTURES.path_join("v4_legacy_migrated.cyrm"))
	var got := _read_bytes(PROBE_LEGACY)
	_chk(got.size() > 0 and got == expected,
			"② 迁移后保存字节应 == v4_legacy_migrated.cyrm(%d 字节 vs %d 字节)"
					% [got.size(), expected.size()])


# ══ ③ 读 v3_simple.txt(source=v3)与 legacy_letters.txt(source=legacy),spawn 坐标要对 ══
func _check_v3_texts() -> void:
	var v3 := EditorIO.open_path(FIXTURES.path_join("v3_simple.txt"))
	_chk(bool(v3.get("ok", false)), "③ 读 v3_simple 应成功(实得 error=%s)" % v3.get("error", ""))
	_chk(String(v3.get("source", "")) == "v3",
			"③ v3_simple 的 source 应 = \"v3\"(实得 \"%s\")" % v3.get("source", ""))
	var v3map: Dictionary = v3.get("map", {})
	_chk(int(v3map.get("sub_cols", -1)) == 8 and int(v3map.get("sub_rows", -1)) == 12,
			"③ v3_simple 应迁成 2×3 格 = 8×12 子格(实得 %s×%s)"
					% [v3map.get("sub_cols", -1), v3map.get("sub_rows", -1)])
	_chk(_points_equal(v3map.get("players", []), [{"x": 2, "y": 1}]),
			"③ v3_simple players 应 = (2,1)(实得 %s)" % str(v3map.get("players", [])))
	_chk(_points_equal(v3map.get("enemies", []), [{"type": "slime", "x": 3, "y": 2}]),
			"③ v3_simple enemies 应 = slime(3,2)(实得 %s)" % str(v3map.get("enemies", [])))
	_chk(_strings_equal(v3map.get("comments", []), ["note"]),
			"③ v3_simple comments 应 = [note](实得 %s)" % str(v3map.get("comments", [])))
	var v3scene := _layer_arr(v3map, 1, "desc")
	var v3_nonzero := 0
	for d in v3scene:
		if d != 0:
			v3_nonzero += 1
	_chk(v3_nonzero > 0, "③ v3_simple 迁移后场景层应有非空子格(实得全空)")

	var legacy := EditorIO.open_path(FIXTURES.path_join("legacy_letters.txt"))
	_chk(bool(legacy.get("ok", false)), "③ 读 legacy_letters 应成功(实得 error=%s)" % legacy.get("error", ""))
	_chk(String(legacy.get("source", "")) == "legacy",
			"③ legacy_letters 的 source 应 = \"legacy\"(实得 \"%s\")" % legacy.get("source", ""))
	var lmap: Dictionary = legacy.get("map", {})
	_chk(int(lmap.get("sub_cols", -1)) == 8 and int(lmap.get("sub_rows", -1)) == 8,
			"③ legacy_letters 4×4 旧字母应折叠成 2×2 格 = 8×8 子格(实得 %s×%s)"
					% [lmap.get("sub_cols", -1), lmap.get("sub_rows", -1)])
	_chk(_points_equal(lmap.get("players", []), [{"x": 2, "y": 1}]),
			"③ legacy_letters players 应 ÷2 = (2,1)(实得 %s)" % str(lmap.get("players", [])))


# ══ ⑤ save → open → save:两次落盘字节逐字节相等(确定性 encode)══
func _check_deterministic_save() -> void:
	# 用 ① 读进来的真实 7 层图(不另造图,顺带证明「打开→保存」链路)。
	var opened := EditorIO.open_path(FIXTURES.path_join("v4_mixed_7layers.cyrm"))
	var map: Dictionary = opened.get("map", {})
	var save_a := EditorIO.save_path(PROBE_A, map)
	_chk(bool(save_a.get("ok", false)), "⑤ 第一次保存应成功(实得 error=%s)" % save_a.get("error", ""))
	var size_a := _file_size(PROBE_A)
	_chk(size_a > 20, "⑤ 第一次保存后文件应存在且 > 20 字节(实得 %d)" % size_a)
	_chk(int(save_a.get("bytes", -1)) == size_a,
			"⑤ 保存返回的 bytes 应 = 实际文件长度(%s vs %d)" % [save_a.get("bytes", -1), size_a])
	var reopened := EditorIO.open_path(PROBE_A)
	_chk(bool(reopened.get("ok", false)),
			"⑤ 保存的文件应能再打开(实得 error=%s)" % reopened.get("error", ""))
	_chk(String(reopened.get("source", "")) == "v4",
			"⑤ 再打开 source 应 = \"v4\"(实得 \"%s\")" % reopened.get("source", ""))
	var save_b := EditorIO.save_path(PROBE_B, reopened.get("map", {}))
	_chk(bool(save_b.get("ok", false)), "⑤ 第二次保存应成功(实得 error=%s)" % save_b.get("error", ""))
	var bytes_a := _read_bytes(PROBE_A)
	var bytes_b := _read_bytes(PROBE_B)
	_chk(bytes_a.size() > 20 and bytes_a == bytes_b,
			"⑤ 同一张图两次保存应逐字节相等(%d 字节 vs %d 字节)"
					% [bytes_a.size(), bytes_b.size()])


# ══ ④ 坏文件:随机 20 字节 / 非 CYRM 文本 ⇒ ok:false 且 error 非空 ══
func _check_bad_files() -> void:
	var junk := PackedByteArray()
	for i in 20:
		# 确定的 20 字节可打印垃圾(前 4 字节不是 "CYRM" magic)。不用真随机非 UTF-8 字节:
		# 那会让 get_string_from_utf8 刷一屏引擎的 Unicode 解析噪声,掩盖真信号。
		junk.append(33 + (i * 37) % 90)
	_write_bytes(PROBE_BAD_BIN, junk)
	var bad_bin := EditorIO.open_path(PROBE_BAD_BIN)
	_chk(not bool(bad_bin.get("ok", false)) and not String(bad_bin.get("error", "")).is_empty(),
			"④ 随机 20 字节应 ok:false 且 error 非空(实得 ok=%s error=\"%s\")"
					% [bad_bin.get("ok", true), bad_bin.get("error", "")])
	_write_bytes(PROBE_BAD_TEXT, "not a cyrm map\n".to_utf8_buffer())
	var bad_text := EditorIO.open_path(PROBE_BAD_TEXT)
	_chk(not bool(bad_text.get("ok", false)) and not String(bad_text.get("error", "")).is_empty(),
			"④ 非 CYRM 文本应 ok:false 且 error 非空(实得 ok=%s error=\"%s\")"
					% [bad_text.get("ok", true), bad_text.get("error", "")])


# ══ ⑥ validate errors 拒写:含 legacy tex id 的图 ⇒ ok:false、errors 非空、目标文件不存在 ══
func _check_validate_reject() -> void:
	var bad_map := EditorMap.create_map("bad_legacy", 2, 2)
	var layers: Array = bad_map.get("layers", [])
	var scene_size := 0
	var legacy_id_ok := false
	if layers.size() == 7 and layers[1] != null:
		var ld: Dictionary = layers[1]
		var desc: PackedInt32Array = ld.get("desc", PackedInt32Array())
		scene_size = desc.size()
		if desc.size() > 0:
			desc[0] = EditorDesc.neutral_desc(2)   # legacy id(不在 tile_defs)⇒ validate 必报 error
			ld["desc"] = desc
			legacy_id_ok = _at(desc, 0) == EditorDesc.neutral_desc(2)
	_chk(layers.size() == 7 and scene_size == 64 and legacy_id_ok,
			"⑥ 前提:构造的 2×2 格图应有 7 层、场景层 64 子格且第 0 格 = legacy tex 2(实得层数 %d/长度 %d)"
					% [layers.size(), scene_size])
	var report := EditorValidate.validate_map(bad_map)
	_chk(not ((report.get("errors", []) as Array).is_empty()),
			"⑥ 前提:含 legacy tex id 的图 validate 应给 errors(实得 %s)" % str(report.get("warnings", [])))
	var res := EditorIO.save_path(PROBE_REJECT, bad_map)
	_chk(not bool(res.get("ok", false)), "⑥ validate errors 时 save_path 应 ok:false(实得 ok:true)")
	_chk(not String(res.get("error", "")).is_empty(),
			"⑥ 拒写应给原因(实得 error=\"\")")
	_chk(not ((res.get("errors", []) as Array).is_empty()),
			"⑥ 拒写返回应带 errors(实得 %s)" % str(res.get("errors", [])))
	_chk(not FileAccess.file_exists(PROBE_REJECT),
			"⑥ 拒写时目标文件必须不存在: %s" % PROBE_REJECT)


# ══ ⑦ list_maps:三处目录(本例可验 res://maps 与 user://maps),去重排序 ══
func _check_list_maps() -> void:
	var maps := EditorIO.list_maps()
	_chk(maps.has("res://maps/demo.cyrm") or maps.has("res://maps/newfactory.cyrm"),
			"⑦ list_maps 应含 res://maps 下的真实地图(实得 %s)" % str(maps))
	_chk(maps.has(PROBE_A), "⑦ list_maps 应含 user://maps 下刚保存的 %s(实得 %s)"
			% [PROBE_A, str(maps)])
	var sorted_copy := maps.duplicate()
	sorted_copy.sort()
	_chk(maps == sorted_copy, "⑦ list_maps 应排序(实得 %s)" % str(maps))


# ══ ⑧ default_target("a b/c"):落 user://maps/ 且名字被 sanitize ══
func _check_default_target() -> void:
	var target := EditorIO.default_target("a b/c")
	_chk(target.begins_with("user://maps/"),
			"⑧ default_target 应落在 user://maps/(实得 \"%s\")" % target)
	_chk(target == "user://maps/a_bc.cyrm",
			"⑧ default_target 应把 \"a b/c\" 净化为 a_bc 并补 .cyrm(实得 \"%s\")" % target)


# ── 小工具(全部带越界防护:任一组前置失败时后续断言红,不允许脚本抛错挂死)──

func _read_bytes(path: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(path)


func _file_size(path: String) -> int:
	if not FileAccess.file_exists(path):
		return -1
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	var n := f.get_length()
	f.close()
	return int(n)


func _write_bytes(path: String, bytes: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(EditorIO.DEFAULT_DIR)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_buffer(bytes)
		f.close()


func _layer_arr(map: Dictionary, layer: int, key: String) -> PackedInt32Array:
	var layers: Array = map.get("layers", [])
	if layer < 0 or layer >= layers.size() or layers[layer] == null:
		return PackedInt32Array()
	var v: Variant = (layers[layer] as Dictionary).get(key, PackedInt32Array())
	if v is PackedInt32Array:
		return v
	return PackedInt32Array()


func _at(arr: PackedInt32Array, i: int) -> int:
	return arr[i] if i >= 0 and i < arr.size() else -2147483648


func _points_equal(got: Variant, want: Array) -> bool:
	if not (got is Array):
		return false
	var got_arr: Array = got
	if got_arr.size() != want.size():
		return false
	for i in want.size():
		if not (got_arr[i] is Dictionary):
			return false
		var g: Dictionary = got_arr[i]
		var w: Dictionary = want[i]
		for k in w:
			if g.get(k) != w[k]:
				return false
	return true


func _strings_equal(got: Variant, want: Array) -> bool:
	if not (got is Array):
		return false
	var got_arr: Array = got
	if got_arr.size() != want.size():
		return false
	for i in want.size():
		if String(got_arr[i]) != String(want[i]):
			return false
	return true
