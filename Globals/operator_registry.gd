class_name OperatorRegistry
extends RefCounted

# 干员注册表(实验性,DevTools 卡编辑器产出):读 Globals/operators.json → {id → 卡数据}。
# 容错风格照抄 Scenes/Enemies/enemy_spawner.gd 的 load_types()(缺文件/坏 JSON → push_error 返回空)。

const DATA_PATH := "res://Globals/operators.json"

static var _operators: Dictionary = {}


static func load_all() -> Dictionary:
	if not _operators.is_empty():
		return _operators
	var txt := FileAccess.get_file_as_string(DATA_PATH)
	if txt.is_empty():
		push_error("OperatorRegistry: 读不到 " + DATA_PATH)
		return _operators
	var parsed: Variant = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY or not (parsed.get("operators", []) is Array):
		push_error("OperatorRegistry: operators.json 格式非法")
		return _operators
	for e in parsed["operators"]:
		if typeof(e) == TYPE_DICTIONARY and e.has("id"):
			_operators[str(e["id"])] = e
	return _operators


static func get_operator(id: String) -> Dictionary:
	if id.is_empty():
		return {}
	load_all()
	return _operators.get(id, {})


static func reset_cache() -> void:
	_operators = {}
