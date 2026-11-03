extends SceneTree

# legacy 纹理迁移工具:旧图集废弃槽位(tex 2-5 / 16-18,新图集里全透明)改写成 base + hue 辅码。

const MAP_DIR := "res://maps"

var _fails: Array[String] = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var do_write := args.has("--write")
	var do_check := args.has("--check")
	if do_write == do_check:
		print("MAP TEXTURE MIGRATE: FAIL —— 需要 --check 或 --write 之一(二者互斥)")
		quit(1)
		return
	TileDefs.load_defs()
	# 空载守卫:迁移表没加载出来 ⇒ 一切文件都会被判成"无 legacy",写模式还会静默什么都不改。
	if TileDefs.legacy_base_of(2) != 1 or TileDefs.legacy_base_of(16) != 15 or TileDefs.legacy_hue_of(17) != 7:
		print("MAP TEXTURE MIGRATE: FAIL —— legacy_texture_map 未加载(data/tile_defs.json?)")
		quit(1)
		return
	var paths := _list_maps()
	if paths.is_empty():
		print("MAP TEXTURE MIGRATE: FAIL —— %s 下没有 .cyrm" % MAP_DIR)
		quit(1)
		return
	for p in paths:
		if do_check:
			_check_one(p)
		else:
			_write_one(p)
	if _fails.is_empty():
		print("MAP TEXTURE MIGRATE: OK")
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("MAP TEXTURE MIGRATE: FAIL(%d 处)" % _fails.size())
		quit(1)


func _list_maps() -> Array[String]:
	var out: Array[String] = []
	var da := DirAccess.open(MAP_DIR)
	if da == null:
		return out
	da.list_dir_begin()
	var f := da.get_next()
	while f != "":
		if not da.current_is_dir() and f.to_lower().ends_with(".cyrm"):
			out.append(MAP_DIR + "/" + f)
		f = da.get_next()
	da.list_dir_end()
	out.sort()
	return out


# 原始读取(**不做**迁移 —— MapFormatV4.parse 会在读时迁移,本工具必须看得到迁移前的字节)。
# 成功:{ok, data, body(解压后), compression, header, scene:{pal_off, pc, idx_off, iw, n}};失败 {ok:false, error}。
func _read_raw(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"ok": false, "error": "打不开"}
	var data := f.get_buffer(int(f.get_length()))
	f.close()
	if not MapFormatV4.is_v4_data(data):
		return {"ok": false, "error": "不是 v4"}
	var h := MapFormatV4.read_header(data)
	if int(h["version"]) != 4:
		return {"ok": false, "error": "版本 %d" % int(h["version"])}
	var body := data.slice(MapFormatV4.HEADER_SIZE)
	var compression := int(h["compression"])
	if compression == 1:
		body = body.decompress(int(h["body_size"]), FileAccess.COMPRESSION_DEFLATE)
		if body.size() != int(h["body_size"]):
			return {"ok": false, "error": "解压失败"}
	elif compression != 0:
		return {"ok": false, "error": "未知压缩 %d" % compression}
	if MapFormatV4.crc32(body) != int(h["crc32"]):
		return {"ok": false, "error": "CRC 不符"}
	if body.size() < 2:
		return {"ok": false, "error": "body 缺 meta_len"}
	var meta_len := body.decode_u16(0)
	if body.size() < 2 + meta_len:
		return {"ok": false, "error": "meta 截断"}
	var n := int(h["sub_cols"]) * int(h["sub_rows"])
	var off := 2 + meta_len
	for bit in 4:
		if int(h["layer_flags"]) & (1 << bit) == 0:
			continue
		if off + 1 > body.size():
			return {"ok": false, "error": "层块截断(bit%d)" % bit}
		var kind := body[off]
		off += 1
		if kind == 1:
			if off + 2 > body.size():
				return {"ok": false, "error": "调色板计数截断(bit%d)" % bit}
			var pc := body.decode_u16(off)
			off += 2
			var pal_off := off
			off += pc * 4
			if off + 1 > body.size():
				return {"ok": false, "error": "索引宽度截断(bit%d)" % bit}
			var iw := body[off]
			off += 1
			if off + n * iw > body.size():
				return {"ok": false, "error": "索引流截断(bit%d)" % bit}
			if bit == 1:
				return {"ok": true, "data": data, "body": body, "compression": compression,
						"header": h, "scene": {"pal_off": pal_off, "pc": pc, "idx_off": off, "iw": iw, "n": n}}
			off += n * iw
		elif kind == 2:
			off += n * 4
		else:
			return {"ok": false, "error": "未知层类型 %d" % kind}
	return {"ok": false, "error": "无场景层"}


func _cell_index(raw: Dictionary, i: int) -> int:
	var body: PackedByteArray = raw["body"]
	var scene: Dictionary = raw["scene"]
	var idx_off := int(scene["idx_off"])
	return body[idx_off + i] if int(scene["iw"]) == 1 else body.decode_u16(idx_off + i * 2)


func _pal_desc(raw: Dictionary, i: int) -> int:
	var body: PackedByteArray = raw["body"]
	var scene: Dictionary = raw["scene"]
	return body.decode_u32(int(scene["pal_off"]) + i * 4)


func _check_one(path: String) -> void:
	var raw := _read_raw(path)
	if not bool(raw["ok"]):
		_fails.append("%s: %s" % [path, str(raw.get("error", "?"))])
		return
	var pc := int((raw["scene"] as Dictionary)["pc"])
	var n := int((raw["scene"] as Dictionary)["n"])
	var legacy_pal := 0
	var texs := {}
	for i in pc:
		var tex := (_pal_desc(raw, i) >> 12) & 0xFFF
		if TileDefs.legacy_base_of(tex) != 0:
			legacy_pal += 1
			texs[tex] = true
	var legacy_cells := 0
	if legacy_pal > 0:
		for i in n:
			var idx := _cell_index(raw, i)
			if idx < pc and TileDefs.legacy_base_of((_pal_desc(raw, idx) >> 12) & 0xFFF) != 0:
				legacy_cells += 1
	print("  %s: legacy 调色板项 %d(纹理 %s)/ legacy 子格 %d" % [path, legacy_pal, str(texs.keys()), legacy_cells])


func _write_one(path: String) -> void:
	var raw := _read_raw(path)
	if not bool(raw["ok"]):
		_fails.append("%s: %s" % [path, str(raw.get("error", "?"))])
		return
	var scene: Dictionary = raw["scene"]
	var pc := int(scene["pc"])
	var n := int(scene["n"])
	var body: PackedByteArray = (raw["body"] as PackedByteArray).duplicate()
	var pal_off := int(scene["pal_off"])
	var expected_pal := PackedInt32Array()
	expected_pal.resize(pc)
	var before_tex := PackedInt32Array()
	before_tex.resize(pc)
	var changed := 0
	for i in pc:
		var d := body.decode_u32(pal_off + i * 4)
		before_tex[i] = (d >> 12) & 0xFFF
		expected_pal[i] = MapFormatV4.migrate_descriptor(d)
		if int(expected_pal[i]) != d:
			body.encode_u32(pal_off + i * 4, int(expected_pal[i]))
			changed += 1
	if changed == 0:
		print("  %s: 无 legacy 描述符,跳过(未写盘)" % path)
		return
	var out := _rebuild(raw, body)
	var w := FileAccess.open(path, FileAccess.WRITE)
	if w == null:
		_fails.append("%s: 写不开" % path)
		return
	w.store_buffer(out)
	w.close()
	_verify(path, body, expected_pal, before_tex, raw)


# 意图 body → 完整文件字节:compression 位沿用原文件;压不动(compress 回读校验失败)才退回裸 body(§3.5 两条都合法)。
func _rebuild(raw: Dictionary, body: PackedByteArray) -> PackedByteArray:
	var payload := body
	var compression := int(raw["compression"])
	if compression == 1:
		var packed := body.compress(FileAccess.COMPRESSION_DEFLATE)
		if not packed.is_empty() \
				and packed.decompress(body.size(), FileAccess.COMPRESSION_DEFLATE) == body:
			payload = packed
		else:
			compression = 0
	var h: Dictionary = raw["header"]
	var data: PackedByteArray = raw["data"]
	var out := PackedByteArray()
	out.append_array(MapFormatV4.MAGIC.to_ascii_buffer())
	out.append(4)
	out.append(compression)
	MapFormatV4.write_u32(out, body.size())
	MapFormatV4.write_u32(out, MapFormatV4.crc32(body))
	MapFormatV4.write_u16(out, int(h["sub_cols"]))
	MapFormatV4.write_u16(out, int(h["sub_rows"]))
	out.append(int(h["layer_flags"]))
	out.append(data[19])                 # reserved 原样
	out.append_array(payload)
	return out


func _verify(path: String, want_body: PackedByteArray, expected_pal: PackedInt32Array,
		before_tex: PackedInt32Array, raw_before: Dictionary) -> void:
	var raw := _read_raw(path)
	if not bool(raw["ok"]):
		_fails.append("%s: 回读失败 %s" % [path, str(raw.get("error", "?"))])
		return
	var after: PackedByteArray = raw["body"]
	# ① 除调色板改写外逐字节无损(meta / 索引流 / 其余层)
	if after != want_body:
		_fails.append("%s: 回读 body 与意图 body 不一致(层块被动过?)" % path)
		return
	var pc := expected_pal.size()
	var legacy_left := 0
	for i in pc:
		var d := _pal_desc(raw, i)
		if d != int(expected_pal[i]):
			_fails.append("%s: 调色板[%d] = 0x%X,期望 0x%X" % [path, i, d, int(expected_pal[i])])
			return
		# ② 迁移后不再有 legacy 纹理
		if TileDefs.legacy_base_of((d >> 12) & 0xFFF) != 0:
			legacy_left += 1
	if legacy_left > 0:
		_fails.append("%s: 迁移后仍有 %d 个 legacy 调色板项" % [path, legacy_left])
		return
	# ③ 逐格纹理与迁移前映射一致(索引流未动 ⇒ 逐格对调色板)
	var n := int((raw["scene"] as Dictionary)["n"])
	var idx_before := PackedInt32Array()
	idx_before.resize(n)
	for i in n:
		idx_before[i] = _cell_index(raw_before, i)
	for i in n:
		if _cell_index(raw, i) != idx_before[i]:
			_fails.append("%s: 索引流被改动(格 %d)" % [path, i])
			return
		var t_before := before_tex[idx_before[i]] if idx_before[i] < pc else 0
		var t_after := (_pal_desc(raw, _cell_index(raw, i)) >> 12) & 0xFFF
		var base := TileDefs.legacy_base_of(t_before)
		var want := base if base != 0 else t_before
		if t_after != want:
			_fails.append("%s: 格 %d 纹理 %d,期望 %d(迁移前 %d)" % [path, i, t_after, want, t_before])
			return
	print("  %s: 已迁移(调色板 %d 项改写;回读断言 ①②③ 通过)" % [path, _count_changed(expected_pal, before_tex)])


func _count_changed(expected_pal: PackedInt32Array, before_tex: PackedInt32Array) -> int:
	var c := 0
	for i in expected_pal.size():
		if ((int(expected_pal[i]) >> 12) & 0xFFF) != before_tex[i]:
			c += 1
	return c
