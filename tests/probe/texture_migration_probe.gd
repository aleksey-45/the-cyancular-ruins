extends SceneTree

# legacy 纹理读时迁移守卫:旧图集废弃槽位(tex 2-5 / 16-18,新图集里全透明)必须在**读时**迁移成

const EXPECTED_CHECKS := 4
const V3_TMP := "user://texture_migration_probe.cyrm"

var _fails: Array[String] = []
var _checks := 0


func _initialize() -> void:
	TileDefs.load_defs()
	_chk_legacy_table()
	_chk_v4_parse()
	_chk_v3_text()
	_chk_migrate_descriptor()

	if _checks != EXPECTED_CHECKS:
		_fails.append("实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("TEXTURE MIGRATION OK(%d 条断言):全表 · v4 parse · v3 文本 · 合成规则" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("TEXTURE MIGRATION FAILED: %d 处" % _fails.size())
		quit(1)


# ① legacy_base_of / legacy_hue_of 全表(1..22 + 越界):去掉 json 里某一项 / 表装填错位 / MAX_TEXTURE 重编号 ⇒ 红。
func _chk_legacy_table() -> void:
	var want := {2: [1, 3], 3: [1, 1], 4: [1, 5], 5: [1, 0], 16: [15, 2], 17: [15, 7], 18: [15, 7]}
	var bad: Array[String] = []
	if TileDefs.MAX_TEXTURE != 22:
		bad.append("MAX_TEXTURE=%d(纹理 id 空间必须稳定 1..22 不重编号)" % TileDefs.MAX_TEXTURE)
	for tex in range(0, TileDefs.MAX_TEXTURE + 2):
		var wb: int = (want[tex] as Array)[0] if want.has(tex) else 0
		var wh: int = (want[tex] as Array)[1] if want.has(tex) else 0
		if TileDefs.legacy_base_of(tex) != wb:
			bad.append("legacy_base_of(%d)=%d 期望 %d" % [tex, TileDefs.legacy_base_of(tex), wb])
		elif wb != 0 and TileDefs.legacy_hue_of(tex) != wh:
			bad.append("legacy_hue_of(%d)=%d 期望 %d" % [tex, TileDefs.legacy_hue_of(tex), wh])
	_chk(bad.is_empty(), "legacy 迁移全表%s" % ["" if bad.is_empty() else ":" + "; ".join(bad)])


# ② 合成 v4 字节(palette 含 legacy 描述符 + 索引流)→ parse:scene 必须已迁移。
#    去掉 parse 里的 migrate_descriptor ⇒ 红(这是 v4 入口的唯一迁移点)。
func _chk_v4_parse() -> void:
	var d_legacy2 := _desc(2, 4, 4, 4, 7)        # 纯色变体 tex2,中性辅码
	var d_legacy16 := _desc(16, 2, 5, 3, 6)      # 树叶变体 tex16,带非中性辅码(bri5/sat3/alpha6 必须原样保留)
	var d_plain := _desc(7, 6, 2, 5, 7)          # 非 legacy:必须原样
	var palette := [0, d_legacy2, d_legacy16, d_plain]
	var sc := 12
	var sr := 4
	var indices: Array = []
	for i in sc * sr:
		indices.append(0)
	for sy in 4:                                  # 第 1 格 → idx1(tex2),第 2 格 → idx2(tex16),第 3 格全空气
		for sx in 4:
			indices[sy * sc + sx] = 1
			indices[sy * sc + 4 + sx] = 2
	indices[3 * sc + 9] = 3                       # 空气格里散落一个非 legacy 子格
	var data := _build_v4(palette, indices, sc, sr)
	var v := MapFormatV4.parse(data)
	if not bool(v.get("ok", false)):
		_chk(false, "合成 v4 parse 失败:%s" % str(v.get("error", "?")))
		return
	var scene: PackedInt32Array = v["scene"]
	var e_tex2 := _desc(1, 3, 4, 4, 7)            # tex2 → base1,hue=clamp(4+3-4)=3
	var e_tex16 := _desc(15, 0, 5, 3, 6)          # tex16 → base15,hue=clamp(2+2-4)=0,bri/sat/alpha 原样
	var ok := scene[0] == e_tex2 and scene[4] == e_tex16 and scene[3 * sc + 9] == d_plain
	for i in scene.size():                        # 前两格之外全是空气
		if i % sc < 8 or i == 3 * sc + 9:
			continue
		if scene[i] != 0:
			ok = false
	var subgrid := MapFormatV4.scene_to_subgrid(scene, sc, sr)
	var descgrid := MapFormatV4.scene_to_descgrid(scene, sc, sr)
	ok = ok and subgrid[0][0] == 1 and subgrid[0][4] == 15 and subgrid[3][9] == 7 and subgrid[0][8] == 0 \
			and descgrid[0][0] == e_tex2 and descgrid[0][4] == e_tex16 and descgrid[0][8] == 0
	_chk(ok, "v4 parse 读时迁移:tex2→(1,hue3) / tex16→(15,hue0,辅码保留) / 非 legacy 原样 / 空气 0 / descgrid 同源")


# ③ v3 文本(含 legacy 纹理 2 与 16)→ load_subgrid_with_descs:textures 必须是 base、descs 带 hue;
#    load_map_file 的格级 packed 网格同样迁移。去掉文本路径的迁移 ⇒ 红。
func _chk_v3_text() -> void:
	var f := FileAccess.open(V3_TMP, FileAccess.WRITE)
	if f == null:
		_chk(false, "写不开 %s" % V3_TMP)
		return
	f.store_string("# cyrm-v3\n001F002F\n0168015F\n")
	f.close()
	var sd := MapFormat.load_subgrid_with_descs(V3_TMP)
	var texs: Array = sd["textures"]
	var descs: Array = sd["descs"]
	var grid := MapFormat.load_map_file(V3_TMP)
	var ok := texs.size() == 8 and not texs.is_empty()
	if ok:
		# 格 (0,0)=tex1 全砖 / (1,0)=tex2→base1 / (0,1)=tex16→base15 形状 8(只盖象限 qy1qx1 = 子格 (6..7,2..3))/ (1,1)=tex15 全砖
		ok = texs[0][0] == 1 and texs[0][4] == 1 and texs[6][2] == 15 and texs[4][4] == 15 \
				and descs[0][0] == MapFormatV4.neutral_descriptor(1) \
				and descs[0][4] == _desc(1, 3, 4, 4, 7) \
				and descs[6][2] == _desc(15, 2, 4, 4, 7) \
				and descs[4][4] == MapFormatV4.neutral_descriptor(15) \
				and texs[4][0] == 0 and descs[4][0] == 0 \
				and grid.size() == 2 \
				and grid[0][0] == MapFormat.pack(1, 15) and grid[0][1] == MapFormat.pack(1, 15) \
				and grid[1][0] == MapFormat.pack(15, 8) and grid[1][1] == MapFormat.pack(15, 15)
	_chk(ok, "v3 文本读时迁移:子格纹理 = base、描述符带 legacy hue 档、形状掩码保留、格级 packed 同步迁移")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(V3_TMP))


# ④ 合成规则本体(migrate_descriptor):hue 档相加后 clamp [0,7](两个方向都要钳)、辅码与保留位原样、
#    非 legacy 与空气恒等。把 clamp 去掉(溢出串到 bri 位)或改成档位取模 ⇒ 红。
func _chk_migrate_descriptor() -> void:
	var bad: Array[String] = []
	var cases := [
		[_desc(17, 7, 4, 4, 7), _desc(15, 7, 4, 4, 7)],    # 7+7-4=10 → clamp 7(上界)
		[_desc(5, 0, 4, 4, 7), _desc(1, 0, 4, 4, 7)],       # 0+0-4=-4 → clamp 0(下界)
		[_desc(4, 1, 6, 2, 5), _desc(1, 2, 6, 2, 5)],       # 1+5-4=2;bri6/sat2/alpha5 原样
		[_desc(18, 4, 0, 7, 1), _desc(15, 7, 0, 7, 1)],     # 4+7-4=7
		[_desc(7, 4, 4, 4, 7), _desc(7, 4, 4, 4, 7)],       # 非 legacy 恒等
		[0, 0],                                              # 空气恒等
	]
	for c in cases:
		var got := MapFormatV4.migrate_descriptor(int(c[0]))
		if got != int(c[1]):
			bad.append("0x%X → 0x%X(期望 0x%X)" % [int(c[0]), got, int(c[1])])
	_chk(bad.is_empty(), "migrate_descriptor 合成规则%s" % ["" if bad.is_empty() else ":" + "; ".join(bad)])


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


# packDesc(texture, hue, bright, sat, alpha) —— 位域与 level_editor/core/90_desc.js 逐字一致。
func _desc(tex: int, hue: int, bri: int, sat: int, alpha: int) -> int:
	return (tex << 12) | ((alpha & 7) << 9) | ((sat & 7) << 6) | ((bri & 7) << 3) | (hue & 7)


# 合成一份最小 v4 文件字节(compression=0,只有场景层)。
func _build_v4(palette: Array, indices: Array, sc: int, sr: int) -> PackedByteArray:
	var body := PackedByteArray()
	MapFormatV4.write_u16(body, 0)                 # meta_len = 0
	body.append(1)                                 # kind = 调色板 + 索引流
	MapFormatV4.write_u16(body, palette.size())
	for d in palette:
		MapFormatV4.write_u32(body, int(d))
	body.append(1)                                 # index_width = 1
	for idx in indices:
		body.append(int(idx))
	var out := PackedByteArray()
	out.append_array("CYRM".to_ascii_buffer())
	out.append(4)
	out.append(0)
	MapFormatV4.write_u32(out, body.size())
	MapFormatV4.write_u32(out, MapFormatV4.crc32(body))
	MapFormatV4.write_u16(out, sc)
	MapFormatV4.write_u16(out, sr)
	out.append(0b0010)                             # layer_flags:只有场景层
	out.append(0)
	out.append_array(body)
	return out
