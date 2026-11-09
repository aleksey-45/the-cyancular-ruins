class_name EditorCompress
extends RefCounted

# 移植自已退役的浏览器编辑器 core/50_compress.js(2026-11-09 删除,历史见 git)—— zlib(deflate)进出,走引擎原生实现。
# ★ Godot COMPRESSION_DEFLATE = zlib RFC1950 = 浏览器 CompressionStream('deflate'),三种实现互通
#   (互操作已在仓内实测,见 core/sim/map_format_v4.gd 头注释)。
# ★ 输出上界必须作用在**实际输出**上:Godot decompress 的 buffer_size 就是它,等价 JS 的流式闸
#   (头里的 body_size 是攻击者可控的声明,见 docs/eng/editor-core.md §3)。
# ★ 失败一律返回 {ok:false, error};GDScript 没有异常,也不拿 push_error 当失败路径。

const COMPRESSION_MODE: int = FileAccess.COMPRESSION_DEFLATE


static func deflate_bytes(bytes: PackedByteArray) -> Dictionary:
	if bytes.is_empty():
		# Godot 的 compress() 拒绝空输入(JS 会产出合法空流)。encodeBody 的 body 恒 ≥ 2 字节,这条只防误用。
		return {"ok": false, "error": "deflateBytes: 空输入无法压缩(Godot compress 要求非空)"}
	var out := bytes.compress(COMPRESSION_MODE)
	if out.is_empty():
		return {"ok": false, "error": "deflateBytes: 压缩失败"}
	return {"ok": true, "bytes": out}


# max_bytes < 0 = 不设限(对应 JS maxBytes 缺省);唯一调用方 decode_map 恒传头部声明的 body_size。
static func inflate_bytes(bytes: PackedByteArray, max_bytes: int = -1) -> Dictionary:
	if bytes.is_empty():
		return {"ok": false, "error": "inflateBytes: 输入为空"}
	if max_bytes < 0:
		var dyn := bytes.decompress_dynamic(-1, COMPRESSION_MODE)
		if dyn.is_empty():
			return {"ok": false, "error": "inflateBytes: 解压失败"}
		return {"ok": true, "bytes": dyn}
	if max_bytes == 0:
		# Godot 的 decompress(0) 非法(buffer_size 必须 > 0);JS 语义下任何输出都超过 0 上限 ⇒ 直接拒。
		return {"ok": false, "error": "inflateBytes: 解压输出超过 0 字节上限,中止"}
	var out := bytes.decompress(max_bytes, COMPRESSION_MODE)
	# Godot 在"输出比 buffer_size 大"或"流本身损坏"两种情况下都返回空:错因合写成一句。
	if out.is_empty():
		return {"ok": false,
			"error": "inflateBytes: 解压失败或输出超过 %d 字节上限,中止" % max_bytes}
	if out.size() > max_bytes:
		return {"ok": false,
			"error": "inflateBytes: 解压输出超过 %d 字节上限(已累计 %d 字节),中止"
					% [max_bytes, out.size()]}
	return {"ok": true, "bytes": out}
