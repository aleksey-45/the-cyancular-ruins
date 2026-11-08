class_name EditorLayers
extends RefCounted

# 镜像 level_editor/core/30_layers.js —— 单层编解码(纹理层 / 颜色层)。
# ★ 索引 0 恒为空气:即使本层一个空气格都没有也要占住第 0 位,于是"空图 = 调色板 [0] + 全 0 索引流"无条件成立。
# ★ 调色板上界判在 push 之前且必须用 >=:此刻 p 是加入前的 pal.size(),合法条件是 p ≤ 65534(加入后 ≤ 65535 = u16 上限)。
# ★ 失败一律返回 {ok:false, error}(文案照抄 JS 的 throw,中文原样);ByteReader 越界不算异常,每次读后判 r.failed。
# ★ 纹理层 desc / 颜色层 rgba 都是 PackedInt32Array:u32 值超过 int32 时会落成负数,这是有意的(写字节按位掩码仍正确)。

const KIND_TEX: int = 1
const KIND_COLOR: int = 2


static func encode_tex_layer(desc: PackedInt32Array, sub_cols: int, sub_rows: int) -> Dictionary:
	var n := sub_cols * sub_rows
	if desc.size() != n:
		return {"ok": false,
			"error": "encodeTexLayer: desc 长度 %d ≠ subCols×subRows %d" % [desc.size(), n]}
	# pal[0] 恒为空气;palette 顺序 = 描述符在索引流里**首次出现**的顺序。
	var pal := PackedInt32Array()
	pal.append(EditorDesc.DESC_AIR)
	var seen := {EditorDesc.DESC_AIR: 0}
	var idx := PackedInt32Array()
	idx.resize(n)
	for i in n:
		var d: int = desc[i] & 0xFFFFFFFF
		var p: int
		if seen.has(d):
			p = int(seen[d])
		else:
			p = pal.size()
			if p >= 65535:
				return {"ok": false, "error": "encodeTexLayer: 调色板超过 65535 项(u16 上限)"}
			pal.append(d)
			seen[d] = p
		idx[i] = p
	var iw := 1 if pal.size() <= 256 else 2
	var w := EditorBytes.Writer.new()
	w.u8(KIND_TEX)
	w.u16(pal.size())
	for k in pal.size():
		w.u32(pal[k])
	w.u8(iw)
	if iw == 1:
		for i in n:
			w.u8(idx[i])
	else:
		for i in n:
			w.u16(idx[i])
	return {"ok": true, "bytes": w.finish()}


static func decode_tex_layer(r: EditorBytes.Reader, sub_cols: int, sub_rows: int) -> Dictionary:
	var kind := r.u8()
	if r.failed:
		return {"ok": false, "error": r.error}
	if kind != KIND_TEX:
		return {"ok": false, "error": "decodeTexLayer: kind=%d,期望 %d" % [kind, KIND_TEX]}
	var pal_count := r.u16()
	if r.failed:
		return {"ok": false, "error": r.error}
	if pal_count == 0:
		return {"ok": false, "error": "decodeTexLayer: 调色板为空(索引 0 必须留给空气)"}
	var pal := PackedInt32Array()
	pal.resize(pal_count)
	for k in pal_count:
		pal[k] = r.u32()
		if r.failed:
			return {"ok": false, "error": r.error}
	var iw := r.u8()
	if r.failed:
		return {"ok": false, "error": r.error}
	if iw != 1 and iw != 2:
		return {"ok": false, "error": "decodeTexLayer: index_width=%d(只允许 1 或 2)" % iw}
	var n := sub_cols * sub_rows
	var desc := PackedInt32Array()
	desc.resize(n)
	for i in n:
		var p := r.u8() if iw == 1 else r.u16()
		if r.failed:
			return {"ok": false, "error": r.error}
		if p >= pal_count:
			return {"ok": false, "error": "decodeTexLayer: 索引 %d 越出调色板 %d 项" % [p, pal_count]}
		desc[i] = pal[p]
	return {"ok": true, "layer": {"kind": "tex", "desc": desc}}


# 背景层不做调色板:真彩,且平滑渐变恰好是 deflate 最擅长的一类数据。
static func encode_color_layer(rgba: PackedInt32Array, sub_cols: int, sub_rows: int) -> Dictionary:
	var n := sub_cols * sub_rows
	if rgba.size() != n:
		return {"ok": false,
			"error": "encodeColorLayer: rgba 长度 %d ≠ subCols×subRows %d" % [rgba.size(), n]}
	var w := EditorBytes.Writer.new()
	w.u8(KIND_COLOR)
	for i in n:
		w.u32(rgba[i])
	return {"ok": true, "bytes": w.finish()}


static func decode_color_layer(r: EditorBytes.Reader, sub_cols: int, sub_rows: int) -> Dictionary:
	var kind := r.u8()
	if r.failed:
		return {"ok": false, "error": r.error}
	if kind != KIND_COLOR:
		return {"ok": false, "error": "decodeColorLayer: kind=%d,期望 %d" % [kind, KIND_COLOR]}
	var n := sub_cols * sub_rows
	var rgba := PackedInt32Array()
	rgba.resize(n)
	for i in n:
		rgba[i] = r.u32()
		if r.failed:
			return {"ok": false, "error": r.error}
	return {"ok": true, "layer": {"kind": "color", "rgba": rgba}}
