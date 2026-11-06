class_name PanelLogTail
extends RefCounted


const DEFAULT_MAX_CHARS := 64 * 1024

var offset := 0
var text := ""
var max_chars := DEFAULT_MAX_CHARS


func reset() -> void:
	offset = 0
	text = ""


func read_delta(abs_path: String) -> Dictionary:
	var out := {"new_text": "", "rebuild": false, "rotated": false}
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return out
	var total := f.get_length()
	if offset > total:
		offset = 0
		text = ""
		out["rotated"] = true
	if total <= offset:
		f.close()
		return out
	f.seek(offset)
	var chunk := f.get_buffer(total - offset)
	f.close()
	var nl := chunk.rfind(10)
	if nl < 0:
		return out
	var consumed := nl + 1
	offset += consumed
	var added := chunk.slice(0, consumed).get_string_from_utf8()
	text += added
	out["new_text"] = added
	if text.length() > max_chars:
		var over := text.length() - max_chars
		var cut_nl := text.find("\n", over)
		if cut_nl >= 0:
			over = cut_nl + 1
		text = text.substr(over)
		out["rebuild"] = true
	return out