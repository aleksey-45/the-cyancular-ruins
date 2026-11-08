class_name EditorV3
extends RefCounted

# 镜像 level_editor/core/70_v3_text.js —— v3 文本 / 旧字母格式的解析与一次性迁移。
# ★ v3 的 packed = texture*16 + shape 是 v3 编码,与 v4 的 descriptor 毫无关系(规格 §3.6):
#   一律走 _v3_pack / _v3_tex_of / _v3_shape_of,不可与 EditorDesc.pack_desc / tex_of 混用。
# ★ 禁止 RegEx(客户端导出裁剪了 regex 模块):版本标记行的谓词、纹理位「3 位数字」校验、
#   旧字母表 0-9/A 全部手写。
# ★ 旧字母格式靠 2×2 折叠成 1 格 ⇒ 宽高必须都是 ≥2 的偶数:否则单行输入会抛裸 TypeError、
#   宽 3 × 高 4 会一句话不说地永久丢掉两整列;而迁移是单向的,吃掉的就找不回来(规格 §8)。

const SHAPE_HEX: String = "0123456789ABCDEF"
# 旧字母格式只认 0-9 与 A(大小写均可),与游戏侧 MapFormat._tile_char_to_value 一致。
const LEGACY_CHAR := {
	"0": 0, "1": 1, "2": 2, "3": 3, "4": 4,
	"5": 5, "6": 6, "7": 7, "8": 8, "9": 9, "A": 10,
}


# ── v3 编码(texture*16 + shape)──

# 纹理 0 或形状 0 一律是空气(0):两者缺一就没有可画的东西。
static func _v3_pack(texture: int, shape: int) -> int:
	if shape == 0 or texture == 0:
		return 0
	return (texture * 16 + shape) & 0xFFFF


# JS 的 (v / 16) | 0:本模块的 v 恒在 0..0xFFFF,右移等价且不触发整数除法告警。
static func _v3_tex_of(v: int) -> int:
	return v >> 4


static func _v3_shape_of(v: int) -> int:
	return v & 0xF


# ── v3 标记行 ──

# /^#\s*cyrm-v\d+(\s|$)/ —— 手写,不引 RegEx。
# ★ 版本标记行的唯一谓词:is_v3_text 与 parse_v3_text 两处都必须走它(宽严不是重点,两处同宽才是)。
static func is_v3_marker_line(line: String) -> bool:
	var s := EditorGeometry._trim_js(line)
	if s.is_empty() or s.unicode_at(0) != 35:   # '#'
		return false
	var i := 1
	while i < s.length() and EditorGeometry._is_js_space(s.unicode_at(i)):
		i += 1
	if s.substr(i, 6) != "cyrm-v":
		return false
	i += 6
	var digits := 0
	while i < s.length():
		var cp := s.unicode_at(i)
		if cp < 48 or cp > 57:   # 0-9
			break
		i += 1
		digits += 1
	if digits == 0:
		return false
	if i >= s.length():
		return true
	return EditorGeometry._is_js_space(s.unicode_at(i))


static func is_v3_text(text: String) -> bool:
	for line in _split_lines(text):
		if is_v3_marker_line(line):
			return true
	return false


# ── 解析 ──

# 解析 v3 文本(# cyrm-v\d+ 标记)或旧字母格式(无标记,自动 2×2 折叠)。
# 失败返回 {"ok": false, "error": String},文案照抄 JS 的 throw;成功返回
# {"ok": true, "parsed": {cells_w, cells_h, packed, players, enemies, respawns, comments}}。
static func parse_v3_text(text: String) -> Dictionary:
	var lines := _split_lines(text)
	var v3 := false
	for line in lines:
		if is_v3_marker_line(line):
			v3 = true
			break
	var rows: Array = []
	var width := -1
	var meta_text := ""
	for i in lines.size():
		var line := EditorGeometry._trim_js(lines[i])
		if line == "":
			continue
		if line.unicode_at(0) == 35:   # '#'
			# ★ 版本标记行不算注释(判据同上):漏了这句,# cyrm-v3 会被塞进 comments,
			#   导入→导出就往用户 meta 里塞垃圾。
			if is_v3_marker_line(line):
				continue
			meta_text += line + "\n"
			continue
		var row: Array[int] = []
		if v3:
			if line.length() % 4 != 0:
				return _fail("parseV3Text: 第 %d 行长度 %d 不是 4 的倍数" % [i + 1, line.length()])
			var j := 0
			while j < line.length():
				var tstr := line.substr(j, 3)
				if not _is_three_digits(tstr):
					return _fail('parseV3Text: 第 %d 行纹理位 "%s" 不是 3 位数字' % [i + 1, tstr])
				var raw_shape := line.substr(j + 3, 1)
				var sv := SHAPE_HEX.find(raw_shape.to_upper())
				if sv < 0:
					return _fail('parseV3Text: 第 %d 行非法形状字符 "%s"' % [i + 1, raw_shape])
				row.append(_v3_pack(tstr.to_int(), sv))
				j += 4
		else:
			for j in line.length():
				var raw_ch := line.substr(j, 1)
				var lv := int(LEGACY_CHAR.get(raw_ch.to_upper(), -1))
				if lv < 0:
					return _fail('parseV3Text: 第 %d 行非法字符 "%s"(旧格式只允许 0-9/A)'
							% [i + 1, raw_ch])
				row.append(lv)
		if width < 0:
			width = row.size()
		elif row.size() != width:
			return _fail("parseV3Text: 第 %d 行宽度 %d 与首行 %d 不一致"
					% [i + 1, row.size(), width])
		rows.append(row)
	if rows.is_empty():
		return _fail("parseV3Text: 地图里没有有效网格行")

	var meta := EditorMeta.parse_meta(meta_text)
	var players: Array = meta["players"]
	var enemies: Array = meta["enemies"]
	if not v3:
		# ★ 旧字母格式靠 2×2 折叠成 1 格,所以宽高必须都是 ≥2 的偶数 —— 否则单行输入抛裸 TypeError、
		#   宽 3 × 高 4 会一句话不说地永久丢掉两整列;按规格 §3.6 迁移是单向的,吃掉的就找不回来。
		if width < 2 or width % 2 != 0 or rows.size() < 2 or rows.size() % 2 != 0:
			return _fail("parseV3Text: 旧字母格式的宽高必须都是 ≥2 的偶数(收到 %d×%d),否则 2×2 折叠会静默丢掉边缘行/列"
					% [width, rows.size()])
		rows = _convert_legacy_2x2(rows)
		# 旧格式 2×2 → 1,spawn 坐标同步 ÷2(JS Math.floor:负坐标向 -∞ 取整)。
		var p2: Array = []
		for p in players:
			p2.append({"x": _half_floor(int(p["x"])), "y": _half_floor(int(p["y"]))})
		players = p2
		var e2: Array = []
		for e in enemies:
			e2.append({"type": String(e["type"]), "x": _half_floor(int(e["x"])),
					"y": _half_floor(int(e["y"]))})
		enemies = e2

	var cells_w: int = (rows[0] as Array).size()
	var cells_h := rows.size()
	var packed := PackedInt32Array()
	packed.resize(cells_w * cells_h)
	for y in cells_h:
		for x in cells_w:
			packed[y * cells_w + x] = int((rows[y] as Array)[x])
	return {
		"ok": true,
		"parsed": {
			"cells_w": cells_w,
			"cells_h": cells_h,
			"packed": packed,
			"players": players,
			"enemies": enemies,
			"respawns": meta["respawns"],
			"comments": meta["comments"],
		},
	}


# 旧 2×2 字母网格 → 1 格 packed(纹理取组内首个非零,形状 = 2×2 掩码);
# 逻辑与游戏侧 MapFormat.convert_old_grid 逐字对应。
static func _convert_legacy_2x2(rows: Array) -> Array:
	var h := rows.size()
	var w: int = (rows[0] as Array).size()
	var out: Array = []
	for ny in h / 2:
		var row: Array[int] = []
		for nx in w / 2:
			var shape := 0
			var tex := 0
			for sy in 2:
				for sx in 2:
					var ov: int = (rows[ny * 2 + sy] as Array)[nx * 2 + sx]
					if ov != 0:
						shape |= 1 << (sy * 2 + sx)
						if tex == 0:
							tex = ov
			row.append(_v3_pack(tex, shape))
		out.append(row)
	return out


# ── 取角映射(规格 §2.2,规范定义)──
# 子格全局坐标 (X,Y) → dst 目标矩形(世界像素,恒 16×16)+ src 源矩形(贴图块内偏移,恒 8×8);
# 调用方按 (texture-1) 定位贴图块再加这里的 src 偏移。
# ★ 象限由子格在 64px 格内的位置决定(X % 4 / Y % 4),不是存在数据里的字段。
# ★★ 调用方约束:X / Y 必须非负,调用方自己 posmod。本函数不做归一化、不报错,负 X 会安静地
#   给出贴图块外的源矩形(GDScript 的 % 与 JS 一样保留被除数符号)。
static func subcell_render(x: int, y: int) -> Dictionary:
	var qx := x % EditorConstants.SUB_PER_CELL
	var qy := y % EditorConstants.SUB_PER_CELL
	# 贴图块 32px,每格占其 1/4 = 8px。
	var block := 32 / EditorConstants.SUB_PER_CELL
	return {
		"dst": [x * EditorConstants.SUB_PX, y * EditorConstants.SUB_PX,
				EditorConstants.SUB_PX, EditorConstants.SUB_PX],
		"src": [qx * block, qy * block, block, block],
	}


# ── v3 → v4 迁移(规格 §3.6)──
# 旧掩码 bit (qy*2+qx) 为 1 → 新网格的 4 个子格 X∈[2qx,2qx+1], Y∈[2qy,2qy+1] 填同一纹理;
# spawn 坐标同步 ÷2。配合 subcell_render 的取角映射,迁移后视觉逐像素不变;
# 前/后/背景三层留空(v3 里没有它们)。
# ★ legacy 纹理 id 在**产出 desc 时**就迁移(v3 文本与旧字母格式都经这里;表缺席时 no-op)。
static func migrate_v3(parsed: Dictionary) -> Dictionary:
	var cells_w := int(parsed["cells_w"])
	var cells_h := int(parsed["cells_h"])
	var packed: PackedInt32Array = parsed["packed"]
	var map := EditorMap.create_map("", cells_w, cells_h)
	if map.is_empty():
		return map
	var layers: Array = map["layers"]
	var scene_layer: Dictionary = layers[EditorConstants.LAYER_SCENE]
	var scene: PackedInt32Array = scene_layer["desc"]
	var sub_cols := int(map["sub_cols"])
	for cy in cells_h:
		for cx in cells_w:
			var v := packed[cy * cells_w + cx]
			if v == 0:
				continue
			var tex := _v3_tex_of(v)
			var shape := _v3_shape_of(v)
			if tex == 0 or shape == 0:
				continue
			var d := EditorLegacy.migrate_descriptor(EditorDesc.neutral_desc(tex))
			for qy in 2:
				for qx in 2:
					if shape & (1 << (qy * 2 + qx)) == 0:
						continue
					for dy in 2:
						for dx in 2:
							var X := cx * EditorConstants.SUB_PER_CELL + qx * 2 + dx
							var Y := cy * EditorConstants.SUB_PER_CELL + qy * 2 + dy
							scene[Y * sub_cols + X] = d
	scene_layer["desc"] = scene
	var players: Array = []
	for p in parsed["players"]:
		players.append({"x": int(p["x"]), "y": int(p["y"])})
	var enemies: Array = []
	for e in parsed["enemies"]:
		enemies.append({"type": String(e["type"]), "x": int(e["x"]), "y": int(e["y"])})
	map["players"] = players
	map["enemies"] = enemies
	# ★ 与 JS 一致:respawns 不复制(JS migrateV3 只搬 players/enemies/comments —— v3 时代即便写了
	#   # respawn 也会在这里丢掉)。移植不夹带语义改动,原样保留该行为。
	map["comments"] = (parsed["comments"] as Array).duplicate()
	return map


# ── 小工具 ──

static func _fail(msg: String) -> Dictionary:
	return {"ok": false, "error": msg}


# /^[0-9]{3}$/ —— 手写,不引 RegEx(JS 的 \d 只认 ASCII 数字)。
static func _is_three_digits(s: String) -> bool:
	if s.length() != 3:
		return false
	for i in 3:
		var cp := s.unicode_at(i)
		if cp < 48 or cp > 57:
			return false
	return true


# JS 的 Math.floor(v / 2):GDScript 的整数 / 是向 0 截断,负坐标会差 1,不能用。
static func _half_floor(v: int) -> int:
	return floori(float(v) / 2.0)


# JS 的 String(text).split(/\r?\n/):先按 \n 切,再吃掉紧邻 \n 的那个 \r(孤立 \r 不是分隔符)。
static func _split_lines(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	for line in text.split("\n"):
		if line.ends_with("\r"):
			line = line.substr(0, line.length() - 1)
		out.append(line)
	return out
