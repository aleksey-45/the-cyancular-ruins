extends RefCounted

# 从 EditorDoc 拆出的 出生点 / 复活点 / 敌人 meta 域(无 class_name,由 EditorDoc preload)。
# 纯静态函数:第一个参数是 EditorDoc(数据与信号仍归 doc,这里只放操作)。

static func add_player(doc, cell: Vector2i) -> int:
	if not doc._meta_ready():
		return -1
	var before = meta_snapshot(doc)
	var c = doc._wrap_cell(cell)
	var players: Array = doc.map.get("players", [])
	players.append({"x": c.x, "y": c.y})
	doc.map["players"] = players
	doc._commit_meta_change(before)
	return players.size() - 1



static func remove_player_at(doc, cell: Vector2i) -> bool:
	if not doc._meta_ready():
		return false
	var c = doc._wrap_cell(cell)
	var players: Array = doc.map.get("players", [])
	for i in players.size():
		var d: Dictionary = players[i]
		if int(d.get("x", -1)) == c.x and int(d.get("y", -1)) == c.y:
			var before = meta_snapshot(doc)
			players.remove_at(i)
			doc.map["players"] = players
			doc._commit_meta_change(before)
			return true
	return false



# side 只认 1|2,否则 -1。
static func add_respawn(doc, side: int, cell: Vector2i) -> int:
	if side != 1 and side != 2:
		return -1
	if not doc._meta_ready():
		return -1
	var before = meta_snapshot(doc)
	var c = doc._wrap_cell(cell)
	var respawns: Array = doc.map.get("respawns", [])
	respawns.append({"side": side, "x": c.x, "y": c.y})
	doc.map["respawns"] = respawns
	doc._commit_meta_change(before)
	return respawns.size() - 1



static func remove_respawn_at(doc, side: int, cell: Vector2i) -> bool:
	if side != 1 and side != 2:
		return false
	if not doc._meta_ready():
		return false
	var c = doc._wrap_cell(cell)
	var respawns: Array = doc.map.get("respawns", [])
	for i in respawns.size():
		var d: Dictionary = respawns[i]
		if int(d.get("side", 0)) == side and int(d.get("x", -1)) == c.x \
				and int(d.get("y", -1)) == c.y:
			var before = meta_snapshot(doc)
			respawns.remove_at(i)
			doc.map["respawns"] = respawns
			doc._commit_meta_change(before)
			return true
	return false



static func add_enemy(doc, enemy_type: String, cell: Vector2i) -> int:
	if not doc._meta_ready():
		return -1
	var before = meta_snapshot(doc)
	var c = doc._wrap_cell(cell)
	var enemies: Array = doc.map.get("enemies", [])
	enemies.append({"type": enemy_type, "x": c.x, "y": c.y})
	doc.map["enemies"] = enemies
	doc._commit_meta_change(before)
	return enemies.size() - 1



static func remove_enemy_at(doc, cell: Vector2i) -> bool:
	if not doc._meta_ready():
		return false
	var c = doc._wrap_cell(cell)
	var enemies: Array = doc.map.get("enemies", [])
	for i in enemies.size():
		var d: Dictionary = enemies[i]
		if int(d.get("x", -1)) == c.x and int(d.get("y", -1)) == c.y:
			var before = meta_snapshot(doc)
			enemies.remove_at(i)
			doc.map["enemies"] = enemies
			doc._commit_meta_change(before)
			return true
	return false



# 移动一条 meta 条目到新格坐标(环面归一化)。kind 只认 "player"|"respawn"|"enemy";
# 只改 x/y,保留 respawn.side / enemy.type(不重造条目字典)。
# 越界索引 / 非法 kind / 原地不动 ⇒ false,不入栈、不发信号;成功 ⇒ 恰好一条 meta 快照条目
# + 一次 meta_changed + dirty=true(与 add_*/remove_* 同口径)。
static func set_meta_position(doc, kind: String, index: int, cell: Vector2i) -> bool:
	if not doc._meta_ready():
		return false
	var list_name = _meta_list_name(kind)
	if list_name.is_empty():
		return false
	var entries: Array = doc.map.get(list_name, [])
	if index < 0 or index >= entries.size():
		return false
	var raw: Variant = entries[index]
	if not (raw is Dictionary):
		return false
	var d: Dictionary = raw
	var c = doc._wrap_cell(cell)
	# 判「原地不动」用的是快照归一化后的坐标口径(缺 x/y 时按 0),与新位置比较。
	if int(d.get("x", 0)) == c.x and int(d.get("y", 0)) == c.y:
		return false                       # 原地不动:不产生条目、不发信号
	var before = meta_snapshot(doc)
	d["x"] = c.x
	d["y"] = c.y
	entries[index] = d
	doc.map[list_name] = entries
	doc._commit_meta_change(before)
	return true



# 按索引删除一条 meta(kind 只认 "player"|"respawn"|"enemy")。
# 数组原地 remove_at ⇒ 剩余条目保持相对顺序(与 remove_*_at 的按坐标删互补:面板列表按行号删)。
# 非法 kind / 索引越界 / 条目损坏 ⇒ false,不入栈、不发信号;成功 ⇒ 恰好一条 meta 快照条目
# + 一次 meta_changed + dirty=true。
static func remove_meta_at(doc, kind: String, index: int) -> bool:
	if not doc._meta_ready():
		return false
	var list_name = _meta_list_name(kind)
	if list_name.is_empty():
		return false
	var entries: Array = doc.map.get(list_name, [])
	if index < 0 or index >= entries.size():
		return false
	var raw: Variant = entries[index]
	if not (raw is Dictionary):
		return false
	var before = meta_snapshot(doc)
	entries.remove_at(index)
	doc.map[list_name] = entries
	return doc._commit_meta_change(before)



# 只改 enemies[index].type,保留 x/y(不重造条目字典)。
# 索引越界 / 条目损坏 / type 空白 / 与现类型相同 ⇒ false(不入栈、不发信号);
# 成功 ⇒ 恰好一条 meta 快照条目 + 一次 meta_changed + dirty=true。
static func set_meta_enemy_type(doc, index: int, type: String) -> bool:
	if not doc._meta_ready():
		return false
	if type.strip_edges().is_empty():
		return false
	var enemies: Array = doc.map.get("enemies", [])
	if index < 0 or index >= enemies.size():
		return false
	var raw: Variant = enemies[index]
	if not (raw is Dictionary):
		return false
	var d: Dictionary = raw
	if String(d.get("type", "")) == type:
		return false                       # 同类型:不产生条目、不发信号
	var before = meta_snapshot(doc)
	d["type"] = type
	enemies[index] = d
	doc.map["enemies"] = enemies
	return doc._commit_meta_change(before)



# kind 只认 "players"|"respawns"|"enemies"|"all";返回删除条数,非法 kind 返回 -1。
static func clear_meta(doc, kind: String) -> int:
	if not doc._meta_ready():
		return -1
	if kind != "players" and kind != "respawns" and kind != "enemies" and kind != "all":
		return -1
	var before = meta_snapshot(doc)
	var removed = 0
	if kind == "players" or kind == "all":
		var players: Array = doc.map.get("players", [])
		removed += players.size()
		if not players.is_empty():
			doc.map["players"] = []
	if kind == "respawns" or kind == "all":
		var respawns: Array = doc.map.get("respawns", [])
		removed += respawns.size()
		if not respawns.is_empty():
			doc.map["respawns"] = []
	if kind == "enemies" or kind == "all":
		var enemies: Array = doc.map.get("enemies", [])
		removed += enemies.size()
		if not enemies.is_empty():
			doc.map["enemies"] = []
	if removed == 0:
		return 0
	doc._commit_meta_change(before)
	return removed



# 深拷贝 {"players","respawns","enemies"}:改返回值不影响 doc(undo 快照同样靠它隔离)。
static func meta_snapshot(doc) -> Dictionary:
	return {
		"players": doc._copy_meta_entries(doc.map.get("players", []), "player"),
		"respawns": doc._copy_meta_entries(doc.map.get("respawns", []), "respawn"),
		"enemies": doc._copy_meta_entries(doc.map.get("enemies", []), "enemy"),
	}



# 只读扁平列表(顺序 = players → respawns → enemies),供面板 / 画布命中统一按行遍历:
#   player  → {"kind":"player","index":i,"x":int,"y":int}
#   respawn → {"kind":"respawn","index":i,"side":int,"x":int,"y":int}
#   enemy   → {"kind":"enemy","index":i,"type":String,"x":int,"y":int}
# 返回的是新建字典(改返回值不影响 doc);不产生 undo / 信号 / dirty。损坏条目跳过(不按 respawn 兜底)。
static func meta_entries(doc) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var players: Array = doc.map.get("players", [])
	for i in players.size():
		var raw_p: Variant = players[i]
		if not (raw_p is Dictionary):
			continue
		var dp: Dictionary = raw_p
		out.append({"kind": "player", "index": i, "x": int(dp.get("x", 0)),
				"y": int(dp.get("y", 0))})
	var respawns: Array = doc.map.get("respawns", [])
	for i in respawns.size():
		var raw_r: Variant = respawns[i]
		if not (raw_r is Dictionary):
			continue
		var dr: Dictionary = raw_r
		out.append({"kind": "respawn", "index": i, "side": int(dr.get("side", 0)),
				"x": int(dr.get("x", 0)), "y": int(dr.get("y", 0))})
	var enemies: Array = doc.map.get("enemies", [])
	for i in enemies.size():
		var raw_e: Variant = enemies[i]
		if not (raw_e is Dictionary):
			continue
		var de: Dictionary = raw_e
		out.append({"kind": "enemy", "index": i, "type": String(de.get("type", "")),
				"x": int(de.get("x", 0)), "y": int(de.get("y", 0))})
	return out


# ── 校验 / 编码接线 ─────────────────────────────────────────────────────────


static func _meta_list_name(kind: String) -> String:
	match kind:
		"player":
			return "players"
		"respawn":
			return "respawns"
		"enemy":
			return "enemies"
	return ""


# kind 只认 "players"|"respawns"|"enemies"|"all";返回删除条数,非法 kind 返回 -1。
