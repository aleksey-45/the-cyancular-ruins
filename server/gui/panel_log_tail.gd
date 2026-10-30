class_name PanelLogTail
extends RefCounted

# 服务端面板「日志 tail」的**纯逻辑**(2026-10-30 从 `server_panel.gd` 抽出;01 审查 S-13①)。
# 只做增量读与有界缓冲,不碰 UI/SceneTree ⇒ `-s` 可测。
#
# 口径(逐字沿用抽取前的实现,别改语义):
#   · **半行不消费**:只读到最后一条 `\n` 为止。UTF-8 多字节被截在中间会冒乱码行,所以写了一半的行
#     留到下一轮再读(`offset` 不前进)。
#   · **文件被轮转/重建**:`offset > 文件长度` 视为重建 ⇒ 归零重读,并回报 `rotated` 让调用方清屏。
#   · **超上限从头部截断**:上限按**字符**算(不是字节);截断点切在**行边界**上,否则首行是半截。
#     截断后 `text` 是整段重建过的内容,调用方要整体重画(`rebuild`)而不是追加。
#
# ★ 跟随/暂停(滚动位置)不在本类:那是 UI 语义,留在 `server_panel.gd` 的 `_refresh_log`(含 I1/I2 两条注释)。

const DEFAULT_MAX_CHARS := 64 * 1024   # ≈2000 行;与抽取前 `LOG_MAX_CHARS` 同值

var offset := 0        # 已消费到的字节位置
var text := ""         # 已消费的文本(受 max_chars 截断)
var max_chars := DEFAULT_MAX_CHARS


func reset() -> void:
	offset = 0
	text = ""


# 增量读一次。返回 `{new_text, rebuild, rotated}`:
#   new_text  本轮新增的完整行文本(可能为空)
#   rebuild   因超上限发生过头部截断 ⇒ 调用方应把整段设为 `text`
#   rotated   文件比 offset 短(轮转/重建)⇒ 调用方应先清屏;本轮新内容已含在 new_text
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