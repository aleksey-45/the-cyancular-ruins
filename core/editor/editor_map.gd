class_name EditorMap
extends RefCounted

# 移植自已退役的浏览器编辑器 core/10_map.js(2026-11-09 删除,历史见 git)—— 地图对象与下标。
# ★ 全部用 PackedInt32Array:7 层 × 大图若用嵌套 Array 会到几十 MB 且 GC 压力巨大。
# ★ 下标一律 = y * sub_cols + x(行主序),与文件里的排布一致。


# 建一张空图:只分配层 0-3(历史文件恒有背景 100%),4-6 按需由 ensure_layer 建。
# 尺寸非法时返回空字典(调用方应先 clamp_map_size);这是程序员错误,不是用户输入路径。
static func create_map(name: String, cells_w: int, cells_h: int) -> Dictionary:
	if cells_w <= 0 or cells_h <= 0:
		push_error("EditorMap.create_map: 格数必须是正整数,收到 %d×%d" % [cells_w, cells_h])
		return {}
	var sub_cols := cells_w * EditorConstants.SUB_PER_CELL
	var sub_rows := cells_h * EditorConstants.SUB_PER_CELL
	var n := sub_cols * sub_rows
	var layers: Array = []
	for layer_idx in EditorConstants.LAYER_COUNT:
		if layer_idx < 3:
			layers.append({"kind": "tex", "desc": _zeros(n)})
		elif layer_idx == EditorConstants.LAYER_BG:
			layers.append({"kind": "color", "rgba": _zeros(n)})
		else:
			layers.append(null)
	return {
		"name": name,
		"sub_cols": sub_cols,
		"sub_rows": sub_rows,
		"layers": layers,
		"players": [],
		"enemies": [],
		"respawns": [],
		"comments": [],
	}


static func cells_w_of(map: Dictionary) -> int:
	return int(map["sub_cols"]) / EditorConstants.SUB_PER_CELL


static func cells_h_of(map: Dictionary) -> int:
	return int(map["sub_rows"]) / EditorConstants.SUB_PER_CELL


static func sub_index(sub_cols: int, x: int, y: int) -> int:
	return y * sub_cols + x


# 按需建颜色层:背景 75%/50%/25% 默认 null,第一次要往里画时才分配。
# ★ 只对颜色层生效;纹理层缺席是「这张图没有这一层」(旧文件),绝不凭空补一层空的。
static func ensure_layer(map: Dictionary, layer: int) -> Variant:
	var layers: Array = map.get("layers", [])
	if layers.is_empty() or layer < 0 or layer >= EditorConstants.LAYER_COUNT:
		return null
	if layers[layer] != null:
		return layers[layer]
	if EditorConstants.LAYER_KINDS[layer] != "color":
		return null
	var ld := {"kind": "color", "rgba": _zeros(int(map["sub_cols"]) * int(map["sub_rows"]))}
	layers[layer] = ld
	return ld


static func _zeros(n: int) -> PackedInt32Array:
	var a := PackedInt32Array()
	a.resize(n)
	return a
