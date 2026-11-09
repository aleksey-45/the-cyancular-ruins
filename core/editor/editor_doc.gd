class_name EditorDoc
extends RefCounted

# P2 文档模型:一张编辑器地图 + 稀疏 cells 撤销栈。纯逻辑、`-s` headless 可测;不碰磁盘、不依赖场景树。
# 契约见 docs/eng/editor-godot.md §4;地图字典形状 = EditorMap.create_map()(7 层,0-2 tex / 3-6 color,4-6 可 null)。
#
# ★ 撤销条目 = {layer:int, idxs:PackedInt32Array, before:PackedInt32Array, after:PackedInt32Array, color:bool}:
#   只记**真正变过的子格**(idxs = sy*sub_cols+sx),一个笔画也只有变动格的内存,不存整图快照。
#   before/after 与 idxs 逐位对应;after 是**每格**的新值(同一笔里可能不同 desc,所以不是单个标量)。
# ★ 环面世界:set_cells/get_subcell/flood_fill 的入参一律 posmod 到 [0,sub_cols)×[0,sub_rows) 兜底,
#   调用方(画布)已经归一化也不冲突;paint_line 的端点可能为负,Bresenham 走原始坐标、写入时再归一化。
# ★ 颜色层(3-6)的值是 RGBA u32 = 0xRRGGBBAA:set_cells 接受任意 int(按 32 位截断),get_subcell/sample
#   返回**无符号 u32**(0xRRGGBBAA);层内 PackedInt32Array 存的是同一批位的有符号读数——高位颜色落成
#   负数是正常的(0xFF336699 存 -13408615),要无符号值请 `v & 0xFFFFFFFF`,别拿存储值直接比颜色。
# ★ 纹理层(0-2)缺席 = 旧文件没有这一层:set_cells/flood_fill 一律无操作返回 0,**绝不**凭空补空层;
#   ensure_layer 只对颜色层按需建层(层从 null 变成 color 会发 structure_changed,画布要整体重建)。
# ★ 失败路径一律「无操作 + 返回 0/false」,不 push_error(编辑器里这些通常是用户输入)。
# ★ 撤销栈双上限:undo_capacity 条 + undo_cells_budget 累计 cells,超了丢最旧;
#   单条就超 budget 时保留最新一条(与 JS 编辑器 createHistory 的 `undos.length > 1` 一致:全丢 = 没有撤销)。
# ★ dirty 只在 load_map/new_map 清 false;undo/redo 不回退 dirty(撤销过的图依然没落盘)。


signal changed(layer: int, subcells: PackedInt32Array)   # 子格索引 = sy * sub_cols + sx
signal structure_changed()                               # 换图 / 尺寸变 / 层增删(画布要整体重建)

var map: Dictionary = {}                # 契约 §1 形状;外部可读,别整体替换(用 load_map/new_map)
var active_layer: int = 1               # 0..6;0-2 读写 desc,3-6 读写 rgba(u32)
var dirty: bool = false
var undo_capacity: int = 60             # 条数上限(超出丢最旧)
var undo_cells_budget: int = 2_000_000  # 撤销栈累计 cells 上限(超出丢最旧;单条超预算时保留最新一条)

var _undo: Array[Dictionary] = []
var _redo: Array[Dictionary] = []
var _undo_cells: int = 0
var _stroke_open := false
var _stroke_entry: Dictionary = {}
var _stroke_pos: Dictionary = {}         # idx -> 该格在 _stroke_entry 里的位置(同一格重复涂时 before 取第一次)


# ── 文档装载 ────────────────────────────────────────────────────────────────

# 装入一张已有的图(已由 EditorIO 做过 legacy 迁移,本函数不重复迁移)。
func load_map(m: Dictionary) -> void:
	map = m
	_undo.clear()
	_redo.clear()
	_undo_cells = 0
	_stroke_open = false
	_stroke_entry = {}
	_stroke_pos.clear()
	dirty = false
	structure_changed.emit()


# 建一张空图;尺寸非法时无操作(不抛错)。meta 出生点不在这里加(调用方的事)。
func new_map(map_name: String, cells_w: int, cells_h: int) -> void:
	if cells_w <= 0 or cells_h <= 0:
		return
	var m: Dictionary = EditorMap.create_map(map_name, cells_w, cells_h)
	if m.is_empty():
		return
	load_map(m)


func sub_size() -> Vector2i:
	return Vector2i(int(map.get("sub_cols", 0)), int(map.get("sub_rows", 0)))


# ── 读取 ────────────────────────────────────────────────────────────────────

# 环面归一化后读 active_layer:纹理层返回 desc,颜色层返回 u32 颜色;缺席层返回 0。
func get_subcell(sx: int, sy: int) -> int:
	var sz := sub_size()
	if sz.x <= 0 or sz.y <= 0:
		return 0
	var layer := active_layer
	if layer < 0 or layer >= EditorConstants.LAYER_COUNT:
		return 0
	var store_v: Variant = _read_array(layer)
	if store_v == null:
		return 0
	var store: PackedInt32Array = store_v
	var idx := posmod(sy, sz.y) * sz.x + posmod(sx, sz.x)
	if idx < 0 or idx >= store.size():
		return 0
	var v := store[idx]
	if EditorConstants.is_color_layer(layer):
		return v & 0xFFFFFFFF
	return v


# 吸管:与 get_subcell 同口径(active_layer 的 desc / 颜色层的 u32 颜色)。
func sample(sx: int, sy: int) -> int:
	return get_subcell(sx, sy)


# ── 写入 ────────────────────────────────────────────────────────────────────

# 批量写 active_layer(环面归一化、去重、跳过写同值),返回实际改动格数。
# 0 改动 ⇒ 不 push undo、不发 changed、不动 dirty。
func set_cells(cells: Array[Vector2i], desc: int) -> int:
	var sz := sub_size()
	if sz.x <= 0 or sz.y <= 0:
		return 0
	var layer := active_layer
	if layer < 0 or layer >= EditorConstants.LAYER_COUNT:
		return 0
	var new_val := _to_i32(desc)
	var store_v: Variant = _read_array(layer)
	if store_v == null:
		if not EditorConstants.is_color_layer(layer):
			return 0                      # 纹理层缺席:不许凭空补层
		if new_val == 0:
			return 0                      # 写「透明」到不存在的颜色层 = 无操作,别白建一层
		store_v = _ensure_color_layer(layer)
		if store_v == null:
			return 0
	var store: PackedInt32Array = store_v
	var seen := {}
	var idxs := PackedInt32Array()
	var before := PackedInt32Array()
	for p in cells:
		var pt: Vector2i = p
		var idx := posmod(pt.y, sz.y) * sz.x + posmod(pt.x, sz.x)
		if seen.has(idx):
			continue
		seen[idx] = true
		var old := store[idx]
		if old == new_val:
			continue
		idxs.append(idx)
		before.append(old)
	if idxs.is_empty():
		return 0
	return _apply_change(layer, store, idxs, before, new_val)


# 直线 = Bresenham(含两端,与旧浏览器编辑器 lineCells 同算法;源已退役,历史见 git);
# 两端坐标可越界/为负,写入时逐格环面归一化。
func paint_line(a: Vector2i, b: Vector2i, desc: int) -> int:
	var cells: Array[Vector2i] = []
	var dx := absi(b.x - a.x)
	var dy := absi(b.y - a.y)
	var sx := 1 if a.x < b.x else -1
	var sy := 1 if a.y < b.y else -1
	var err := dx - dy
	var x := a.x
	var y := a.y
	while true:
		cells.append(Vector2i(x, y))
		if x == b.x and y == b.y:
			break
		var e2 := 2 * err
		if e2 > -dy:
			err -= dy
			x += sx
		if e2 < dx:
			err += dx
			y += sy
	return set_cells(cells, desc)


# 油漆桶:4 邻接、按「当前值相等」扩散,环面接缝算连通;返回实际改动格数。
func flood_fill(start: Vector2i, desc: int) -> int:
	var sz := sub_size()
	if sz.x <= 0 or sz.y <= 0:
		return 0
	var layer := active_layer
	if layer < 0 or layer >= EditorConstants.LAYER_COUNT:
		return 0
	var new_val := _to_i32(desc)
	var store_v: Variant = _read_array(layer)
	if store_v == null:
		if not EditorConstants.is_color_layer(layer):
			return 0                      # 纹理层缺席:不许凭空补层
		if new_val == 0:
			return 0
		store_v = _ensure_color_layer(layer)
		if store_v == null:
			return 0
	var store: PackedInt32Array = store_v
	var n := sz.x * sz.y
	var start_idx := posmod(start.y, sz.y) * sz.x + posmod(start.x, sz.x)
	var target := store[start_idx]
	if target == new_val:
		return 0
	var visited := PackedByteArray()
	visited.resize(n)
	visited[start_idx] = 1
	var queue := PackedInt32Array([start_idx])
	var idxs := PackedInt32Array()
	var before := PackedInt32Array()
	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	while not queue.is_empty():
		var idx := queue[queue.size() - 1]
		queue.remove_at(queue.size() - 1)
		idxs.append(idx)
		before.append(store[idx])
		var cx := idx % sz.x
		var cy := idx / sz.x
		for d in dirs:
			var ni := posmod(cy + d.y, sz.y) * sz.x + posmod(cx + d.x, sz.x)
			if visited[ni] == 1 or store[ni] != target:
				continue
			visited[ni] = 1
			queue.append(ni)
	return _apply_change(layer, store, idxs, before, new_val)


# ── 校验 / 编码接线 ─────────────────────────────────────────────────────────

func validate() -> Dictionary:
	return EditorValidate.validate_map(map)


func to_bytes(opts: Dictionary = {}) -> Dictionary:
	return EditorCodec.encode_map(map, opts)


# ── 撤销 / 重做 ─────────────────────────────────────────────────────────────

# 连续笔画合并成一条 undo:第一笔前调 begin_stroke,最后一笔后调 end_stroke。
func begin_stroke() -> void:
	if _stroke_open:
		end_stroke()
	_stroke_open = true
	_stroke_entry = {}
	_stroke_pos.clear()


# 结束合并;空笔画(一格没改)不产生 undo 条目。
func end_stroke() -> void:
	if not _stroke_open:
		return
	_stroke_open = false
	_flush_stroke_entry()


func undo() -> bool:
	if _stroke_open:
		end_stroke()                      # 笔画还没收尾:先把它落成一条,再撤它
	if _undo.is_empty():
		return false
	var entry: Dictionary = _undo.pop_back()
	var idxs: PackedInt32Array = entry["idxs"]
	_undo_cells -= idxs.size()
	var layer := int(entry["layer"])
	var store_v: Variant = _write_target(layer)
	if store_v == null:
		_undo.append(entry)               # 图层没了(外部改坏 map):不动栈
		_undo_cells += idxs.size()
		return false
	_apply_values(layer, store_v, idxs, entry["before"])
	_redo.append(entry)
	dirty = true                          # 撤销 ≠ 落盘,保持 dirty
	changed.emit(layer, idxs)
	return true


func redo() -> bool:
	if _stroke_open:
		end_stroke()                      # 结束笔画会清空 redo 链 ⇒ 这里之后通常直接 false
	if _redo.is_empty():
		return false
	var entry: Dictionary = _redo.pop_back()
	var idxs: PackedInt32Array = entry["idxs"]
	var layer := int(entry["layer"])
	var store_v: Variant = _write_target(layer)
	if store_v == null:
		_redo.append(entry)
		return false
	_apply_values(layer, store_v, idxs, entry["after"])
	_undo.append(entry)
	_undo_cells += idxs.size()
	_trim_undo()
	dirty = true
	changed.emit(layer, idxs)
	return true


func can_undo() -> bool:
	return not _undo.is_empty()


func can_redo() -> bool:
	return not _redo.is_empty()


func undo_count() -> int:
	return _undo.size()


# ── 内部:写入与历史 ────────────────────────────────────────────────────────

# 把 idxs 处写成 new_val:落笔、写回层字典、dirty、记 undo/合并笔画、发 changed;返回改动格数。
func _apply_change(layer: int, store: PackedInt32Array, idxs: PackedInt32Array,
		before: PackedInt32Array, new_val: int) -> int:
	for idx in idxs:
		store[idx] = new_val
	_store_write_back(layer, store)
	dirty = true
	if _stroke_open:
		_merge_stroke(layer, idxs, before, new_val)
	else:
		_commit_entry(_make_entry(layer, idxs, before, _filled(idxs.size(), new_val)))
	changed.emit(layer, idxs)
	return idxs.size()


# undo/redo 写回:values 与 idxs 逐位对应。★ 层号必须用条目里的 layer,不能用 active_layer
# (用户可能先切层再按 Ctrl+Z;写回错层会把另一层的数组整个覆盖掉)。
func _apply_values(layer: int, store_v: Variant, idxs: PackedInt32Array, values: PackedInt32Array) -> void:
	var store: PackedInt32Array = store_v
	var count := mini(idxs.size(), values.size())
	for k in count:
		store[idxs[k]] = values[k]
	_store_write_back(layer, store)


func _make_entry(layer: int, idxs: PackedInt32Array, before: PackedInt32Array,
		after: PackedInt32Array) -> Dictionary:
	return {
		"layer": layer,
		"idxs": idxs,
		"before": before,
		"after": after,
		"color": EditorConstants.is_color_layer(layer),
	}


# 一笔里同一格可能被涂多次(after 随最后一次,before 永远是笔画开始前的值)。
func _merge_stroke(layer: int, idxs: PackedInt32Array, before: PackedInt32Array, new_val: int) -> void:
	if _stroke_entry.is_empty() or int(_stroke_entry["layer"]) != layer:
		# 一笔里换了层:先把已有那层落栈,再为当前层开新条目(仍处于 stroke 合并中)
		_flush_stroke_entry()
		_stroke_entry = _make_entry(layer, PackedInt32Array(), PackedInt32Array(), PackedInt32Array())
		_stroke_pos.clear()
	var e_idx: PackedInt32Array = _stroke_entry["idxs"]
	var e_before: PackedInt32Array = _stroke_entry["before"]
	var e_after: PackedInt32Array = _stroke_entry["after"]
	for k in idxs.size():
		var idx := idxs[k]
		if _stroke_pos.has(idx):
			e_after[int(_stroke_pos[idx])] = new_val
		else:
			_stroke_pos[idx] = e_idx.size()
			e_idx.append(idx)
			e_before.append(before[k])
			e_after.append(new_val)
	# Packed 数组是写时复制:改动本地副本后必须写回条目,否则笔画记录丢格
	_stroke_entry["idxs"] = e_idx
	_stroke_entry["before"] = e_before
	_stroke_entry["after"] = e_after


func _flush_stroke_entry() -> void:
	if _stroke_entry.is_empty():
		return
	var e: Dictionary = _stroke_entry
	_stroke_entry = {}
	_stroke_pos.clear()
	if (e["idxs"] as PackedInt32Array).is_empty():
		return                            # 空笔画:不产生 undo 条目
	_commit_entry(e)


# 新编辑入栈并断掉 redo 链(标准语义)。
func _commit_entry(entry: Dictionary) -> void:
	_redo.clear()
	_undo.append(entry)
	_undo_cells += (entry["idxs"] as PackedInt32Array).size()
	_trim_undo()


func _trim_undo() -> void:
	var cap := maxi(0, undo_capacity)
	while _undo.size() > cap:
		_undo_cells -= (_undo[0]["idxs"] as PackedInt32Array).size()
		_undo.pop_front()
	var budget := maxi(0, undo_cells_budget)
	while _undo_cells > budget and _undo.size() > 1:
		_undo_cells -= (_undo[0]["idxs"] as PackedInt32Array).size()
		_undo.pop_front()


# ── 内部:层访问 ────────────────────────────────────────────────────────────

# 读 active_layer 的存储数组(tex→desc / color→rgba);层缺席或非法返回 null。
func _read_array(layer: int) -> Variant:
	var layers: Array = map.get("layers", [])
	if layer < 0 or layer >= layers.size():
		return null
	var ld = layers[layer]
	if not (ld is Dictionary):
		return null
	var d: Dictionary = ld
	if String(d.get("kind", "")) == "tex":
		return d.get("desc", null)
	return d.get("rgba", null)


# undo/redo 的写目标:颜色层若被外部清成 null 则按需重建;纹理层缺席返回 null。
func _write_target(layer: int) -> Variant:
	var store_v: Variant = _read_array(layer)
	if store_v != null:
		return store_v
	if not EditorConstants.is_color_layer(layer):
		return null
	return _ensure_color_layer(layer)


# 只对颜色层按需建层;建层 = 结构变化,发 structure_changed。
func _ensure_color_layer(layer: int) -> Variant:
	if not EditorConstants.is_color_layer(layer):
		return null
	var sz := sub_size()
	if sz.x <= 0 or sz.y <= 0:
		return null
	var created: Variant = EditorMap.ensure_layer(map, layer)
	if created == null:
		return null
	structure_changed.emit()
	var d: Dictionary = created
	return d.get("rgba", null)


func _store_write_back(layer: int, store: PackedInt32Array) -> void:
	var layers: Array = map.get("layers", [])
	if layer < 0 or layer >= layers.size():
		return
	var ld = layers[layer]
	if not (ld is Dictionary):
		return
	var d: Dictionary = ld
	if String(d.get("kind", "")) == "tex":
		d["desc"] = store
	else:
		d["rgba"] = store


# u32 → PackedInt32Array 里存的有符号 32 位(0xFF000000 存 -16777216 是正常的)。
static func _to_i32(v: int) -> int:
	var u := v & 0xFFFFFFFF
	if u >= 0x80000000:
		return u - 0x100000000
	return u


static func _filled(n: int, v: int) -> PackedInt32Array:
	var a := PackedInt32Array()
	a.resize(n)
	a.fill(v)
	return a
