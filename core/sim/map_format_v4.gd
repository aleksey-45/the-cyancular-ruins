class_name MapFormatV4
extends RefCounted

# CYRM v4 包含文件头和数据体，数据体存放地图元数据与图层。
# 文件头记录压缩方式、原始大小和 CRC32，用于解压并校验数据。
# 场景层以 16 像素的子格保存纹理。每 4 × 4 个子格还可合并成一块 64 像素的瓦片。

const HEADER_SIZE := 20
const SUB_PER_CELL := 4
const TEXTURE_SHIFT := 12
const TINT_MASK := (1 << TEXTURE_SHIFT) - 1
const NEUTRAL_TINT := 4 | (4 << 3) | (4 << 6) | (7 << 9)


static func descriptor_texture(desc: int) -> int:
	return (desc >> TEXTURE_SHIFT) & 0xFFF


static func migrate_descriptor(desc: int, legacy: Dictionary) -> int:
	var key := str(descriptor_texture(desc))
	if not legacy.has(key):
		return desc
	var entry: Dictionary = legacy[key]
	var hue := clampi((desc & 7) + int(entry["hue"]) - 4, 0, 7)
	return (desc & ~((0xFFF << TEXTURE_SHIFT) | 7)) | (int(entry["base"]) << TEXTURE_SHIFT) | hue


static func is_v4_data(data: PackedByteArray) -> bool:
	return data.size() >= 4 and data[0] == 0x43 and data[1] == 0x59 and data[2] == 0x52 and data[3] == 0x4D


static func read_header(data: PackedByteArray) -> Dictionary:
	return {
		"version": data[4],
		"compression": data[5],
		"body_size": data.decode_u32(6),
		"crc32": data.decode_u32(10),
		"sub_cols": data.decode_u16(14),
		"sub_rows": data.decode_u16(16),
		"layer_flags": data[18],
	}


const MAX_BODY_SIZE := 64 * 1024 * 1024   # 兼容网页编辑器，解压后的数据体不得超过 64 MiB。

static func parse(data: PackedByteArray) -> Dictionary:
	if data.size() < HEADER_SIZE:
		return {"ok": false, "error": "文件过短(%d 字节)" % data.size()}
	if not is_v4_data(data):
		return {"ok": false, "error": "缺少 CYRM magic"}
	var h := read_header(data)
	if int(h["version"]) != 4:
		return {"ok": false, "error": "版本 %d 不支持(只支持 4)" % int(h["version"])}
	# 宽高必须能分为完整的 4 × 4 子格瓦片。
	if int(h["sub_cols"]) <= 0 or int(h["sub_rows"]) <= 0 \
			or int(h["sub_cols"]) % SUB_PER_CELL != 0 or int(h["sub_rows"]) % SUB_PER_CELL != 0:
		return {"ok": false, "error": "sub 尺寸非法(%dx%d,须为 4 的倍数且非零)" % [int(h["sub_cols"]), int(h["sub_rows"])]}
	# 先限制声明的解压大小，避免解压时分配超出上限的内存。
	if int(h["body_size"]) > MAX_BODY_SIZE:
		return {"ok": false, "error": "body_size 超上限(%d > %d)" % [int(h["body_size"]), MAX_BODY_SIZE]}
	if int(h["compression"]) == 0 and int(h["body_size"]) != data.size() - HEADER_SIZE:
		return {"ok": false, "error": "裸 body 大小与文件不符"}
	var body := data.slice(HEADER_SIZE)
	if int(h["compression"]) == 1:
		body = body.decompress(int(h["body_size"]), FileAccess.COMPRESSION_DEFLATE)
		if body.size() != int(h["body_size"]):
			return {"ok": false, "error": "解压失败或大小不符(%d != %d)" % [body.size(), int(h["body_size"])]}
	elif int(h["compression"]) != 0:
		return {"ok": false, "error": "未知压缩类型 %d" % int(h["compression"])}
	if crc32(body) != int(h["crc32"]):
		return {"ok": false, "error": "CRC32 校验失败(文件损坏)"}
	if body.size() < 2:
		return {"ok": false, "error": "body 缺 meta 长度"}
	var meta_len := body.decode_u16(0)
	if body.size() < 2 + meta_len:
		return {"ok": false, "error": "meta 截断"}
	var meta_text := body.slice(2, 2 + meta_len).get_string_from_utf8()
	var meta_lines := meta_text.split("\n")
	var sub_cols := int(h["sub_cols"])
	var sub_rows := int(h["sub_rows"])
	var n := sub_cols * sub_rows
	var out := {
		"ok": true,
		"meta_lines": meta_lines,
		"sub_cols": sub_cols,
		"sub_rows": sub_rows,
		"layer_flags": int(h["layer_flags"]),
		"scene": PackedInt32Array(),
	}
	var off := 2 + meta_len
	for bit in 4:   # 依次处理前景、场景、后景和背景。文件头中未设置的图层没有数据。
		if int(h["layer_flags"]) & (1 << bit) == 0:
			continue
		if off >= body.size():
			return {"ok": false, "error": "层块截断(bit%d)" % bit}
		var kind := body[off]
		off += 1
		if kind == 1:
			if off + 2 > body.size():
				return {"ok": false, "error": "调色板长度截断(bit%d)" % bit}
			var pc := body.decode_u16(off)
			off += 2
			if pc == 0 or off + pc * 4 + 1 > body.size():
				return {"ok": false, "error": "调色板非法或截断(bit%d)" % bit}
			var palette := PackedInt32Array()
			if bit == 1:
				var legacy := TileDefs.legacy_textures()
				palette.resize(pc)
				for i in pc:
					var desc := migrate_descriptor(body.decode_u32(off + i * 4), legacy)
					var texture := descriptor_texture(desc)
					if not TileDefs.has_texture(texture):
						return {"ok": false, "error": "未定义的场景材质 %d" % texture}
					palette[i] = desc
			off += pc * 4
			var iw := body[off]
			off += 1
			if iw not in [1, 2] or (iw == 1 and pc > 256) or off + n * iw > body.size():
				return {"ok": false, "error": "索引流截断(bit%d)" % bit}
			if bit == 1:
				var descs := PackedInt32Array()
				descs.resize(n)
				for i in n:
					var idx := body[off + i] if iw == 1 else body.decode_u16(off + i * 2)
					if idx >= pc:
						return {"ok": false, "error": "调色板索引越界(bit%d)" % bit}
					descs[i] = palette[idx]
				out["scene"] = descs
			off += n * iw
		elif kind == 2:
			if off + n * 4 > body.size():
				return {"ok": false, "error": "RGBA 层截断(bit%d)" % bit}
			off += n * 4   # RGBA 图层不提供游戏所用的场景瓦片，直接跳过像素字节。
		else:
			return {"ok": false, "error": "未知层类型 %d" % kind}
	return out


## 用每块瓦片中最常见的非空纹理作为瓦片纹理。频次相同时取较小的纹理 ID。
## 低四位记录四个区域是否包含非空子格，顺序是左上、右上、左下、右下。
static func flatten_scene(scene: PackedInt32Array, sub_cols: int, sub_rows: int) -> Array[Array]:
	var cols := sub_cols / SUB_PER_CELL
	var rows := sub_rows / SUB_PER_CELL
	var grid: Array[Array] = []
	for r in rows:
		var row: Array[int] = []
		row.resize(cols)
		row.fill(0)
		grid.append(row)
	for r in rows:
		for c in cols:
			var counts := {}
			var shape := 0
			for qy in 2:
				for qx in 2:
					var any := false
					for sy in 2:
						for sx in 2:
							var x := c * SUB_PER_CELL + qx * 2 + sx
							var y := r * SUB_PER_CELL + qy * 2 + sy
							var tex := descriptor_texture(scene[y * sub_cols + x])
							if tex != 0:
								any = true
								counts[tex] = int(counts.get(tex, 0)) + 1
					if any:
						shape |= 1 << (qy * 2 + qx)
			var best := 0
			var best_n := 0
			for tex in counts:
				var nn := int(counts[tex])
				if nn > best_n or (nn == best_n and tex < best):
					best = tex
					best_n = nn
			grid[r][c] = MapFormat.pack(best, shape)
	return grid


# CRC32 使用按多项式 0xEDB88320 生成的查找表。
# GDScript 的整数为有符号 64 位，足以存放计算得到的无符号 32 位校验值。
static var _crc_table: PackedInt64Array = PackedInt64Array()

static func crc32(data: PackedByteArray) -> int:
	if _crc_table.is_empty():
		_crc_table.resize(256)
		for i in 256:
			var c := i
			for k in 8:
				c = (c >> 1) ^ (0xEDB88320 if (c & 1) == 1 else 0)
			_crc_table[i] = c
	var crc := 0xFFFFFFFF
	for b in data:
		crc = _crc_table[(crc ^ b) & 0xFF] ^ (crc >> 8)
	return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF
