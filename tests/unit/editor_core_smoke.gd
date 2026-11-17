extends SceneTree

# 编辑器核心基础层冒烟(`-s`,headless):EditorConstants / EditorDesc / EditorBytes / EditorGeometry / EditorMeta / EditorLegacy / EditorMap。
# 去掉什么它才会红:
#   ① 描述符位域错位(例如 alpha 写成 bit7 而不是 bit9)⇒ ① 组的字面量断言红;
#   ② 字节写入端序反了 ⇒ ② 组「u16/u32 小端字节」红;
#   ③ Reader 越界不报错(静默返回 0)⇒ ③ 组 failed 断言红;
#   ④ meta 文本顺序/关键字漂移(respawn 没按侧分组、player2 写法变)⇒ ④ 组整串比对红;
#   ⑤ 解析器把非法行吞掉(而不是降级成注释)⇒ ⑤ 组红;
#   ⑥ legacy 迁移合成规则改了(base/hue 组合)⇒ ⑥ 组红;
#   ⑦ 层对象形状漂移(4-6 层不是 null、ensure_layer 给纹理层补层)⇒ ⑦ 组红。
# 判据是未跑满条数与失败清单两条,退出码只是陪衬。

const EXPECTED_CHECKS := 37

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	# ★ 空载守卫:任一脚本 load 失败还往下走会在 null 上抛错,而 `-s` 抛错走不到 quit() ⇒ 进程永久挂起。
	for p in ["res://core/editor/editor_constants.gd", "res://core/editor/editor_desc.gd",
			"res://core/editor/editor_bytes.gd", "res://core/editor/editor_geometry.gd",
			"res://core/editor/editor_meta.gd", "res://core/editor/editor_legacy.gd",
			"res://core/editor/editor_map.gd"]:
		if load(p) == null:
			print("EDITOR CORE SMOKE: FAIL | 空载守卫 load(%s) 为 null(-s 不 quit 会挂死)" % p)
			quit(1)
			return

	_check_constants()
	_check_desc()
	_check_bytes()
	_check_geometry()
	_check_meta()
	_check_legacy()
	_check_map()

	if _checks < EXPECTED_CHECKS:
		print("EDITOR CORE SMOKE: FAIL | 只跑了 %d 条 < %d(脚本中途中止)" % [_checks, EXPECTED_CHECKS])
		quit(1)
		return
	if not _fails.is_empty():
		print("EDITOR CORE SMOKE: FAIL(%d/%d)" % [_fails.size(), EXPECTED_CHECKS])
		for f in _fails:
			print("  - " + f)
		quit(1)
		return
	print("EDITOR CORE SMOKE: OK(%d 条断言)" % _checks)
	quit(0)


func _check_constants() -> void:
	_chk(EditorConstants.LAYER_COUNT == 7 and EditorConstants.SUB_PER_CELL == 4,
			"① 常量:LAYER_COUNT=%d SUB_PER_CELL=%d(期望 7/4)" % [EditorConstants.LAYER_COUNT, EditorConstants.SUB_PER_CELL])
	var color_ok := true
	for layer_idx in EditorConstants.LAYER_COUNT:
		color_ok = color_ok and (EditorConstants.is_color_layer(layer_idx) == (layer_idx >= 3 and layer_idx <= 6))
	_chk(color_ok, "① is_color_layer 只在 3..6 为真")
	_chk(EditorConstants.LAYER_NAMES.size() == 7 and EditorConstants.LAYER_KINDS.size() == 7
			and EditorConstants.LAYER_KINDS[2] == "tex" and EditorConstants.LAYER_KINDS[3] == "color",
			"① LAYER_NAMES/LAYER_KINDS 各 7 项且 2=tex 3=color")


func _check_desc() -> void:
	# 手推:tex=1, hue=4, bri=4, sat=4, alpha=7 ⇒ 1<<12 | 7<<9 | 4<<6 | 4<<3 | 4 = 0x00001F24
	_chk(EditorDesc.neutral_desc(1) == 0x00001F24,
			"② neutral_desc(1)=0x%08X(期望 0x00001F24)" % EditorDesc.neutral_desc(1))
	var d := EditorDesc.pack_desc(21, 5, 6, 7, 3)
	_chk(EditorDesc.tex_of(d) == 21 and EditorDesc.hue_of(d) == 5 and EditorDesc.bright_of(d) == 6
			and EditorDesc.sat_of(d) == 7 and EditorDesc.alpha_of(d) == 3,
			"② pack_desc 位域往返:tex=%d hue=%d bri=%d sat=%d alpha=%d" % [
				EditorDesc.tex_of(d), EditorDesc.hue_of(d), EditorDesc.bright_of(d), EditorDesc.sat_of(d), EditorDesc.alpha_of(d)])
	_chk(EditorDesc.pack_desc(0, 4, 4, 4, 7) == 0 and EditorDesc.pack_desc(4096, 4, 4, 4, 7) == 0
			and EditorDesc.pack_desc(4095, 4, 4, 4, 7) != 0,
			"② 纹理 0 与 4096 被钳成空气、4095 合法")
	_chk(EditorDesc.is_air(0) and not EditorDesc.is_air(EditorDesc.neutral_desc(1)),
			"② is_air 只认整体 0")
	# 读外来文件的空气判据是 tex_of == 0:畸形 0x7FF(纹理 0、辅码非 0)不等同空气。
	var malformed := 0x7FF
	_chk(EditorDesc.tex_of(malformed) == 0 and not EditorDesc.is_air(malformed),
			"② 畸形描述符 0x7FF:tex_of=0 但 is_air=false")


func _check_bytes() -> void:
	var w := EditorBytes.Writer.new()
	w.u8(0x12).u16(0x3456).u32(0x89ABCDEF)
	var raw := w.finish()
	_chk(raw.hex_encode() == "125634efcdab89",
			"③ Writer 小端字节序:%s(期望 125634efcdab89)" % raw.hex_encode())
	var r := EditorBytes.Reader.new(raw)
	_chk(r.u8() == 0x12 and r.u16() == 0x3456 and r.u32() == 0x89ABCDEF and r.remaining() == 0,
			"③ Reader 往返与 remaining 归零")
	# ★ u32 必须按无符号给:0xFFFFFFFF 不是 -1(否则 CRC / 头部字段比较会错)。
	var rmax := EditorBytes.Reader.new(PackedByteArray([0xFF, 0xFF, 0xFF, 0xFF]))
	_chk(rmax.u32() == 4294967295, "③ Reader.u32(0xFFFFFFFF)=%d(期望 4294967295)" % rmax.u32())
	# 越界必须置 failed(不抛错、不静默)。
	var rbad := EditorBytes.Reader.new(PackedByteArray([1, 2]))
	rbad.u32()
	_chk(rbad.failed and rbad.error.contains("越界"), "③ 越界读置 failed 且 error 点名(%s)" % rbad.error)
	# CRC32 标准向量:"123456789" ⇒ 0xCBF43926
	_chk(EditorBytes.crc32("123456789".to_utf8_buffer()) == 0xCBF43926,
			"③ crc32(\"123456789\")=0x%08X(期望 0xCBF43926)" % EditorBytes.crc32("123456789".to_utf8_buffer()))


func _check_geometry() -> void:
	_chk(EditorGeometry.sanitize_name("  你好 world!! -abc  ") == "你好_world_-abc",
			"④ sanitize_name 空白折叠/剔非法/去前导-:%s" % EditorGeometry.sanitize_name("  你好 world!! -abc  "))
	_chk(EditorGeometry.sanitize_name("") == "structure" and EditorGeometry.sanitize_name("!!!") == "structure",
			"④ 空名回落 structure")
	var long_name := "abcdefghijklmnopqrstuvwxyz0123456789"
	_chk(EditorGeometry.sanitize_name(long_name).length() == 32,
			"④ 名字截到 32 字符(实得 %d)" % EditorGeometry.sanitize_name(long_name).length())
	var off3 := EditorGeometry.brush_offsets(3)
	var off4 := EditorGeometry.brush_offsets(4)
	_chk(off3["lo"] == 1 and off3["hi"] == 1 and off4["lo"] == 1 and off4["hi"] == 2,
			"④ brush_offsets(3)=%s (4)=%s(期望 1/1、1/2)" % [off3, off4])
	var line := EditorGeometry.line_cells(0, 0, 2, 1)
	_chk(line.size() == 3 and line[0] == Vector2i(0, 0) and line[2] == Vector2i(2, 1),
			"④ Bresenham 直线含两端:%s" % str(line))
	var region := EditorGeometry.norm_region(2, 3, 0, 1)
	_chk(region["x"] == 0 and region["y"] == 1 and region["w"] == 3 and region["h"] == 3,
			"④ norm_region 归一化:%s" % str(region))


func _check_meta() -> void:
	var map := {
		"comments": ["a", "b"],
		"players": [{"x": 1, "y": 2}, {"x": 3, "y": 4}, {"x": 5, "y": 6}],
		"respawns": [{"side": 2, "x": 7, "y": 8}, {"side": 1, "x": 9, "y": 10}],
		"enemies": [{"type": "slime", "x": 1, "y": 1}],
	}
	var want := "# a\n# b\n# player 1 2\n# player2 3 4\n# player3 5 6\n" \
			+ "# respawn 1 9 10\n# respawn 2 7 8\n# enemy slime 1 1\n"
	var got := EditorMeta.build_meta(map)
	_chk(got == want, "⑤ build_meta 顺序/关键字:\n    实得 %s\n    期望 %s" % [JSON.stringify(got), JSON.stringify(want)])
	var parsed := EditorMeta.parse_meta(got)
	_chk(parsed["comments"] == ["a", "b"]
			and parsed["players"] == [{"x": 1, "y": 2}, {"x": 3, "y": 4}, {"x": 5, "y": 6}]
			and parsed["respawns"] == [{"side": 1, "x": 9, "y": 10}, {"side": 2, "x": 7, "y": 8}]
			and parsed["enemies"] == [{"type": "slime", "x": 1, "y": 1}],
			"⑤ parse_meta(build_meta) 往返一致:%s" % JSON.stringify(parsed))
	# 解析失败的行必须降级成注释(而不是丢掉,也不是被 parseInt 静默截断)。
	var bad := EditorMeta.parse_meta("# player 3.5 4\n# respawn 3 1 2\n# enemy slime 1e3 2\n# player +3 -4\n")
	_chk(bad["comments"] == ["player 3.5 4", "respawn 3 1 2", "enemy slime 1e3 2"],
			"⑤ 非法行降级成注释:%s" % JSON.stringify(bad["comments"]))
	_chk(bad["players"] == [{"x": 3, "y": -4}],
			"⑤ 整数字面量接受前导正负号:%s" % JSON.stringify(bad["players"]))
	_chk((bad["respawns"] as Array).is_empty() and (bad["enemies"] as Array).is_empty(),
			"⑤ side 只认 1|2、敌人坐标必须是整数")
	_chk(EditorMeta.build_meta({"comments": [], "players": [], "respawns": [], "enemies": []}) == "",
			"⑤ 空 meta 输出空串")


func _check_legacy() -> void:
	# tex 2 → base 1、hue 偏移 3−4:中性 hue 4 ⇒ 新 hue 3。
	var m2 := EditorLegacy.migrate_descriptor(EditorDesc.neutral_desc(2))
	_chk(m2 == EditorDesc.pack_desc(1, 3, 4, 4, 7),
			"⑥ tex 2 迁移到 base 1/hue 3:0x%08X(期望 0x%08X)" % [m2, EditorDesc.pack_desc(1, 3, 4, 4, 7)])
	# tex 17 → base 15、hue 7;原 hue 6 ⇒ 6+7−4=9 钳到 7。
	var m17 := EditorLegacy.migrate_descriptor(EditorDesc.pack_desc(17, 6, 4, 4, 7))
	_chk(m17 == EditorDesc.pack_desc(15, 7, 4, 4, 7),
			"⑥ hue 钳制:tex 17/hue6 → base15/hue7:0x%08X" % m17)
	_chk(EditorLegacy.migrate_descriptor(0) == 0 and EditorLegacy.migrate_descriptor(EditorDesc.neutral_desc(1)) == EditorDesc.neutral_desc(1),
			"⑥ 空气与非 legacy 纹理原样返回")
	# migrate_map 只动三个纹理层。
	var m := EditorMap.create_map("t", 1, 1)
	var scene: PackedInt32Array = (m["layers"][1] as Dictionary)["desc"]
	scene[0] = EditorDesc.neutral_desc(4)
	(m["layers"][1] as Dictionary)["desc"] = scene
	var bg: PackedInt32Array = (m["layers"][3] as Dictionary)["rgba"]
	bg[0] = 0x11223344
	(m["layers"][3] as Dictionary)["rgba"] = bg
	EditorLegacy.migrate_map(m)
	_chk(int((m["layers"][1] as Dictionary)["desc"][0]) == EditorDesc.pack_desc(1, 5, 4, 4, 7),
			"⑥ migrate_map 迁移场景层(tex4→base1/hue5)")
	_chk(int((m["layers"][3] as Dictionary)["rgba"][0]) == 0x11223344,
			"⑥ migrate_map 不碰颜色层")


func _check_map() -> void:
	var m := EditorMap.create_map("t", 2, 3)
	_chk(m["sub_cols"] == 8 and m["sub_rows"] == 12 and EditorMap.cells_w_of(m) == 2 and EditorMap.cells_h_of(m) == 3,
			"⑦ create_map 尺寸:sub=%dx%d cells=%dx%d" % [
				m["sub_cols"], m["sub_rows"], EditorMap.cells_w_of(m), EditorMap.cells_h_of(m)])
	var layers: Array = m["layers"]
	_chk(layers.size() == 7 and layers[0] != null and layers[3] != null
			and layers[4] == null and layers[5] == null and layers[6] == null,
			"⑦ 默认只分配层 0-3,4-6 为 null")
	_chk((layers[0] as Dictionary)["desc"].size() == 96 and (layers[3] as Dictionary)["rgba"].size() == 96,
			"⑦ 层数组长度 = sub_cols×sub_rows")
	_chk(EditorMap.ensure_layer(m, 4) != null and (m["layers"] as Array)[4] != null
			and (m["layers"] as Array)[5] == null,
			"⑦ ensure_layer(4) 按需建颜色层、不动 5")
	var tex_absent := EditorMap.create_map("t", 1, 1)
	(tex_absent["layers"] as Array)[2] = null
	_chk(EditorMap.ensure_layer(tex_absent, 2) == null, "⑦ ensure_layer 不给缺席的纹理层补层")
	_chk(EditorMap.create_map("x", 0, 1).is_empty(), "⑦ create_map 尺寸非法返回空字典")
	_chk(EditorMap.sub_index(8, 3, 2) == 19, "⑦ sub_index(8,3,2)=19(实得 %d)" % EditorMap.sub_index(8, 3, 2))
