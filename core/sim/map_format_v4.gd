class_name MapFormatV4
extends RefCounted

# .cyrm v4 二进制地图读取。
# 包含 20 字节明文文件头、Deflate 解压缩、CRC32 校验以及四图层二进制数据解析。
# 游戏侧核心消费场景层数据：支持通过 flatten_scene 将 4x4 子格降采样为游戏主网格，
# 或直接输出 16px 子格表供物理破坏与精细渲染系统使用。

const HEADER_SIZE := 20
const SUB_PER_CELL := 4   # 一格 64px = 4×4 个 16px 子格


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


## 解析 v4。成功:{"ok": true, "meta_lines": Array, "scene": PackedInt32Array(子格描述符),
## "sub_cols", "sub_rows", "layer_flags"};失败:{"ok": false, "error": "..."}。
## 目前只保留「场景」层的内容(其余层按块大小跳过,保持游标对齐)。
const MAX_BODY_SIZE := 64 * 1024 * 1024   # body 上限(解压后;与编辑器 core.js 同值)

static func parse(data: PackedByteArray) -> Dictionary:
	if data.size() < HEADER_SIZE:
		return {"ok": false, "error": "文件过短(%d 字节)" % data.size()}
	if not is_v4_data(data):
		return {"ok": false, "error": "缺少 CYRM magic"}
	var h := read_header(data)
	if int(h["version"]) != 4:
		return {"ok": false, "error": "版本 %d 不支持(只支持 4)" % int(h["version"])}
	# 格式防御性校验：
	# 1. 瓦片尺寸必须为 4 的整数倍且大于 0
	if int(h["sub_cols"]) <= 0 or int(h["sub_rows"]) <= 0 \
			or int(h["sub_cols"]) % SUB_PER_CELL != 0 or int(h["sub_rows"]) % SUB_PER_CELL != 0:
		return {"ok": false, "error": "sub 尺寸非法(%dx%d,须为 4 的倍数且非零)" % [int(h["sub_cols"]), int(h["sub_rows"])]}
	# 2. 校验解压前声明的 body_size 上限，避免异常大内存分配
	if int(h["body_size"]) > MAX_BODY_SIZE:
		return {"ok": false, "error": "body_size 超上限(%d > %d)" % [int(h["body_size"]), MAX_BODY_SIZE]}
	# 3. 未压缩模式下 body_size 必须与文件实际数据余量一致
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
	for bit in 4:   # bit0 前景 / bit1 场景 / bit2 后景 / bit3 背景
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
			palette.resize(pc)
			for i in pc:
				palette[i] = body.decode_u32(off)
				off += 4
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
			off += n * 4   # 背景层:整块 RGBA,游戏侧暂不消费
		else:
			return {"ok": false, "error": "未知层类型 %d" % kind}
	return out


## 将场景层描述符解包为 16px 子格纹理表（Array[Array]，下标 [y][x] 为纹理 ID，0 为空气）。
## 装载时交给 NativeTerrain，供碰撞、破坏和渲染读取。
static func scene_to_subgrid(scene: PackedInt32Array, sc: int, sr: int) -> Array[Array]:
	var out: Array[Array] = []
	for y in sr:
		var row: Array[int] = []
		row.resize(sc)
		for x in sc:
			row[x] = int((scene[y * sc + x] >> 12) & 0xFFF)
		out.append(row)
	return out


## 「场景」层 → 游戏网格。纹理取 16 子格中出现最多的非零者(平票取小 id),
## 形状 = 2×2 象限掩码(象限内有任一子格非空即置位)。
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
							var tex := (scene[y * sub_cols + x] >> 12) & 0xFFF
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


# CRC32 校验（IEEE 802.3 标准，多项式 0xEDB88320）：静态表驱动加速。
# 内部使用 64 位整型避免无符号 32 位整型溢出符号位。
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
