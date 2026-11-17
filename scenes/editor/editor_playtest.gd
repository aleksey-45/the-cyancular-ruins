extends RefCounted

# 编辑器 ↔ 试玩 的交接单(只有编辑器脚本引用;服务端导出排除 scenes/editor/*)。
# 试玩 = 换场景,编辑器实例会被拆掉 ⇒ 这里暂存同一个 EditorDoc(撤销栈/选区/dirty 不掉),回来时取回。
# 临时地图写在 TMP_MAP(不在 user://maps ⇒ 不出现在「打开地图」列表),退出试玩时由 Level0 还回原地图路径。

const TMP_MAP := "user://editor_playtest.cyrm"

static var _doc: EditorDoc = null
static var _path := ""
static var _picked_map := ""
static var _spawn := Vector2i(-1, -1)


static func stash(doc: EditorDoc, path: String, spawn_cell: Vector2i, picked_map: String) -> void:
	_doc = doc
	_path = path
	_picked_map = picked_map
	_spawn = spawn_cell


# 空字典 = 不是从试玩回来;否则交出 {doc, path, picked_map, spawn} 并清空(只能取一次)。
static func take_restore() -> Dictionary:
	if _doc == null:
		return {}
	var out := {"doc": _doc, "path": _path, "picked_map": _picked_map, "spawn": _spawn}
	_doc = null
	_path = ""
	_picked_map = ""
	_spawn = Vector2i(-1, -1)
	return out


static func pending() -> bool:
	return _doc != null
