class_name EditorCodec
extends RefCounted

# 镜像 level_editor/core/60_codec.js —— v4 容器:头 + body_size 闸 + 分层读写。
# ★ MAX_BODY_SIZE 是**解压后** body 的硬上限(堵 deflate 炸弹,压比 ≈1032:1),用在两道闸上、两道都不可省:
#   ① decode_map 的头部声明(判在任何解压动作之前);② EditorCompress.inflate_bytes 的输出上界。
# ★ 闸门顺序照 JS:头部声明 body_size ≤ 64MB → 尺寸合法 → 解压 → 实际输出 == 声明 → CRC(只覆盖 body)
#   → body 全消费 → 每层分配前用剩余字节粗筛。顺序不可挪(挪到解压之后等于没判)。
# ★ 头部 reserved 与 layer_flags 的 bit4-7 一律读掉不判(有意的前向兼容,写侧恒 0),别加校验。
# ★ 失败一律返回 {ok:false, error};文案照抄 JS 的 throw。

const FORMAT_VERSION: int = 4
const HEADER_SIZE: int = 20
const MAGIC := [0x43, 0x59, 0x52, 0x4D]   # "CYRM"
const MAX_BODY_SIZE: int = 64 * 1024 * 1024


# 层号 = layer_flags 位号(bit0-6);null 层不写块、由 flags 表达。
static func layer_flags(map: Dictionary) -> int:
	var f := 0
	var layers: Array = map.get("layers", [])
	for L in mini(layers.size(), EditorConstants.LAYER_COUNT):
		if layers[L] != null:
			f |= (1 << L)
	return f


static func encode_body(map: Dictionary) -> Dictionary:
	var meta_bytes := EditorMeta.build_meta(map).to_utf8_buffer()
	if meta_bytes.size() > 65535:
		return {"ok": false, "error": "encodeBody: meta 超过 65535 字节"}
	var sub_cols := int(map.get("sub_cols", 0))
	var sub_rows := int(map.get("sub_rows", 0))
	var w := EditorBytes.Writer.new()
	w.u16(meta_bytes.size())
	w.bytes(meta_bytes)
	var layers: Array = map.get("layers", [])
	for L in mini(layers.size(), EditorConstants.LAYER_COUNT):
		var layer = layers[L]
		if layer == null:
			continue                        # 缺层不写块,由 layer_flags 表达
		var ld: Dictionary = layer
		var block: Dictionary
		if String(ld.get("kind", "")) == "tex":
			block = EditorLayers.encode_tex_layer(
					ld.get("desc", PackedInt32Array()), sub_cols, sub_rows)
		else:
			block = EditorLayers.encode_color_layer(
					ld.get("rgba", PackedInt32Array()), sub_cols, sub_rows)
		if not bool(block.get("ok", false)):
			return block
		w.bytes(block["bytes"])
	return {"ok": true, "bytes": w.finish()}


static func decode_body(body: PackedByteArray, sub_cols: int, sub_rows: int, flags: int) -> Dictionary:
	var r := EditorBytes.Reader.new(body)
	var meta_len := r.u16()
	if r.failed:
		return {"ok": false, "error": r.error}
	var meta_bytes := r.bytes(meta_len)
	if r.failed:
		return {"ok": false, "error": r.error}
	# TextDecoder 语义:UTF-8 解出文本;解析失败的行由 parse_meta 降级成注释,不丢。
	var meta := EditorMeta.parse_meta(meta_bytes.get_string_from_utf8())
	var layers: Array = []
	var n := sub_cols * sub_rows
	for L in EditorConstants.LAYER_COUNT:
		if (flags & (1 << L)) == 0:
			layers.append(null)
			continue
		var kind: String = EditorConstants.LAYER_KINDS[L]
		# ★ 头部的 sub_cols / sub_rows 未经验证(CRC 只覆盖 body),一枚翻错的头字节就能让格数到 ≈43 亿
		#   ⇒ 用本层剩余字节数反推粗筛上界,且必须判在分配之前(不需精确,只需不可能通过)。
		var room := r.remaining()
		var max_cells := room if kind == "tex" else (room >> 2)
		if n > max_cells:
			return {"ok": false,
				"error": "decodeBody: 图层 %d(%s)需要 %d 个子格,但剩余 %d 字节最多只够 %d 个 —— "
						% [L, kind, n, room, max_cells]
						+ "头部尺寸 %d×%d 与 body 实际大小不符" % [sub_cols, sub_rows]}
		var res: Dictionary
		if kind == "tex":
			res = EditorLayers.decode_tex_layer(r, sub_cols, sub_rows)
		else:
			res = EditorLayers.decode_color_layer(r, sub_cols, sub_rows)
		if not bool(res.get("ok", false)):
			return res
		layers.append(res["layer"])
	if r.remaining() != 0:
		return {"ok": false, "error": "decodeBody: 尾部还有 %d 字节未消费" % r.remaining()}
	return {"ok": true, "map": {
		"name": "",
		"sub_cols": sub_cols,
		"sub_rows": sub_rows,
		"layers": layers,
		"players": meta["players"],
		"enemies": meta["enemies"],
		"respawns": meta["respawns"],
		"comments": meta["comments"],
	}}


# opts.compress 默认 true;传 false 走裸 body(compression=0)。
# ★ 导出前必须先跑 EditorValidate.validate_map:decode_map 在尺寸/图层长度上很严格,不校验就会产出坏文件;
#   只拒 errors、不拒 warnings(校验只报告不阻止导出)。
static func encode_map(map: Dictionary, opts: Dictionary = {}) -> Dictionary:
	var report := EditorValidate.validate_map(map)
	var errors: Array = report.get("errors", [])
	if not errors.is_empty():
		return {"ok": false, "error": "encodeMap: 地图校验未通过 —— " + ";".join(errors)}
	var body_res := encode_body(map)
	if not bool(body_res.get("ok", false)):
		return body_res
	var body: PackedByteArray = body_res["bytes"]
	var compress := true
	if opts.has("compress") and opts["compress"] == false:
		compress = false
	var payload: PackedByteArray
	var compression := 0
	if compress:
		var deflated := EditorCompress.deflate_bytes(body)
		if not bool(deflated.get("ok", false)):
			return deflated
		payload = deflated["bytes"]
		compression = 1
	else:
		payload = body
	var w := EditorBytes.Writer.new()
	w.u8(MAGIC[0])
	w.u8(MAGIC[1])
	w.u8(MAGIC[2])
	w.u8(MAGIC[3])
	w.u8(FORMAT_VERSION)
	w.u8(compression)
	w.u32(body.size())                  # ★ 解压后的大小
	w.u32(EditorBytes.crc32(body))          # CRC 只覆盖 body,不覆盖头部
	w.u16(int(map.get("sub_cols", 0)))
	w.u16(int(map.get("sub_rows", 0)))
	w.u8(layer_flags(map))
	w.u8(0)                             # reserved:写侧恒 0,读侧读掉不判
	w.bytes(payload)
	return {"ok": true, "bytes": w.finish()}


# decode_map 对外来文件的保证(不满足就拒,绝不静默返回一张残缺的图):头部与尺寸合法、解压闸门、
# body 长度精确、CRC 相符、body 全消费、索引与调色板边界、每层分配前的粗筛。
static func decode_map(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < HEADER_SIZE:
		return {"ok": false,
			"error": "decodeMap: 文件只有 %d 字节,小于头部 20 字节" % bytes.size()}
	var r := EditorBytes.Reader.new(bytes)
	if r.u8() != MAGIC[0] or r.u8() != MAGIC[1] or r.u8() != MAGIC[2] or r.u8() != MAGIC[3]:
		return {"ok": false, "error": "decodeMap: magic 不是 \"CYRM\""}
	var version := r.u8()
	if version != FORMAT_VERSION:
		return {"ok": false,
			"error": "decodeMap: 版本 %d,本编辑器只认 %d" % [version, FORMAT_VERSION]}
	var compression := r.u8()
	var body_size := r.u32()
	var expect_crc := r.u32()
	var sub_cols := r.u16()
	var sub_rows := r.u16()
	var flags := r.u8()
	r.u8()                              # reserved:读掉不判(有意前向兼容)
	if r.failed:
		return {"ok": false, "error": r.error}
	# ★ 先判头部声明的解压后大小、再碰 payload:解压是把攻击者给的字节变成内存的那一步,判在它后面等于没判。
	if body_size > MAX_BODY_SIZE:
		return {"ok": false,
			"error": "decodeMap: 头部声明的 body_size %d 字节超过 64MB 上限(%d 字节),拒绝解压"
					% [body_size, MAX_BODY_SIZE]}
	if sub_cols <= 0 or sub_rows <= 0:
		return {"ok": false, "error": "decodeMap: 尺寸非法 %d×%d" % [sub_cols, sub_rows]}
	if sub_cols % EditorConstants.SUB_PER_CELL != 0 or sub_rows % EditorConstants.SUB_PER_CELL != 0:
		return {"ok": false,
			"error": "decodeMap: 尺寸 %d×%d 不是 %d 的倍数"
					% [sub_cols, sub_rows, EditorConstants.SUB_PER_CELL]}
	var payload := r.bytes(bytes.size() - HEADER_SIZE)
	var body: PackedByteArray
	if compression == 0:
		body = payload
	elif compression == 1:
		# ★ body_size 是未经验证的声明 ⇒ 上界一并交给 inflate_bytes(作用在实际输出上),
		#   且传 body_size 而不是 MAX_BODY_SIZE:合法文件的解压结果恒等于它,是精确上界、不误拒。
		var inflated := EditorCompress.inflate_bytes(payload, body_size)
		if not bool(inflated.get("ok", false)):
			return inflated
		body = inflated["bytes"]
	else:
		return {"ok": false, "error": "decodeMap: 未知 compression=%d" % compression}
	if body.size() != body_size:
		return {"ok": false,
			"error": "decodeMap: 解压后 %d 字节,头部声明 %d" % [body.size(), body_size]}
	var actual := EditorBytes.crc32(body)
	if actual != expect_crc:
		return {"ok": false,
			"error": "decodeMap: CRC 不符(算得 0x%x,头部 0x%x)" % [actual, expect_crc]}
	return decode_body(body, sub_cols, sub_rows, flags)
