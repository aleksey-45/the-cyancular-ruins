class_name EditorStore
extends RefCounted

# 素材编辑器存储层:cards/<type>s/<id>.json 的列表/读写/删除(与旧版卡格式兼容)。

const ROOT := "res://DevTools/cards"


static func dir_of(type: String) -> String:
	return "%s/%s" % [ROOT, EditorSchema.folder_of(type)]


static func card_path(type: String, id: String) -> String:
	return "%s/%s.json" % [dir_of(type), id]


static func list_ids(type: String) -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open(dir_of(type))
	if dir == null:
		return out
	for f in dir.get_files():
		if str(f).ends_with(".json"):
			out.append(str(f).trim_suffix(".json"))
	out.sort()
	return out


static func load_card(type: String, id: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(card_path(type, id))
	if text.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return EditorSchema.apply_defaults(parsed)


static func save_card(card: Dictionary) -> String:
	var type := str(card.get("card_type", ""))
	var id := str(card.get("id", ""))
	var errs := EditorSchema.validate(card)
	if not errs.is_empty():
		return "保存被拒:" + ";".join(errs)
	card["updated_at"] = Time.get_datetime_string_from_system()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir_of(type)))
	var f := FileAccess.open(card_path(type, id), FileAccess.WRITE)
	if f == null:
		return "写不进去:%s" % card_path(type, id)
	f.store_string(JSON.stringify(card, "\t"))
	f.close()
	return ""


static func delete_card(type: String, id: String) -> void:
	var dir := DirAccess.open(dir_of(type))
	if dir != null and dir.file_exists(id + ".json"):
		dir.remove(id + ".json")
	# 连带清理美术槽文件(卡没了,槽也不留)
	for s in EditorSchema.art_slots(type, id):
		var p: String = ProjectSettings.globalize_path("res://DevTools/cards/" + str(s["file"]))
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
		if FileAccess.file_exists(p + ".meta"):
			DirAccess.remove_absolute(p + ".meta")
