class_name MapEditFiles
extends RefCounted

static func save_draft(path: String, map: Dictionary, source_path: String) -> Error:
	return CyrmMap.save_file(map.merged({"path": source_path}), path)

static func read_draft(path: String) -> Dictionary:
	var map := CyrmMap.load_file(path)
	if map.is_empty(): return {}
	var source: String = map.path
	map.erase("path")
	return {"path": source, "map": map}

static func clear_draft(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
