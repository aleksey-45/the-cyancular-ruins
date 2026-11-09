extends SceneTree

# 编辑器 v4 容器 / 分层 / 压缩移植守卫(`-s`,headless,不实例化 autoload)。
# 守护 core/editor/{editor_layers,editor_compress,editor_codec}.gd 对
# 已退役的浏览器编辑器 core/{30_layers,50_compress,60_codec}.js 的忠实移植(历史见 git)。
#
# 去掉什么会红:
#   ① 无压缩整文件往返(encode→decode→再 encode)字节不等;或 palette 不再按"首次出现顺序"、空气不在 [0] 位 ⇒ 红。
#   ② decode 出的图字面量(7 层 kind/长度/内容、players/enemies/respawns/comments)错位 ⇒ 红。
#   ③ 默认压缩不再产 zlib(第 6 字节 compression != 1)、压缩往返结构不等、或 body_size 不是解压后大小 ⇒ 红。
#   ④ 稀疏 layer_flags 不再按位补 null / 头部 flags 位写错 ⇒ 红。
#   ⑤ 调色板 > 256 时不切 index_width=2、或双字节索引串位 ⇒ 红。
#   ⑥ 调色板上界差一格(65536 项调色板被静默写出 / 恰好 65535 项被误拒)⇒ 红。
#   ⑦ 坏 magic / 短文件 / CRC / 未知 compression / body_size 超 64MB / body 尾部多余 / 层块截断
#      被静默接受(或 error 不指出原因)⇒ 红。
#   ⑧ encode_map 不再先跑 EditorValidate.validate_map(非法纹理 id 被写出去)⇒ 红。
# ★ 期望值来自本文件自己构造的输入与手推字节,不复用被测函数的返回值;不"拿实现验实现"。

const EXPECTED_CHECKS := 56

# tile_defs 里真实存在的 15 个纹理 id(encode_map 会跑 validate_map:非法纹理 id 是 error)。
const VALID_TEX_IDS := [1, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 19, 20, 21, 22]

var _fails: Array[String] = []
var _checks := 0


func _chk(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_fails.append(msg)


func _ok_or(res: Dictionary, label: String) -> bool:
	var ok := bool(res.get("ok", false))
	_chk(ok, "%s 应成功(实得 error=%s)" % [label, String(res.get("error", ""))])
	return ok


func _fail_or(res: Dictionary, label: String, keyword: String) -> void:
	if bool(res.get("ok", false)):
		_chk(false, "%s 应 ok:false,实得 ok:true" % label)
		return
	var err := String(res.get("error", ""))
	_chk(err.contains(keyword),
			"%s: ok:false 但 error 缺关键字「%s」(实得「%s」)" % [label, keyword, err])


func _initialize() -> void:
	# ★ 空载守卫(仓规):load() 失败还往下走会在 null 上抛错,而 `-s` 抛错走不到 quit() ⇒ 进程永久挂起。
	for p in [
		"res://core/editor/editor_layers.gd",
		"res://core/editor/editor_compress.gd",
		"res://core/editor/editor_codec.gd",
		"res://core/editor/editor_bytes.gd",
		"res://core/editor/editor_desc.gd",
		"res://core/editor/editor_meta.gd",
		"res://core/editor/editor_validate.gd",
	]:
		if load(p) == null:
			print("EDITOR CODEC SMOKE FAILED: load(%s) 为 null(-s 空载守卫:不 quit 会挂死)" % p)
			quit(1)
			return

	var src := _make_full_map()
	var expected := _expected_decoded(src)

	# ══ ① 无压缩整文件往返:encode → decode → 再 encode,字节必须相等 ══
	var e1 := EditorCodec.encode_map(src, {"compress": false})
	_ok_or(e1, "① encode_map(compress:false)")
	var plain: PackedByteArray = e1.get("bytes", PackedByteArray())
	_chk(_slice(plain, 0, 4) == "CYRM".to_ascii_buffer(),
			"① 文件头 4 字节应 = \"CYRM\"(实得 %s)" % [_slice(plain, 0, 4)])
	_chk(_u8_at(plain, 4) == 4, "① 第 5 字节应 = 版本 4(实得 %d)" % _u8_at(plain, 4))
	_chk(_u8_at(plain, 5) == 0, "① compress:false 时第 6 字节应 = 0(实得 %d)" % _u8_at(plain, 5))
	_chk(_u16_at(plain, 14) == 20 and _u16_at(plain, 16) == 16,
			"① 头部 sub_cols/sub_rows 应 = 20/16(实得 %d/%d)" % [_u16_at(plain, 14), _u16_at(plain, 16)])
	_chk(_u8_at(plain, 18) == 0x7F and _u8_at(plain, 19) == 0,
			"① 7 层全在时 layer_flags 应 = 0x7F、reserved 应 = 0(实得 0x%X/0x%X)"
					% [_u8_at(plain, 18), _u8_at(plain, 19)])
	_chk(_u32_at(plain, 6) == plain.size() - 20,
			"① 头部 body_size 应 = 文件余量 %d(实得 %d)" % [plain.size() - 20, _u32_at(plain, 6)])

	var dec := EditorCodec.decode_map(plain)
	_ok_or(dec, "① decode_map(裸 body)")
	var got: Dictionary = dec.get("map", {})
	_chk(int(got.get("sub_cols", -1)) == 20 and int(got.get("sub_rows", -1)) == 16,
			"① decode 尺寸应 = 20×16(实得 %s×%s)"
					% [got.get("sub_cols", -1), got.get("sub_rows", -1)])
	var layers: Array = got.get("layers", [])
	_chk(layers.size() == 7, "① decode 后 layers 应恒 7 项(实得 %d)" % layers.size())

	var tex_kinds_ok := layers.size() == 7
	for L in [0, 1, 2]:
		if tex_kinds_ok:
			var ld = layers[L]
			if ld == null or String((ld as Dictionary).get("kind", "")) != "tex" \
					or ((ld as Dictionary).get("desc", PackedInt32Array()) as PackedInt32Array).size() != 320:
				tex_kinds_ok = false
	_chk(tex_kinds_ok, "① 层 0-2 应是 320 长的 tex 层(实得 %s)" % _layers_brief(layers))
	var color_kinds_ok := layers.size() == 7
	for L in [3, 4, 5, 6]:
		if color_kinds_ok:
			var ld = layers[L]
			if ld == null or String((ld as Dictionary).get("kind", "")) != "color" \
					or ((ld as Dictionary).get("rgba", PackedInt32Array()) as PackedInt32Array).size() != 320:
				color_kinds_ok = false
	_chk(color_kinds_ok, "① 层 3-6 应是 320 长的 color 层(实得 %s)" % _layers_brief(layers))

	var tex_ok := layers.size() == 7
	for L in [0, 1, 2]:
		if tex_ok:
			var sld: Dictionary = src["layers"][L]
			var gld = layers[L]
			if gld == null or (gld as Dictionary)["desc"] != sld["desc"]:
				tex_ok = false
	_chk(tex_ok, "① 层 0-2 纹理内容应逐格往返一致")
	var color_ok := layers.size() == 7
	for L in [3, 4, 5, 6]:
		if color_ok:
			var sld: Dictionary = src["layers"][L]
			var gld = layers[L]
			if gld == null or (gld as Dictionary)["rgba"] != sld["rgba"]:
				color_ok = false
	_chk(color_ok, "① 层 3-6 颜色内容应逐格往返一致(含 >int32 的 u32 落成负数)")

	_chk(_points_equal(got.get("players", []), expected["players"]),
			"① players 应逐项一致(实得 %s)" % [got.get("players")])
	_chk(_points_equal(got.get("enemies", []), expected["enemies"]),
			"① enemies 应逐项一致(实得 %s)" % [got.get("enemies")])
	_chk(_points_equal(got.get("respawns", []), expected["respawns"]),
			"① respawns 应按侧分组回读(期望 %s,实得 %s)"
					% [expected["respawns"], got.get("respawns")])
	_chk(_strings_equal(got.get("comments", []), expected["comments"]),
			"① comments 应逐项一致(实得 %s)" % [got.get("comments")])

	var e2 := EditorCodec.encode_map(got, {"compress": false})
	_ok_or(e2, "① decode 后再 encode_map(compress:false)")
	var plain2: PackedByteArray = e2.get("bytes", PackedByteArray())
	_chk(plain2.size() > 0 and plain2 == plain,
			"① 无压缩往返字节应完全相等(首份 %d 字节 / 再编 %d 字节)" % [plain.size(), plain2.size()])

	# ══ 调色板顺序 = 描述符在索引流里首次出现的顺序;索引 0 恒为空气 ══
	var d1 := EditorDesc.neutral_desc(1)
	var d2 := EditorDesc.pack_desc(6, 5, 3, 6, 7)
	var d3 := EditorDesc.pack_desc(7, 2, 4, 4, 7)
	var seq := PackedInt32Array([0, d1, d2, 0, d1, d3, d2, d1])
	var enc_seq := EditorLayers.encode_tex_layer(seq, 4, 2)
	var seq_bytes: PackedByteArray = enc_seq.get("bytes", PackedByteArray())
	var br := EditorBytes.Reader.new(seq_bytes)
	var b_kind := br.u8()
	var b_pc := br.u16()
	var b_pal := PackedInt32Array()
	if b_pc > 0 and b_pc <= 16:
		b_pal.resize(b_pc)
		for k in b_pc:
			b_pal[k] = br.u32()
	_chk(b_kind == EditorLayers.KIND_TEX and b_pc == 4 and seq_bytes.size() == 28,
			"调色板顺序: kind=%d, palette_count=%d, 长度=%d(期望 1 / 4 / 28)"
					% [b_kind, b_pc, seq_bytes.size()])
	_chk(b_pal.size() == 4 and b_pal[0] == EditorDesc.DESC_AIR and b_pal[1] == d1 \
			and b_pal[2] == d2 and b_pal[3] == d3,
			"调色板顺序: 应 = [空气, 首次出现的 d1, d2, d3](实得 %s)" % [b_pal])
	var b_iw := br.u8()
	var b_idx := PackedInt32Array()
	b_idx.resize(8)
	for i in 8:
		b_idx[i] = br.u8()
	_chk(b_iw == 1 and b_idx == PackedInt32Array([0, 1, 2, 0, 1, 3, 2, 1]),
			"调色板顺序: index_width=%d, 索引流=%s(期望 1 / [0,1,2,0,1,3,2,1])" % [b_iw, b_idx])

	# ══ ③ 默认压缩往返:compression 字节 = 1,zlib 体解回同一张图 ══
	var enc_c := EditorCodec.encode_map(src)
	_ok_or(enc_c, "③ encode_map(默认压缩)")
	var comp_bytes: PackedByteArray = enc_c.get("bytes", PackedByteArray())
	_chk(_u8_at(comp_bytes, 5) == 1,
			"③ 默认压缩时第 6 字节 compression 应 = 1(实得 %d)" % _u8_at(comp_bytes, 5))
	var dec_c := EditorCodec.decode_map(comp_bytes)
	_ok_or(dec_c, "③ decode_map(压缩 body)")
	var got_c: Dictionary = dec_c.get("map", {})
	var diff_c := _maps_equal(got_c, expected)
	_chk(diff_c == "", "③ 压缩往返结构应等于原图(实得:%s)" % diff_c)
	_chk(_u32_at(comp_bytes, 6) == plain.size() - 20,
			"③ 压缩文件头 body_size 应 = 解压后 body 长度 %d(实得 %d)"
					% [plain.size() - 20, _u32_at(comp_bytes, 6)])

	# ══ ④ 稀疏 layer_flags:只留场景层(层 1),其余 6 层 null ══
	var sparse := _make_sparse_map()
	var enc_s := EditorCodec.encode_map(sparse, {"compress": false})
	_ok_or(enc_s, "④ 稀疏 layer_flags encode")
	var s_bytes: PackedByteArray = enc_s.get("bytes", PackedByteArray())
	_chk(_u8_at(s_bytes, 18) == 0b10,
			"④ 只有场景层时 layer_flags 应 = 0b10(实得 0x%X)" % _u8_at(s_bytes, 18))
	var dec_s := EditorCodec.decode_map(s_bytes)
	_ok_or(dec_s, "④ 稀疏 layer_flags decode")
	var got_s: Dictionary = dec_s.get("map", {})
	var s_layers: Array = got_s.get("layers", [])
	var null_ok := s_layers.size() == 7
	if null_ok:
		for L in 7:
			if L == 1:
				null_ok = s_layers[L] != null
			else:
				null_ok = null_ok and s_layers[L] == null
	_chk(null_ok, "④ 解码后应只有层 1 非 null,其余 6 层为 null(实得 %s)" % _layers_brief(s_layers))
	_chk(s_layers.size() == 7 and s_layers[1] != null \
			and (s_layers[1] as Dictionary)["desc"] == (sparse["layers"][1] as Dictionary)["desc"],
			"④ 稀疏图的场景层内容应往返一致")
	var enc_s2 := EditorCodec.encode_map(got_s, {"compress": false})
	var s_bytes2: PackedByteArray = enc_s2.get("bytes", PackedByteArray())
	_chk(s_bytes2.size() > 0 and s_bytes2 == s_bytes,
			"④ 稀疏图再编码字节应相等(%d vs %d)" % [s_bytes.size(), s_bytes2.size()])

	# ══ ⑤ 调色板 > 256 项 ⇒ index_width = 2,双字节索引往返一致 ══
	var pm := _make_palette_map()
	var uniq := {}
	for i in 300:
		uniq[_distinct_valid_desc(i)] = true
	_chk(uniq.size() == 300,
			"⑤ 构造前提:300 个描述符应两两不同(实得 %d 种;否则调色板缩回 ≤256、双字节分支根本没跑)"
					% uniq.size())
	var enc_p := EditorCodec.encode_map(pm, {"compress": false})
	_ok_or(enc_p, "⑤ 调色板 >256 encode")
	var p_bytes: PackedByteArray = enc_p.get("bytes", PackedByteArray())
	# 无 meta(meta_len = 0)⇒ 层 0 块固定从 20+2 开始:kind(1) + pal_count(2) + 4×301 + iw(1) + 2×320。
	_chk(_u16_at(p_bytes, 23) == 301 and p_bytes.size() == 1870,
			"⑤ 层 0 调色板应 301 项、文件应 1870 字节(实得 %d / %d)"
					% [_u16_at(p_bytes, 23), p_bytes.size()])
	_chk(_u8_at(p_bytes, 1229) == 2,
			"⑤ 调色板 >256 时 index_width 应 = 2(实得 %d)" % _u8_at(p_bytes, 1229))
	var dec_p := EditorCodec.decode_map(p_bytes)
	_ok_or(dec_p, "⑤ 调色板 >256 decode")
	var got_p: Dictionary = dec_p.get("map", {})
	var p_layers: Array = got_p.get("layers", [])
	var p_front_ok: bool = p_layers.size() == 7 and p_layers[0] != null \
			and (p_layers[0] as Dictionary)["desc"] == (pm["layers"][0] as Dictionary)["desc"]
	_chk(p_front_ok, "⑤ 双字节索引往返应逐格一致")
	var spot: bool = p_layers.size() == 7 and p_layers[0] != null
	if spot:
		var pd: PackedInt32Array = (p_layers[0] as Dictionary)["desc"]
		for i in 300:
			if pd[i] != _distinct_valid_desc(i):
				spot = false
				break
		for i in range(300, 320):
			if spot and pd[i] != 0:
				spot = false
	_chk(spot, "⑤ 300 种描述符应各自按位置回读正确、末 20 格是空气")
	var enc_p2 := EditorCodec.encode_map(got_p, {"compress": false})
	var p_bytes2: PackedByteArray = enc_p2.get("bytes", PackedByteArray())
	_chk(p_bytes2.size() > 0 and p_bytes2 == p_bytes,
			"⑤ 双字节索引再编码字节应相等(%d vs %d)" % [p_bytes.size(), p_bytes2.size()])

	# ══ ⑥ 调色板上界:65536 项必须拒(错因点名 65535);恰好 65535 项必须可以 ══
	# ★ 两档都要:65535 个非空气描述符 ⇒ 调色板**将要**变成 65536 项,但正好没有第 65536 个描述符
	#   去触发下一条循环 ⇒ 只有"判在 push 之前且用 >= "能拒;写成 p > 65535 时它会静默写出 u16 截断成 0 的文件。
	var desc_bad := PackedInt32Array()
	desc_bad.resize(65535)
	for i in 65535:
		desc_bad[i] = _distinct_desc(i)
	_fail_or(EditorLayers.encode_tex_layer(desc_bad, 3, 21845),
			"⑥ 65535 个不同描述符(调色板将达 65536 项)", "65535")

	var desc_bad2 := PackedInt32Array()
	desc_bad2.resize(65536)
	for i in 65536:
		desc_bad2[i] = _distinct_desc(i)
	_fail_or(EditorLayers.encode_tex_layer(desc_bad2, 256, 256),
			"⑥ 65536 个不同描述符", "65535")

	var desc_ok := PackedInt32Array()
	desc_ok.resize(65534)
	for i in 65534:
		desc_ok[i] = _distinct_desc(i)
	var enc_ok := EditorLayers.encode_tex_layer(desc_ok, 2, 32767)
	_ok_or(enc_ok, "⑥ 恰好 65535 项调色板(65534 个不同描述符)应可编码")
	var ok_bytes: PackedByteArray = enc_ok.get("bytes", PackedByteArray())
	_chk(_u16_at(ok_bytes, 1) == 65535 and ok_bytes.size() == 393212,
			"⑥ 上界样本 palette_count 应 = 65535(未被 u16 截断成 0)、长度应 = 393212(实得 %d / %d)"
					% [_u16_at(ok_bytes, 1), ok_bytes.size()])
	var r_ok := EditorBytes.Reader.new(ok_bytes)
	var l_ok := EditorLayers.decode_tex_layer(r_ok, 2, 32767)
	var l_desc: PackedInt32Array = (l_ok.get("layer", {}) as Dictionary).get("desc", PackedInt32Array())
	_chk(bool(l_ok.get("ok", false)) and l_desc.size() == 65534 and l_desc == desc_ok \
			and r_ok.remaining() == 0,
			"⑥ 上界样本应能解回 65534 个逐格相同的描述符")

	# ══ ⑦ 坏输入逐类:必须 ok:false 且 error 指出原因(不能只判 ok:false)══
	var bad_magic: PackedByteArray = plain.duplicate()
	if bad_magic.size() > 0:
		bad_magic[0] = 0x00
	_fail_or(EditorCodec.decode_map(bad_magic), "⑦ 坏 magic", "magic")

	var short_file := PackedByteArray()
	short_file.resize(10)
	_fail_or(EditorCodec.decode_map(short_file), "⑦ 文件 < 20 字节", "小于头部")

	var bad_crc: PackedByteArray = plain.duplicate()
	if bad_crc.size() > 0:
		bad_crc[bad_crc.size() - 1] = bad_crc[bad_crc.size() - 1] ^ 0xFF
	_fail_or(EditorCodec.decode_map(bad_crc), "⑦ CRC 不符", "CRC 不符")

	var bad_comp: PackedByteArray = plain.duplicate()
	if bad_comp.size() >= 6:
		bad_comp[5] = 7
	_fail_or(EditorCodec.decode_map(bad_comp), "⑦ 未知 compression", "未知 compression")

	var bad_size: PackedByteArray = plain.duplicate()
	if bad_size.size() >= 10:
		bad_size.encode_u32(6, 0x7FFFFFFF)
	_fail_or(EditorCodec.decode_map(bad_size), "⑦ body_size 超 64MB", "64MB")

	var tail_body: PackedByteArray = _slice_from(plain, 20).duplicate()
	tail_body.append(0x5A)
	var tail_file := _craft_file_like(plain, tail_body)
	_fail_or(EditorCodec.decode_map(tail_file), "⑦ body 尾部多余字节", "尾部")

	var trunc_body: PackedByteArray = _slice_from(plain, 20).duplicate()
	if trunc_body.size() > 0:
		trunc_body = trunc_body.slice(0, trunc_body.size() - 1)
	var trunc_file := _craft_file_like(plain, trunc_body)
	_fail_or(EditorCodec.decode_map(trunc_file), "⑦ 层块截断", "越界读")

	# ══ ⑧ encode_map 必须先跑 validate_map:非法纹理 id(legacy id 2)不得被写出去 ══
	var known := EditorValidate._known_textures()
	_chk(known.size() >= 15,
			"⑧ 前提:data/tile_defs.json 键集应已加载(实得 %d 个;加载不到时纹理闸会静默跳过)" % known.size())
	var bad_map := _make_full_map()
	var bad_desc: PackedInt32Array = (bad_map["layers"][0] as Dictionary)["desc"]
	bad_desc[0] = EditorDesc.neutral_desc(2)
	(bad_map["layers"][0] as Dictionary)["desc"] = bad_desc
	var bad_res := EditorCodec.encode_map(bad_map, {"compress": false})
	if bool(bad_res.get("ok", false)):
		_chk(false, "⑧ 非法纹理 id 应被 encode_map 的 validate_map 闸拒绝,实得 ok:true")
	else:
		var berr := String(bad_res.get("error", ""))
		_chk(berr.contains("校验未通过") and berr.contains("tile_defs"),
				"⑧ 非法纹理 id 的 error 应点名「校验未通过」+「tile_defs」(实得「%s」)" % berr)

	# ══ 判词闸 ══
	if _checks < EXPECTED_CHECKS:
		print("EDITOR CODEC SMOKE FAILED: 只跑了 %d 条 < %d(脚本中途中止)" % [_checks, EXPECTED_CHECKS])
		quit(1)
		return
	if not _fails.is_empty():
		print("EDITOR CODEC SMOKE FAILED (%d/%d):" % [_fails.size(), EXPECTED_CHECKS])
		for f in _fails:
			print("  - " + f)
		quit(1)
		return
	print(("EDITOR CODEC SMOKE: OK(%d 条断言):无压缩往返字节相等 · 字面量 · 压缩往返 · 稀疏层 · "
			+ "双字节索引 · 65535 调色板上界 · 七类坏输入 · 校验闸") % _checks)
	quit(0)


# ── 样本图:5×4 格 = 20×16 = 320 子格;7 层全在(3 纹理 + 4 颜色),meta 含注释/2 出生点/两侧复活点/敌人 ──
func _make_full_map() -> Dictionary:
	var sub_cols := 20
	var sub_rows := 16
	var n := sub_cols * sub_rows
	var front := _zero(n)                 # 层 0 前景:稀疏装饰(tex 1)
	for i in range(0, n, 7):
		front[i] = EditorDesc.neutral_desc(1)
	var scene := _zero(n)                 # 层 1 场景:左边 4 列一堵墙(tex 6)
	var brick := EditorDesc.neutral_desc(6)
	for i in n:
		if i % sub_cols < 4:
			scene[i] = brick
	var back := _zero(n)                  # 层 2 后景:零星(tex 7,带非中性辅码)
	var moss := EditorDesc.pack_desc(7, 5, 3, 6, 7)
	for i in range(0, n, 13):
		back[i] = moss
	var bg3 := _zero(n)                   # 层 3 背景 100%
	for i in n:
		bg3[i] = ((0x102030 | (i & 0xFF)) * 0x010101) & 0xFFFFFFFF
	var bg4 := _zero(n)                   # 层 4 背景 75%
	for i in n:
		bg4[i] = (0x804020 * 0x010101 + i * 0x010203) & 0xFFFFFFFF
	var bg5 := _zero(n)                   # 层 5 背景 50%:刻意含 > int32 的 u32(写进 PackedInt32Array 会变负)
	for i in n:
		bg5[i] = (0xFF000000 + i) & 0xFFFFFFFF
	var bg6 := _zero(n)                   # 层 6 背景 25%:从 u32 上界往下减
	for i in n:
		bg6[i] = (0xFFFFFFFF - i * 3) & 0xFFFFFFFF
	return {
		"name": "syn",
		"sub_cols": sub_cols,
		"sub_rows": sub_rows,
		"layers": [
			{"kind": "tex", "desc": front},
			{"kind": "tex", "desc": scene},
			{"kind": "tex", "desc": back},
			{"kind": "color", "rgba": bg3},
			{"kind": "color", "rgba": bg4},
			{"kind": "color", "rgba": bg5},
			{"kind": "color", "rgba": bg6},
		],
		"players": [{"x": 1, "y": 1}, {"x": 3, "y": 3}],
		"enemies": [{"type": "fly_bird", "x": 2, "y": 0}],
		# 输入顺序 = 侧 2 在前;build_meta 按侧分组回写(侧 1 全在前),故解码后的期望顺序是分组后的。
		"respawns": [{"side": 2, "x": 4, "y": 1}, {"side": 1, "x": 1, "y": 2}],
		"comments": ["demo", "带中文的注释"],
	}


func _make_sparse_map() -> Dictionary:
	var sub_cols := 20
	var sub_rows := 16
	var n := sub_cols * sub_rows
	var scene := _zero(n)
	for i in n:
		if i % sub_cols < 4:
			scene[i] = EditorDesc.neutral_desc(6)
	var layers: Array = []
	for L in 7:
		layers.append({"kind": "tex", "desc": scene} if L == 1 else null)
	return {
		"name": "sparse",
		"sub_cols": sub_cols,
		"sub_rows": sub_rows,
		"layers": layers,
		"players": [{"x": 1, "y": 1}],
		"enemies": [],
		"respawns": [],
		"comments": [],
	}


func _make_palette_map() -> Dictionary:
	var sub_cols := 20
	var sub_rows := 16
	var n := sub_cols * sub_rows
	var front := _zero(n)
	for i in 300:
		front[i] = _distinct_valid_desc(i)
	var layers: Array = []
	for L in 7:
		layers.append({"kind": "tex", "desc": front} if L == 0 else null)
	return {
		"name": "pal",
		"sub_cols": sub_cols,
		"sub_rows": sub_rows,
		"layers": layers,
		"players": [],
		"enemies": [],
		"respawns": [],
		"comments": [],
	}


# 只用 tile_defs 里真实存在的 15 个纹理 id(encode_map 会跑 validate_map),靠 (hue, bright, sat) 分块凑不同。
# ⑤ 里自证前 300 个两两不同。
func _distinct_valid_desc(i: int) -> int:
	var block := int(i / 15.0)
	return EditorDesc.pack_desc(VALID_TEX_IDS[i % 15], block & 7, (block >> 3) & 7, (block >> 6) & 7, 7)


# 直接喂 EditorLayers.encode_tex_layer 用(不跑 validate_map):纹理 1..4095 循环 + (hue, bright) 分块,
# 4095×17 > 65536 ⇒ 能构造出 65536 个两两不同的描述符。
func _distinct_desc(i: int) -> int:
	var block := int(i / 4095.0)
	return EditorDesc.pack_desc(1 + (i % 4095), block & 7, (block >> 3) & 7, (block >> 6) & 7, 7)


func _expected_decoded(src: Dictionary) -> Dictionary:
	return {
		"sub_cols": int(src["sub_cols"]),
		"sub_rows": int(src["sub_rows"]),
		"layers": src["layers"],
		"players": src["players"],
		"enemies": src["enemies"],
		"respawns": _grouped_respawns(src["respawns"]),
		"comments": src["comments"],
	}


func _grouped_respawns(rs: Array) -> Array:
	var out: Array = []
	for side in [1, 2]:
		for r in rs:
			if int(r["side"]) == side:
				out.append(r)
	return out


func _maps_equal(got: Dictionary, want: Dictionary) -> String:
	if got.is_empty():
		return "解码失败,got 为空"
	if int(got.get("sub_cols", -1)) != int(want.get("sub_cols", -2)) \
			or int(got.get("sub_rows", -1)) != int(want.get("sub_rows", -2)):
		return "尺寸 %s×%s ≠ %s×%s" % [got.get("sub_cols"), got.get("sub_rows"),
				want.get("sub_cols"), want.get("sub_rows")]
	var ga: Array = got.get("layers", [])
	var wa: Array = want.get("layers", [])
	if ga.size() != wa.size():
		return "层数 %d ≠ %d" % [ga.size(), wa.size()]
	for L in wa.size():
		var g = ga[L]
		var w = wa[L]
		if g == null or w == null:
			if not (g == null and w == null):
				return "层 %d 的 null 形态不同(实得 %s)" % [L, "null" if g == null else "有值"]
			continue
		var gd: Dictionary = g
		var wd: Dictionary = w
		if String(gd.get("kind", "")) != String(wd.get("kind", "")):
			return "层 %d kind %s ≠ %s" % [L, gd.get("kind"), wd.get("kind")]
		var key := "desc" if String(wd.get("kind", "")) == "tex" else "rgba"
		var garr: PackedInt32Array = gd.get(key, PackedInt32Array())
		var warr: PackedInt32Array = wd.get(key, PackedInt32Array())
		if garr.size() != warr.size():
			return "层 %d 长度 %d ≠ %d" % [L, garr.size(), warr.size()]
		if garr != warr:
			for i in garr.size():
				if garr[i] != warr[i]:
					return "层 %d[%d] %d ≠ %d" % [L, i, garr[i], warr[i]]
			return "层 %d 内容不同" % L
	if not _points_equal(got.get("players", []), want.get("players", [])):
		return "players %s ≠ %s" % [got.get("players"), want.get("players")]
	if not _points_equal(got.get("enemies", []), want.get("enemies", [])):
		return "enemies %s ≠ %s" % [got.get("enemies"), want.get("enemies")]
	if not _points_equal(got.get("respawns", []), want.get("respawns", [])):
		return "respawns %s ≠ %s" % [got.get("respawns"), want.get("respawns")]
	if not _strings_equal(got.get("comments", []), want.get("comments", [])):
		return "comments %s ≠ %s" % [got.get("comments"), want.get("comments")]
	return ""


func _points_equal(got: Array, want: Array) -> bool:
	if got.size() != want.size():
		return false
	for i in want.size():
		var g: Dictionary = got[i]
		var w: Dictionary = want[i]
		for k in w:
			if g.get(k) != w[k]:
				return false
	return true


func _strings_equal(got: Array, want: Array) -> bool:
	if got.size() != want.size():
		return false
	for i in want.size():
		if String(got[i]) != String(want[i]):
			return false
	return true


# 用 base 的 20 字节头 + 指定的裸 body 重造一份文件(body_size / CRC 按新 body 算,compression=0)。
func _craft_file_like(base: PackedByteArray, body: PackedByteArray) -> PackedByteArray:
	var out := _slice(base, 0, 20).duplicate()
	if out.size() >= 20:
		out.encode_u32(6, body.size())
		out.encode_u32(10, EditorBytes.crc32(body))
		out.encode_u8(5, 0)
		out.append_array(body)
	return out


func _layers_brief(layers: Array) -> String:
	var parts: PackedStringArray = []
	for L in layers.size():
		var ld = layers[L]
		if ld == null:
			parts.append("null")
			continue
		var d: Dictionary = ld
		var key := "desc" if String(d.get("kind", "")) == "tex" else "rgba"
		parts.append("%s:%d" % [d.get("kind"), (d.get(key, PackedInt32Array()) as PackedInt32Array).size()])
	return "[" + ", ".join(parts) + "]"


func _zero(n: int) -> PackedInt32Array:
	var a := PackedInt32Array()
	a.resize(n)
	return a


func _slice(b: PackedByteArray, begin: int, end: int) -> PackedByteArray:
	var lo := maxi(0, mini(begin, b.size()))
	var hi := maxi(lo, mini(end, b.size()))
	return b.slice(lo, hi)


func _slice_from(b: PackedByteArray, begin: int) -> PackedByteArray:
	return _slice(b, begin, b.size())


func _u8_at(b: PackedByteArray, i: int) -> int:
	return int(b[i]) if i >= 0 and i < b.size() else -1


func _u16_at(b: PackedByteArray, i: int) -> int:
	return b.decode_u16(i) if i >= 0 and i + 2 <= b.size() else -1


func _u32_at(b: PackedByteArray, i: int) -> int:
	return b.decode_u32(i) if i >= 0 and i + 4 <= b.size() else -1
