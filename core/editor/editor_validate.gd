class_name EditorValidate
extends RefCounted

# 移植自已退役的浏览器编辑器 core/80_validate.js(2026-11-09 删除,历史见 git)—— 尺寸钳制与整图校验。
# ★ 只报告、不阻止导出:errors = 真正非法(encodeMap 只拒 errors);warnings = 能导出但游戏里可能不按预期跑。
# ★ 纹理合法性判据的单一真相源 = data/tile_defs.json 的 tiles 键集(本模块只读那份 JSON,不抄表)。

const MAX_CELLS_W: int = 400
const MAX_CELLS_H: int = 300
const DEFAULT_CELLS_W: int = 125
const DEFAULT_CELLS_H: int = 75

# 复活点判据(与 core/sim/spawn_chooser.gd / tools/map_spawn_meta.gd 同源);全是 warning。
const RESPAWN_MIN_PER_SIDE: int = 5
const RESPAWN_MIN_SIDE_GAP: int = 5
const RESPAWN_EDGE_MARGIN: int = 10
const RESPAWN_BUCKETS: int = 3

const TILE_DEFS_PATH: String = "res://data/tile_defs.json"

static var _known_tex: Dictionary = {}
static var _known_tex_loaded: bool = false


# 用户输入一律钳制而不是报错回滚(输 99999 变成 400);非数字回落默认值。
static func clamp_map_size(w: Variant, h: Variant) -> Dictionary:
	var pw := _parse_int_prefix(str(w))
	var ph := _parse_int_prefix(str(h))
	var wi: int = int(pw["v"]) if bool(pw["ok"]) else DEFAULT_CELLS_W
	var hi: int = int(ph["v"]) if bool(ph["ok"]) else DEFAULT_CELLS_H
	return {
		"w": clampi(wi, 1, MAX_CELLS_W),
		"h": clampi(hi, 1, MAX_CELLS_H),
	}


static func validate_map(map: Dictionary) -> Dictionary:
	var errors: Array[String] = []
	var warnings: Array[String] = []
	var layers: Array = map.get("layers", [])
	if layers.size() != EditorConstants.LAYER_COUNT:
		errors.append("图层数不是 %d" % EditorConstants.LAYER_COUNT)
		return {"errors": errors, "warnings": warnings}
	var sub_cols := int(map.get("sub_cols", 0))
	var sub_rows := int(map.get("sub_rows", 0))
	if sub_cols % EditorConstants.SUB_PER_CELL != 0 or sub_rows % EditorConstants.SUB_PER_CELL != 0:
		errors.append("尺寸 %d×%d 不是 %d 的倍数" % [sub_cols, sub_rows, EditorConstants.SUB_PER_CELL])
	var n := sub_cols * sub_rows
	for layer_idx in EditorConstants.LAYER_COUNT:
		var layer = layers[layer_idx]
		if layer == null:
			continue
		var ld: Dictionary = layer
		var arr: PackedInt32Array = ld.get("desc", PackedInt32Array()) if String(ld.get("kind", "")) == "tex" \
				else ld.get("rgba", PackedInt32Array())
		if arr.size() != n:
			errors.append(EditorConstants.LAYER_NAMES[layer_idx] + "层长度不是 %d×%d" % [sub_cols, sub_rows])
	if not errors.is_empty():
		return {"errors": errors, "warnings": warnings}

	# ── 纹理合法性:tex 非 0 且不在 tile_defs 键集 ⇒ error(legacy id 应在读时已迁移,越界号没有图集槽位)──
	var known := _known_textures()
	if not known.is_empty():
		for layer_idx in EditorConstants.LAYER_COUNT:
			var layer = layers[layer_idx]
			if layer == null:
				continue
			var ld: Dictionary = layer
			if String(ld.get("kind", "")) != "tex" or not ld.has("desc"):
				continue
			var bad := {}
			var desc: PackedInt32Array = ld["desc"]
			for di in desc.size():
				var tx := EditorDesc.tex_of(desc[di])
				if tx == 0 or known.has(tx):
					continue
				bad[tx] = true
			if not bad.is_empty():
				var ids: Array = bad.keys()
				ids.sort()
				var parts: PackedStringArray = []
				for tid in ids:
					parts.append(str(tid))
				errors.append(EditorConstants.LAYER_NAMES[layer_idx] + "层有纹理 " + "/".join(parts) +
						" 不在 tile_defs(legacy id 应在读时已迁移,越界号没有对应图集槽位)")
		if not errors.is_empty():
			return {"errors": errors, "warnings": warnings}

	var cells_w := sub_cols / EditorConstants.SUB_PER_CELL
	var cells_h := sub_rows / EditorConstants.SUB_PER_CELL
	var scene: Variant = null
	if layers[EditorConstants.LAYER_SCENE] != null:
		scene = (layers[EditorConstants.LAYER_SCENE] as Dictionary)["desc"]

	# 出生点
	var players: Array = map.get("players", [])
	if players.is_empty():
		warnings.append("一个出生点都没有")
	if players.size() > 2:
		warnings.append("有 %d 个出生点,但游戏只认前两个(第 3 个及以后在 map_format.gd 里读不到)" % players.size())
	for i in players.size():
		warnings.append_array(_check_spawn(players[i], "出生点 P%d" % (i + 1), cells_w, cells_h, scene))
	var enemies: Array = map.get("enemies", [])
	for e in enemies:
		var ed: Dictionary = e
		warnings.append_array(_check_spawn(ed, "敌人 %s" % String(ed.get("type", "")), cells_w, cells_h, scene))

	# 所有图层全空
	var all_empty := true
	for layer_idx in EditorConstants.LAYER_COUNT:
		if not all_empty:
			break
		var layer = layers[layer_idx]
		if layer == null:
			continue
		var ld: Dictionary = layer
		var a: PackedInt32Array = ld.get("desc", PackedInt32Array()) if String(ld.get("kind", "")) == "tex" \
				else ld.get("rgba", PackedInt32Array())
		for k in a.size():
			if a[k] != 0:
				all_empty = false
				break
	if all_empty:
		warnings.append("所有图层全是空的")

	warnings.append_array(_check_respawns(map, cells_w, cells_h, scene))
	return {"errors": errors, "warnings": warnings}


static func _check_respawns(map: Dictionary, cells_w: int, cells_h: int, scene: Variant) -> Array[String]:
	var out: Array[String] = []
	var rs: Array = map.get("respawns", [])
	var pvp_intent: bool = (map.get("players", []) as Array).size() >= 2
	if rs.is_empty():
		if pvp_intent:
			out.append("这是 PvP 图(有 player2)但没有任何「# respawn」复活点:联机会走老图两点回退")
		return out
	var half := cells_w / 2.0
	for side in [1, 2]:
		var pts: Array = []
		for r in rs:
			var rd: Dictionary = r
			if int(rd.get("side", 0)) == side:
				pts.append(rd)
		var label := "侧 " + str(side)
		if pts.is_empty():
			out.append(label + " 一个复活点都没有(该侧要做联机出生就至少 %d 个)" % RESPAWN_MIN_PER_SIDE)
			continue
		if pts.size() < RESPAWN_MIN_PER_SIDE:
			out.append(label + " 只有 %d 个复活点,少于建议的 %d 个" % [pts.size(), RESPAWN_MIN_PER_SIDE])
		# ① 必须在自己的半区里
		var wrong: Array[String] = []
		for p in pts:
			var pd: Dictionary = p
			var px := int(pd["x"])
			var py := int(pd["y"])
			var own := px < half if side == 1 else px >= half
			if not own:
				wrong.append("%d,%d" % [px, py])
			out.append_array(_check_spawn(pd, label + " 复活点", cells_w, cells_h, scene))
		if not wrong.is_empty():
			out.append(label + " 有 %d 个点不在自己半区(%s):%s%s" % [
				wrong.size(), "左半 x<%s" % _num_str(half) if side == 1 else "右半 x≥%s" % _num_str(half),
				" ".join(wrong.slice(0, 3)), " …" if wrong.size() > 3 else ""])
		# ② 离接缝/中线太近
		var marg: Array[String] = []
		for p in pts:
			var pd: Dictionary = p
			var px := int(pd["x"])
			var m := mini(px, int(half) - px) if side == 1 else mini(px - int(half), cells_w - px)
			if m < RESPAWN_EDGE_MARGIN:
				marg.append("%d,%d" % [px, int(pd["y"])])
		if not marg.is_empty():
			out.append(label + " 有 %d 个点离接缝/半区中线不足 %d 格:%s%s" % [
				marg.size(), RESPAWN_EDGE_MARGIN, " ".join(marg.slice(0, 3)), " …" if marg.size() > 3 else ""])
		# ③ 同侧两两环面距离(只报最近的一对)
		var best_d := -1
		var best_a := {}
		var best_b := {}
		for i in pts.size():
			for j in range(i + 1, pts.size()):
				var a: Dictionary = pts[i]
				var bidx: Dictionary = pts[j]
				var d := maxi(_torus_dist(int(a["x"]), int(bidx["x"]), cells_w),
						_torus_dist(int(a["y"]), int(bidx["y"]), cells_h))
				if best_d < 0 or d < best_d:
					best_d = d
					best_a = a
					best_b = bidx
		if best_d >= 0 and best_d < RESPAWN_MIN_SIDE_GAP:
			out.append(label + " 有两个点挨得太近(环面距离 %d 格 < %d):(%d,%d)-(%d,%d)" % [
				best_d, RESPAWN_MIN_SIDE_GAP, int(best_a["x"]), int(best_a["y"]),
				int(best_b["x"]), int(best_b["y"])])
		# ④ 3×3 桶覆盖
		var bset := {}
		for p in pts:
			var pd: Dictionary = p
			var bx := int(floori(((int(pd["x"]) - (0 if side == 1 else int(half))) / (half / RESPAWN_BUCKETS))))
			var by := int(floori(int(pd["y"]) / (cells_h / float(RESPAWN_BUCKETS))))
			bx = clampi(bx, 0, RESPAWN_BUCKETS - 1)
			by = clampi(by, 0, RESPAWN_BUCKETS - 1)
			bset["%d/%d" % [bx, by]] = true
		var empty_b: Array[String] = []
		for cx in RESPAWN_BUCKETS:
			for cy in RESPAWN_BUCKETS:
				if not bset.has("%d/%d" % [cx, cy]):
					empty_b.append("(%d,%d)" % [cx, cy])
		if not empty_b.is_empty():
			out.append(label + " 的 3×3 桶有 %d 个空桶%s:%s" % [
				empty_b.size(), "(PvP 图要求每桶 ≥1)" if pvp_intent else "(非 PvP 图只作提示)",
				" ".join(empty_b.slice(0, 4))])
	return out


# 越界 / 落在实心格。返回 warning 文案数组(可能为空)。
static func _check_spawn(pt: Dictionary, label: String, cells_w: int, cells_h: int, scene: Variant) -> Array[String]:
	var out: Array[String] = []
	var px := int(pt["x"])
	var py := int(pt["y"])
	if px < 0 or py < 0 or px >= cells_w or py >= cells_h:
		out.append(label + " 坐标 (%d,%d) 越界(地图是 %d×%d 格)" % [px, py, cells_w, cells_h])
		return out
	if scene == null:
		return out
	var desc: PackedInt32Array = scene
	var sub_cols := cells_w * EditorConstants.SUB_PER_CELL
	# 「场景」层该格 4×4 子格全非空才算实心
	var solid := true
	for dy in EditorConstants.SUB_PER_CELL:
		if not solid:
			break
		for dx in EditorConstants.SUB_PER_CELL:
			if desc[(py * EditorConstants.SUB_PER_CELL + dy) * sub_cols + (px * EditorConstants.SUB_PER_CELL + dx)] == 0:
				solid = false
				break
	if solid:
		out.append(label + " 落在实心格里(场景层该格被填满)")
	return out


static func _torus_dist(a: int, b: int, n: int) -> int:
	var d := absi(a - b)
	return mini(d, n - d)


# ── tile_defs 键集(只读 JSON;load 一次缓存)──
static func _known_textures() -> Dictionary:
	if _known_tex_loaded:
		return _known_tex
	_known_tex_loaded = true
	if not FileAccess.file_exists(TILE_DEFS_PATH):
		return _known_tex
	var f := FileAccess.open(TILE_DEFS_PATH, FileAccess.READ)
	if f == null:
		return _known_tex
	var parsed = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		var tiles = parsed.get("tiles", {})
		if tiles is Dictionary:
			for k in tiles:
				_known_tex[int(String(k))] = true
	return _known_tex


# JS parseInt(w, 10) 的前缀语义:跳过前导空白、可选符号、数字前缀;没有数字前缀 ⇒ ok=false。
static func _parse_int_prefix(s: String) -> Dictionary:
	var idx := 0
	while idx < s.length() and EditorGeometry._is_js_space(s.unicode_at(idx)):
		idx += 1
	var sign := 1
	if idx < s.length() and (s.unicode_at(idx) == 43 or s.unicode_at(idx) == 45):
		if s.unicode_at(idx) == 45:
			sign = -1
		idx += 1
	var start := idx
	while idx < s.length():
		var cp := s.unicode_at(idx)
		if cp < 48 or cp > 57:
			break
		idx += 1
	if idx == start:
		return {"ok": false, "v": 0}
	return {"ok": true, "v": sign * int(s.substr(start, idx - start))}


# JS 的数字转字符串:整数不带 ".0"(half = cellsW/2 可能是半数,如 62.5)。
static func _num_str(v: float) -> String:
	if v == floorf(v):
		return str(int(v))
	return str(v)
