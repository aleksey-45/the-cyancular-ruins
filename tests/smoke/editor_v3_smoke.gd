extends SceneTree

# 编辑器 v3 文本 / 旧字母格式冒烟(`-s`,headless):EditorV3(镜像 level_editor/core/70_v3_text.js)。
# 去掉什么它才会红:
#   ① 版本标记谓词少认一种写法("#cyrm-v3" / "# cyrm-v3 (demo)"),或 parseV3Text 不跳过标记行
#      ⇒ ① 组红(标记落进 comments / is_v3_text 漏认);
#   ② v3 编码写错(没做 texture*16+shape / 掩码截断)、行宽非 4 倍数 / 纹理位非 3 位数字 /
#      非法形状字符 / 行宽与首行不一致 / 无网格行的闸被拿掉 ⇒ ② ③ 组红;
#   ③ 旧字母格式 2×2 折叠取错纹理(没取首个非零)或掩码位公式反了、spawn ÷2 没按 Math.floor
#      取整(负坐标)⇒ ④ 组红;
#   ④ 旧字母格式「宽高 ≥2 偶数」闸被拿掉 ⇒ ⑤ 组不再返回 ok:false(宽 3 会静默丢列);
#   ⑤ migrate_v3 的 16px 展开象限位错 / spawn 没 ÷2 / 产出 desc 时漏 legacy 迁移 ⇒ ⑥ 组逐点红;
#   ⑥ subcell_render 的 dst/src 公式错,或偷偷把负坐标归一化 ⇒ ⑦ 组红。
# 判据 = 失败清单 + 条数闸两条,退出码只是陪衬。期望值全部由测试手推;legacy base/hue 用
# TileDefs 独立现算(不复用 EditorLegacy 的返回值)。

const EXPECTED_CHECKS := 41

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	# ★ 空载守卫:load 失败还往下走会在 null 上抛错,而 `-s` 抛错走不到 quit() ⇒ 进程永久挂起。
	for p in ["res://core/editor/editor_v3.gd", "res://core/editor/editor_meta.gd",
			"res://core/editor/editor_legacy.gd", "res://core/editor/editor_map.gd",
			"res://core/editor/editor_desc.gd", "res://core/editor/editor_constants.gd"]:
		if load(p) == null:
			print("EDITOR V3 SMOKE: FAIL | 空载守卫 load(%s) 为 null(-s 不 quit 会挂死)" % p)
			quit(1)
			return

	_check_markers()
	_check_valid_v3()
	_check_errors()
	_check_legacy()
	_check_legacy_even()
	_check_migrate()
	_check_subcell()

	if _checks < EXPECTED_CHECKS:
		print("EDITOR V3 SMOKE: FAIL | 只跑了 %d 条 < %d(脚本中途中止)" % [_checks, EXPECTED_CHECKS])
		quit(1)
		return
	if not _fails.is_empty():
		print("EDITOR V3 SMOKE: FAIL(%d/%d)" % [_fails.size(), EXPECTED_CHECKS])
		for f in _fails:
			print("  - " + f)
		quit(1)
		return
	print("EDITOR V3 SMOKE: OK(%d 条断言)" % _checks)
	quit(0)


func _check_markers() -> void:
	# 三种写法都要认:规范写法、# 后无空格、行尾附加内容。
	_chk(EditorV3.is_v3_text("# cyrm-v3\n0011\n"),
			"① is_v3_text 未认出 \"# cyrm-v3\"")
	_chk(EditorV3.is_v3_text("#cyrm-v3\n0011\n"),
			"① is_v3_text 未认出 \"#cyrm-v3\"")
	_chk(EditorV3.is_v3_text("# cyrm-v3 (demo)\n0011\n"),
			"① is_v3_text 未认出 \"# cyrm-v3 (demo)\"")
	# 反向:版本号必须是紧跟阿拉伯数字,且数字后是空白或行尾;多位版本号也应认。
	_chk(not EditorV3.is_v3_text("# cyrm-v\n0011\n")
			and not EditorV3.is_v3_text("# cyrm-v3x\n0011\n")
			and EditorV3.is_v3_text("#cyrm-v12\n0011\n"),
			"① 标记谓词边界:\"# cyrm-v\" / \"# cyrm-v3x\" 不该认,#cyrm-v12 该认")
	# ★ 版本标记行不算注释:标记若落进 comments,导入→导出会往用户 meta 里塞垃圾。
	var variants := ["# cyrm-v3", "#cyrm-v3", "# cyrm-v3 (demo)"]
	for marker in variants:
		var res := EditorV3.parse_v3_text(marker + "\n# hello\n0011\n")
		var ok := bool(res.get("ok", false))
		var comments: Array = []
		if ok:
			comments = (res["parsed"] as Dictionary)["comments"]
		_chk(ok and comments == ["hello"],
				"① 标记行 %s 落进了 comments 或解析失败:%s" % [marker, JSON.stringify(res)])


func _check_valid_v3() -> void:
	# 网格行按 4 字符对齐;纹理位 3 位数字;形状 0-9A-F(大小写均可)。
	# 手推:0011→1*16+1=17;002a→2*16+10=42;010f→10*16+15=175;0000→ tex0/shape0 = 0。
	var text := "# cyrm-v3\n# player 3 5\n# enemy slime 7 9\n0011002a\n010f0000\n"
	var res := EditorV3.parse_v3_text(text)
	_chk(bool(res.get("ok", false)), "② 合法 v3 文本解析失败:%s" % JSON.stringify(res))
	if not bool(res.get("ok", false)):
		return
	var p: Dictionary = res["parsed"]
	_chk(int(p["cells_w"]) == 2 and int(p["cells_h"]) == 2
			and (p["packed"] as PackedInt32Array).size() == 4,
			"② 网格尺寸/长度:%dx%d packed=%d(期望 2x2 / 4)" % [
				int(p["cells_w"]), int(p["cells_h"]), (p["packed"] as PackedInt32Array).size()])
	var want := PackedInt32Array([17, 42, 175, 0])
	_chk((p["packed"] as PackedInt32Array) == want,
			"② packed 应 = texture*16+shape:%s(期望 %s)" % [str(p["packed"]), str(want)])
	_chk((p["players"] as Array) == [{"x": 3, "y": 5}]
			and (p["enemies"] as Array) == [{"type": "slime", "x": 7, "y": 9}],
			"② meta 解析:%s" % JSON.stringify({"players": p["players"], "enemies": p["enemies"]}))


func _check_errors() -> void:
	# 每类非法输入都必须 ok:false 且 error 点名,不许静默吞掉。
	_chk(_fail_has(EditorV3.parse_v3_text("# cyrm-v3\n0011\n001\n"), "4 的倍数"),
			"③ 行宽非 4 倍数未报「4 的倍数」")
	_chk(_fail_has(EditorV3.parse_v3_text("# cyrm-v3\n0x11\n"), "不是 3 位数字"),
			"③ 纹理位非 3 位数字未报错")
	_chk(_fail_has(EditorV3.parse_v3_text("# cyrm-v3\n001G\n"), "非法形状字符"),
			"③ 非法形状字符未报错")
	_chk(_fail_has(EditorV3.parse_v3_text("# cyrm-v3\n00110021\n0011\n"), "不一致"),
			"③ 行宽与首行不一致未报错")
	_chk(_fail_has(EditorV3.parse_v3_text("# cyrm-v3\n# only comment\n"), "没有有效网格行"),
			"③ 无网格行未报错")
	var legacy_bad := EditorV3.parse_v3_text("0Z\n11\n")
	_chk(_fail_has(legacy_bad, "非法字符") and _fail_has(legacy_bad, "0-9/A"),
			"③ 旧字母格式非法字符未报错(或未点名 0-9/A)")


func _check_legacy() -> void:
	# 4×4 字母网格 → 2×2 格。手推:
	#   格(0,0)=rows0-1/cols0-1 = [[0,1],[0,2]] → tex 取首个非零 1,掩码 sy0sx1|sy1sx1 = 0b1010 = 10
	#                                                              ⇒ 1*16+10 = 26
	#   格(1,0)=cols2-3 = [[1,0],[0,0]] → tex 1,掩码 1 ⇒ 17
	#   格(0,1)=全 0 ⇒ 0
	#   格(1,1)=rows2-3/cols2-3 = [[0,3],[0,0]] → tex 3,掩码 sy0sx1 = 0b10 = 2 ⇒ 3*16+2 = 50
	var text := "# player 4 6\n# enemy slime 9 7\n0110\n0200\n0003\n0000\n"
	var res := EditorV3.parse_v3_text(text)
	_chk(bool(res.get("ok", false)), "④ 旧字母格式解析失败:%s" % JSON.stringify(res))
	if not bool(res.get("ok", false)):
		return
	var p: Dictionary = res["parsed"]
	_chk(int(p["cells_w"]) == 2 and int(p["cells_h"]) == 2,
			"④ 4×4 折叠后应 2×2 格(实得 %dx%d)" % [int(p["cells_w"]), int(p["cells_h"])])
	_chk((p["packed"] as PackedInt32Array) == PackedInt32Array([26, 17, 0, 50]),
			"④ 2×2 折叠 packed:%s(期望 [26, 17, 0, 50])" % str(p["packed"]))
	_chk((p["players"] as Array) == [{"x": 2, "y": 3}],
			"④ spawn 坐标应 ÷2(4,6 → 2,3):%s" % JSON.stringify(p["players"]))
	_chk((p["enemies"] as Array) == [{"type": "slime", "x": 4, "y": 3}],
			"④ 敌人坐标应 ÷2(9,7 → 4,3):%s" % JSON.stringify(p["enemies"]))
	# ★ spawn ÷2 必须是 JS 的 Math.floor(负坐标向 -∞):-3/2 ⇒ -2、-5/2 ⇒ -3;向 0 截断会得 -1/-2。
	var neg := EditorV3.parse_v3_text("# player -3 -5\n0110\n0200\n0003\n0000\n")
	var neg_players: Array = []
	if bool(neg.get("ok", false)):
		neg_players = (neg["parsed"] as Dictionary)["players"]
	_chk(neg_players == [{"x": -2, "y": -3}],
			"④ 负坐标 spawn 应 floor 除 2(-3,-5 → -2,-3):%s" % JSON.stringify(neg_players))


func _check_legacy_even() -> void:
	# 宽 3 × 高 4:奇数宽会让 2×2 折叠永久丢列 ⇒ 必须报错而不是静默转换。
	var r3 := EditorV3.parse_v3_text("000\n000\n000\n000\n")
	_chk(_fail_has(r3, "偶数") and String(r3.get("error", "")).contains("3×4"),
			"⑤ 宽 3 未报「偶数」或未点名 3×4:%s" % String(r3.get("error", "")))
	# 高 3(宽 4):奇数高丢行,同样必须报错。
	var r4 := EditorV3.parse_v3_text("0000\n0000\n0000\n")
	_chk(_fail_has(r4, "偶数") and String(r4.get("error", "")).contains("4×3"),
			"⑤ 高 3 未报「偶数」或未点名 4×3:%s" % String(r4.get("error", "")))


func _check_migrate() -> void:
	# 2×2 格 v3 图:格(0,0)=tex2/shape5(legacy 002)、格(1,0)=tex16/shape1(legacy 016)、
	# 格(0,1)=空气、格(1,1)=tex1/shape1(非 legacy)。
	var text := "# cyrm-v3\n# player 5 6\n00250161\n00000011\n"
	var res := EditorV3.parse_v3_text(text)
	if not bool(res.get("ok", false)):
		_chk(false, "⑥ 迁移前置解析失败:%s" % JSON.stringify(res))
		return
	var map := EditorV3.migrate_v3(res["parsed"])
	_chk(int(map.get("sub_cols", 0)) == 8 and int(map.get("sub_rows", 0)) == 8,
			"⑥ 2×2 格应展开成 8×8 子格(实得 %dx%d)" % [
				int(map.get("sub_cols", 0)), int(map.get("sub_rows", 0))])
	# 独立期望:legacy base/hue 用 TileDefs 现算(不复用 EditorLegacy 返回值);
	# 中性档 bri/sat=4、alpha=7。legacy hue 都在 0..7,故新 hue 恰 = legacy_hue。
	var base2 := TileDefs.legacy_base_of(2)
	var base16 := TileDefs.legacy_base_of(16)
	var d2 := EditorDesc.pack_desc(base2, TileDefs.legacy_hue_of(2), 4, 4, 7)
	var d16 := EditorDesc.pack_desc(base16, TileDefs.legacy_hue_of(16), 4, 4, 7)
	var d1 := EditorDesc.neutral_desc(1)
	var got2 := _sub(map, 0, 0)
	_chk(base2 == 1 and EditorDesc.tex_of(got2) == base2 and got2 == d2,
			"⑥ tex 002 应迁移成 base 1 的 desc(实得 tex=%d desc=0x%08X,期望 tex=1 desc=0x%08X)"
					% [EditorDesc.tex_of(got2), got2, d2])
	var got16 := _sub(map, 4, 0)
	_chk(base16 == 15 and EditorDesc.tex_of(got16) == base16 and got16 == d16,
			"⑥ tex 016 应迁移成 base 15 的 desc(实得 tex=%d desc=0x%08X,期望 tex=15 desc=0x%08X)"
					% [EditorDesc.tex_of(got16), got16, d16])
	var got1 := _sub(map, 4, 4)
	_chk(got1 == d1 and EditorDesc.tex_of(got1) == 1,
			"⑥ 非 legacy 纹理 001 应保持中性 desc:0x%08X(期望 0x%08X)" % [got1, d1])
	# shape=5 ⇒ 只填 qx=0、qy∈{0,1} 的象限:X∈{0,1}, Y∈{0,1,2,3}(16px 展开逐点)。
	_chk(_sub(map, 0, 0) == d2 and _sub(map, 1, 1) == d2 and _sub(map, 1, 3) == d2,
			"⑥ 格(0,0) shape=5 的 16px 展开位置错:(0,0)/(1,1)/(1,3) 应都是 tex2 的 desc")
	_chk(_sub(map, 2, 0) == 0 and _sub(map, 3, 1) == 0
			and _sub(map, 2, 3) == 0 and _sub(map, 3, 3) == 0,
			"⑥ 格(0,0) shape=5 不该填 qx=1 的象限(X=2/3 处有值)")
	_chk(_sub(map, 4, 0) == d16 and _sub(map, 5, 1) == d16,
			"⑥ 格(1,0) shape=1 应填 X∈{4,5}, Y∈{0,1}")
	_chk(_sub(map, 4, 4) == d1 and _sub(map, 5, 5) == d1,
			"⑥ 格(1,1) shape=1 应填 X∈{4,5}, Y∈{4,5}")
	_chk(_sub(map, 6, 0) == 0 and _sub(map, 4, 2) == 0 and _sub(map, 5, 3) == 0
			and _sub(map, 0, 4) == 0 and _sub(map, 7, 7) == 0,
			"⑥ 未覆盖的子格应为 0((6,0)/(4,2)/(5,3)/(0,4)/(7,7))")
	_chk((map["players"] as Array) == [{"x": 5, "y": 6}],
			"⑥ migrate 后 players 坐标应原样(5,6):%s" % JSON.stringify(map["players"]))
	# v3 没有前/后/背景三层 ⇒ 迁移后这三层必须全空(场景层是唯一填充)。
	_chk(_layer_all_zero(map, EditorConstants.LAYER_FRONT)
			and _layer_all_zero(map, EditorConstants.LAYER_BACK)
			and _layer_all_zero(map, EditorConstants.LAYER_BG),
			"⑥ 前/后/背景三层应留空")


func _check_subcell() -> void:
	# dst = [X*16, Y*16, 16, 16];src = [qx*8, qy*8, 8, 8],qx = X%4, qy = Y%4(期望值手算)。
	var r00 := EditorV3.subcell_render(0, 0)
	_chk(_arr_eq(r00["dst"], [0, 0, 16, 16]) and _arr_eq(r00["src"], [0, 0, 8, 8]),
			"⑦ (0,0) dst/src:%s/%s(期望 [0,0,16,16]/[0,0,8,8])"
					% [str(r00["dst"]), str(r00["src"])])
	var r52 := EditorV3.subcell_render(5, 2)
	_chk(_arr_eq(r52["dst"], [80, 32, 16, 16]) and _arr_eq(r52["src"], [8, 16, 8, 8]),
			"⑦ (5,2) dst/src:%s/%s(期望 [80,32,16,16]/[8,16,8,8])"
					% [str(r52["dst"]), str(r52["src"])])
	var r76 := EditorV3.subcell_render(7, 6)
	_chk(_arr_eq(r76["dst"], [112, 96, 16, 16]) and _arr_eq(r76["src"], [24, 16, 8, 8]),
			"⑦ (7,6) dst/src:%s/%s(期望 [112,96,16,16]/[24,16,8,8])"
					% [str(r76["dst"]), str(r76["src"])])
	# ★ 不做归一化:负坐标按 JS 的 % 语义得到负象限(调用方自己 posmod),不许报错或改成 0。
	var rneg := EditorV3.subcell_render(-1, 0)
	_chk(_arr_eq(rneg["dst"], [-16, 0, 16, 16]) and _arr_eq(rneg["src"], [-8, 0, 8, 8]),
			"⑦ (-1,0) 不该被归一化:dst/src:%s/%s(期望 [-16,0,16,16]/[-8,0,8,8])"
					% [str(rneg["dst"]), str(rneg["src"])])
	_chk(r00.has("dst") and r00.has("src") and r00.size() == 2,
			"⑦ 返回形状应恰为 {dst, src}:%s" % str(r00.keys()))


# ── 小工具 ──

# 场景层某个子格(下标 y * sub_cols + x)。
func _sub(map: Dictionary, x: int, y: int) -> int:
	var layers: Array = map["layers"]
	var scene: PackedInt32Array = (layers[EditorConstants.LAYER_SCENE] as Dictionary)["desc"]
	return int(scene[y * int(map["sub_cols"]) + x])


# 某一层是否全 0(null 层视为空);颜色层读 rgba,纹理层读 desc。
func _layer_all_zero(map: Dictionary, layer: int) -> bool:
	var ld = (map["layers"] as Array)[layer]
	if ld == null:
		return true
	var d: Dictionary = ld
	var key := "desc" if String(d.get("kind", "")) == "tex" else "rgba"
	var arr: PackedInt32Array = d[key]
	for v in arr:
		if int(v) != 0:
			return false
	return true


func _arr_eq(a: Variant, b: Array) -> bool:
	var arr: Array = a
	if arr.size() != b.size():
		return false
	for i in arr.size():
		if int(arr[i]) != int(b[i]):
			return false
	return true


# 失败且 error 里含关键字(照抄 JS throw 文本的那半句)。
func _fail_has(res: Dictionary, needle: String) -> bool:
	return res.has("ok") and not bool(res["ok"]) \
			and String(res.get("error", "")).contains(needle)
