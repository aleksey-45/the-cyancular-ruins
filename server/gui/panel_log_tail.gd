class_name PanelLogTail
extends RefCounted

# 服务端面板「日志 tail」的**纯逻辑**(2026-10-30 从 `server_panel.gd` 抽出;01 审查 S-13①)。

const DEFAULT_MAX_CHARS := 64 * 1024   # ≈2000 行;与抽取前 `LOG_MAX_CHARS` 同值

var offset := 0        # 已消费到的字节位置
var text := ""         # 已消费的文本(受 max_chars 截断)
var max_chars := DEFAULT_MAX_CHARS


func reset() -> void:
	offset = 0
	text = ""


# 增量读一次。返回 `{new_text, rebuild, rotated}`:
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
	var nl := chunk.rfind(10)   # '\n'
	if nl < 0:
		return out              # 还没有完整的一行(半行留给下一轮)
	var consumed := nl + 1
	offset += consumed
	var added := chunk.slice(0, consumed).get_string_from_utf8()
	text += added
	out["new_text"] = added
	if text.length() > max_chars:
		# 从头部截断,并切在行边界上;不动跟随状态(那是调用方的事)。
		var over := text.length() - max_chars
		var cut_nl := text.find("\n", over)
		if cut_nl >= 0:
			over = cut_nl + 1
		text = text.substr(over)
		out["rebuild"] = true
	return out