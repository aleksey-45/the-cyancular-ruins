class_name EditorDoc
extends RefCounted

# P2 文档模型:一张编辑器地图 + 稀疏 cells 撤销栈。纯逻辑、`-s` headless 可测;不碰磁盘、不依赖场景树。
# 契约见 docs/systems/editor/editor-godot.md §4;地图字典形状 = EditorMap.create_map()(7 层,0-2 tex / 3-6 color,4-6 可 null)。
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
# ★ 选区 / 剪贴板 / 镜像 / 整块移动 / 渐变的语义见 docs/systems/editor/editor-godot.md §4、§11
#   (一条稀疏条目、类型互斥、整块移动不环面回绕、缺席层不建层)。
# ★ meta 编辑产生快照式条目 {"kind":"meta","before","after"},只发 meta_changed 但照置 dirty。


signal changed(layer: int, subcells: PackedInt32Array)   # 子格索引 = sy * sub_cols + sx
signal structure_changed()                               # 换图 / 尺寸变 / 层增删(画布要整体重建)
signal meta_changed()                                    # 出生点/复活点/敌人改动(画布标记/面板刷新)
# undo/redo 栈可用性变了(新条目入栈 / undo / redo / load_map 清栈)。★ 与 changed 分开:
# 笔画期间 changed 每条都发,但条目要到 end_stroke 的 _flush_stroke_entry 才入栈 ——
# 撤销/重做按钮只听 changed 会在「画完第一笔」后一直是灰的(2026-11-12 复核抓到的真 bug)。
signal history_changed()

const CELLS_SCRIPT := preload("res://core/editor/editor_doc_cells.gd")
const EDIT_SCRIPT := preload("res://core/editor/editor_doc_edit.gd")
const META_SCRIPT := preload("res://core/editor/editor_doc_meta.gd")

# 域实现(纯静态函数,第一个参数是本对象;数据/信号仍归本类)。拆文件只为可读性,不改契约。
var _cells = CELLS_SCRIPT.new()
var _edit = EDIT_SCRIPT.new()
var _meta = META_SCRIPT.new()

var map: Dictionary = {}                # 契约 §1 形状;外部可读,别整体替换(用 load_map/new_map)
var active_layer: int = 1               # 0..6;0-2 读写 desc,3-6 读写 rgba(u32)
var selection: Rect2i = Rect2i()        # 子格矩形;w/h<=0 = 无选区(写入时已裁剪到图内)
var clipboard: Dictionary = {}          # {} 或 {"kind":"tex"|"color","w":int,"h":int,"values":PackedInt32Array}
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
	selection = Rect2i()                 # 换图清选区;clipboard 故意保留(跨图粘贴是合理用法)
	dirty = false
	structure_changed.emit()
	history_changed.emit()


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


# ── meta:出生点 / 复活点 / 敌人(入 undo 栈,快照式条目)──────────────────────
# 坐标一律先环面归一化到格([0,cells_w)×[0,cells_h));list 里存的也是格坐标(与 validate/MapFormat 同口径)。
# 所有改动 dirty=true、发 meta_changed(每次恰好一次);无改动不产生条目、不发信号。
# add_* 不做重复检查(旧 JS 同款);remove_* 删「坐标等同的第一个」。


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
	if _is_meta_entry(entry):
		_apply_meta_snapshot(entry["before"])
		_redo.append(entry)
		dirty = true                      # 撤销 ≠ 落盘,保持 dirty
		meta_changed.emit()
		history_changed.emit()
		return true
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
	history_changed.emit()
	return true


func redo() -> bool:
	if _stroke_open:
		end_stroke()                      # 结束笔画会清空 redo 链 ⇒ 这里之后通常直接 false
	if _redo.is_empty():
		return false
	var entry: Dictionary = _redo.pop_back()
	if _is_meta_entry(entry):
		_apply_meta_snapshot(entry["after"])
		_undo.append(entry)
		_trim_undo()
		dirty = true
		meta_changed.emit()
		history_changed.emit()
		return true
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
	history_changed.emit()
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


# 高层的原子操作(剪切/粘贴/清除/镜像/渐变)共用:先收尾未结束的笔画(避免半截笔画被并进
# 别人的条目),再写、记一条**多值**稀疏条目、发 changed。after 与 idxs 逐位对应 —— 这点与
# set_cells 的「同一笔同值」不同,所以不能走 _apply_change。
func _apply_cells_atomic(layer: int, store: PackedInt32Array, idxs: PackedInt32Array,
		before: PackedInt32Array, after: PackedInt32Array) -> int:
	if idxs.is_empty():
		return 0
	if _stroke_open:
		end_stroke()
	var count := mini(idxs.size(), after.size())
	for k in count:
		store[idxs[k]] = after[k]
	_store_write_back(layer, store)
	dirty = true
	_commit_entry(_make_entry(layer, idxs, before, after))
	changed.emit(layer, idxs)
	return count


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
	_undo_cells += _entry_cells(entry)
	_trim_undo()
	history_changed.emit()


func _trim_undo() -> void:
	var cap := maxi(0, undo_capacity)
	while _undo.size() > cap:
		_undo_cells -= _entry_cells(_undo[0])
		_undo.pop_front()
	var budget := maxi(0, undo_cells_budget)
	while _undo_cells > budget and _undo.size() > 1:
		_undo_cells -= _entry_cells(_undo[0])
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
func _to_i32(v: int) -> int:
	var u := v & 0xFFFFFFFF
	if u >= 0x80000000:
		return u - 0x100000000
	return u


func _filled(n: int, v: int) -> PackedInt32Array:
	var a := PackedInt32Array()
	a.resize(n)
	a.fill(v)
	return a


# ── 内部:选区 / 历史条目 / meta 辅助 ───────────────────────────────────────

# 当前选区的防御性裁剪(w/h<=0 或地图尺寸变了 ⇒ 空矩形)。
func _clipped_selection() -> Rect2i:
	if not _edit.has_selection(self):
		return Rect2i()
	var sz := sub_size()
	var x0 := maxi(0, selection.position.x)
	var y0 := maxi(0, selection.position.y)
	var x1 := mini(sz.x, selection.position.x + selection.size.x)
	var y1 := mini(sz.y, selection.position.y + selection.size.y)
	if x1 <= x0 or y1 <= y0:
		return Rect2i()
	return Rect2i(x0, y0, x1 - x0, y1 - y0)


# meta 条目没有 idxs ⇒ 计入撤销栈 cells 预算的格数 = 0。
static func _entry_cells(entry: Dictionary) -> int:
	if String(entry.get("kind", "")) == "meta":
		return 0
	var idxs_v: Variant = entry.get("idxs", null)
	if idxs_v is PackedInt32Array:
		return (idxs_v as PackedInt32Array).size()
	return 0


static func _is_meta_entry(entry: Dictionary) -> bool:
	return String(entry.get("kind", "")) == "meta"


# 失败形状唯一(契约 §0):不抛错、不 push_error。
func _fail(msg: String) -> Dictionary:
	return {"ok": false, "error": msg}


# 格坐标可写入(地图至少 1×1 格)。0 尺寸地图上 meta 编辑返回 -1/false。
func _meta_ready() -> bool:
	var sz := sub_size()
	return sz.x >= EditorConstants.SUB_PER_CELL and sz.y >= EditorConstants.SUB_PER_CELL


# 格坐标环面归一化(调用方已保证 _meta_ready)。
func _wrap_cell(cell: Vector2i) -> Vector2i:
	var sz := sub_size()
	var cw := sz.x / EditorConstants.SUB_PER_CELL
	var ch := sz.y / EditorConstants.SUB_PER_CELL
	if cw <= 0 or ch <= 0:
		return Vector2i.ZERO
	return Vector2i(posmod(cell.x, cw), posmod(cell.y, ch))


# 改动前后各拍一份深拷贝;无差异 ⇒ 不入栈、不发信号、返回 false。
func _commit_meta_change(before: Dictionary) -> bool:
	var after := _meta.meta_snapshot(self)
	if JSON.stringify(before) == JSON.stringify(after):
		return false
	_commit_entry({"kind": "meta", "before": before, "after": after})
	dirty = true
	meta_changed.emit()
	return true


# 从快照装回 map(逐项深拷贝:map 与历史条目绝不共用数组/字典)。
func _apply_meta_snapshot(snap: Dictionary) -> void:
	map["players"] = _copy_meta_entries(snap.get("players", []), "player")
	map["respawns"] = _copy_meta_entries(snap.get("respawns", []), "respawn")
	map["enemies"] = _copy_meta_entries(snap.get("enemies", []), "enemy")


# meta 三张表的深拷贝;kind = "player" / "respawn" / "enemy"(其它按 respawn 处理)。
func _copy_meta_entries(list: Variant, kind: String) -> Array:
	var out: Array = []
	if not (list is Array):
		return out
	for it in list:
		if not (it is Dictionary):
			continue
		var d: Dictionary = it
		match kind:
			"player":
				out.append({"x": int(d.get("x", 0)), "y": int(d.get("y", 0))})
			"enemy":
				out.append({"type": String(d.get("type", "")), "x": int(d.get("x", 0)),
						"y": int(d.get("y", 0))})
			_:
				out.append({"side": int(d.get("side", 0)), "x": int(d.get("x", 0)),
						"y": int(d.get("y", 0))})
	return out

# ── 委托:域实现拆到 editor_doc_{cells,edit,meta}.gd(签名/行为不变)──────────
func get_subcell(sx: int, sy: int) -> int:
	return _cells.get_subcell(self, sx, sy)

func sample(sx: int, sy: int) -> int:
	return _cells.sample(self, sx, sy)

func set_cells(cells: Array[Vector2i], desc: int) -> int:
	return _cells.set_cells(self, cells, desc)

func paint_line(a: Vector2i, b: Vector2i, desc: int) -> int:
	return _cells.paint_line(self, a, b, desc)

func flood_fill(start: Vector2i, desc: int) -> int:
	return _cells.flood_fill(self, start, desc)

func set_selection(sub_rect: Rect2i) -> void:
	return _edit.set_selection(self, sub_rect)

func clear_selection() -> void:
	return _edit.clear_selection(self)

func has_selection() -> bool:
	return _edit.has_selection(self)

func selection_size() -> Vector2i:
	return _edit.selection_size(self)

func copy_selection() -> Dictionary:
	return _edit.copy_selection(self)

func cut_selection() -> Dictionary:
	return _edit.cut_selection(self)

func paste_clipboard(at_cell: Vector2i) -> Dictionary:
	return _edit.paste_clipboard(self, at_cell)

func clear_selection_cells() -> int:
	return _edit.clear_selection_cells(self)

func move_selection_content(offset_sub: Vector2i) -> Dictionary:
	return _edit.move_selection_content(self, offset_sub)

func mirror_selection(axis: String) -> Dictionary:
	return _edit.mirror_selection(self, axis)

func paint_gradient(a_sub: Vector2i, b_sub: Vector2i, rgba0: int, rgba1: int,
		clip_selection: bool = false) -> Dictionary:
	return _edit.paint_gradient(self, a_sub, b_sub, rgba0, rgba1, clip_selection)

func add_player(cell: Vector2i) -> int:
	return _meta.add_player(self, cell)

func remove_player_at(cell: Vector2i) -> bool:
	return _meta.remove_player_at(self, cell)

func add_respawn(side: int, cell: Vector2i) -> int:
	return _meta.add_respawn(self, side, cell)

func remove_respawn_at(side: int, cell: Vector2i) -> bool:
	return _meta.remove_respawn_at(self, side, cell)

func add_enemy(enemy_type: String, cell: Vector2i) -> int:
	return _meta.add_enemy(self, enemy_type, cell)

func remove_enemy_at(cell: Vector2i) -> bool:
	return _meta.remove_enemy_at(self, cell)

func set_meta_position(kind: String, index: int, cell: Vector2i) -> bool:
	return _meta.set_meta_position(self, kind, index, cell)

func remove_meta_at(kind: String, index: int) -> bool:
	return _meta.remove_meta_at(self, kind, index)

func set_meta_enemy_type(index: int, type: String) -> bool:
	return _meta.set_meta_enemy_type(self, index, type)

func clear_meta(kind: String) -> int:
	return _meta.clear_meta(self, kind)

func meta_snapshot() -> Dictionary:
	return _meta.meta_snapshot(self)

func meta_entries() -> Array[Dictionary]:
	return _meta.meta_entries(self)