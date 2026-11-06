extends SceneTree

# 背景四层景深守卫:layer_flags bit3-6 的颜色层解析 + 视差数学(ParallaxBg 的唯一实现)。
# 去掉什么才红:① DEPTH 改值/改序 ⇒ 1;② layer_origin 少乘 (1-f) ⇒ 2~4;③ layer_region 起点不用 cam*f ⇒ 5;
#   ④ parse 不存 kind=2 ⇒ 8~10;⑤ 缺层当空数组 ⇒ 10;⑥ load_bg_layers 不看 ok 位 ⇒ 11;
#   ⑦ bake 不做 alpha 加权均值 ⇒ 14/15(透明格把颜色拉黑)。
# 测不到什么:屏幕上"背景真的以 1/4 速度移动"的观感、与光照/后处理的合成次序(只能人眼)。

const EXPECTED_CHECKS := 20
const EPS := 0.0001

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _near(a: float, b: float) -> bool:
	return absf(a - b) <= EPS


func _u16(out: PackedByteArray, v: int) -> void:
	out.append(v & 0xFF)
	out.append((v >> 8) & 0xFF)


func _u32(out: PackedByteArray, v: int) -> void:
	out.append(v & 0xFF)
	out.append((v >> 8) & 0xFF)
	out.append((v >> 16) & 0xFF)
	out.append((v >> 24) & 0xFF)


# 合成一张 v4:场景层全空气 + 可选的四层颜色层(bit3-6)。缺项(null)不置位。
func _make_v4(sub_cols: int, sub_rows: int, bgs: Array) -> PackedByteArray:
	var n := sub_cols * sub_rows
	var body := PackedByteArray()
	_u16(body, 0)                                  # meta_len = 0
	body.append(1)
	_u16(body, 1)                                  # 场景层调色板 1 项
	_u32(body, 0)                                  # palette[0] = 空气
	body.append(1)                                 # index_width = 1
	body.resize(body.size() + n)                   # 全 0 索引
	var flags := 0b00000010
	for i in 4:
		if i >= bgs.size() or bgs[i] == null:
			continue
		flags |= 1 << (3 + i)
		body.append(2)
		var arr: PackedInt32Array = bgs[i]
		for j in n:
			_u32(body, arr[j] if j < arr.size() else 0)
	var out := PackedByteArray()
	out.append_array("CYRM".to_ascii_buffer())
	out.append(4)
	out.append(0)
	_u32(out, body.size())
	_u32(out, MapFormatV4.crc32(body))
	_u16(out, sub_cols)
	_u16(out, sub_rows)
	out.append(flags)
	out.append(0)
	out.append_array(body)
	return out


func _initialize() -> void:
	if load("res://core/present/parallax_bg.gd") == null \
			or load("res://core/sim/map_format_v4.gd") == null \
			or load("res://core/sim/map_format.gd") == null:
		print("BG PARALLAX FAILED: load() 返回 null(-s 空载守卫:不 quit 会挂死)")
		quit(1)
		return

	# ① 景深档位(层 3..6)
	var depth_ok: bool = ParallaxBg.DEPTH.size() == 4 \
			and _near(ParallaxBg.DEPTH[0], 1.0) and _near(ParallaxBg.DEPTH[1], 0.75) \
			and _near(ParallaxBg.DEPTH[2], 0.5) and _near(ParallaxBg.DEPTH[3], 0.25)
	_chk(depth_ok, "★ DEPTH = [1.0, 0.75, 0.5, 0.25](实得 %s)" % str(ParallaxBg.DEPTH))

	var cam := Vector2(1200.0, 800.0)
	var view := Vector2(1920.0, 1440.0)

	# ②③④ 节点世界坐标 = cam × (1 − f)
	_chk(ParallaxBg.layer_origin(cam, 1.0).is_zero_approx(),
			"f=100%% 的层钉在世界原点(与场景同速;实得 %s)" % str(ParallaxBg.layer_origin(cam, 1.0)))
	var o25 := ParallaxBg.layer_origin(cam, 0.25)
	_chk(_near(o25.x, cam.x * 0.75) and _near(o25.y, cam.y * 0.75),
			"f=25%% 的层坐标 = cam×0.75(实得 %s)" % str(o25))
	var o0 := ParallaxBg.layer_origin(cam, 0.0)
	_chk(_near(o0.x, cam.x) and _near(o0.y, cam.y),
			"f=0 的层完全跟着相机(等价于不视差的贴片;实得 %s)" % str(o0))

	# ⑤⑥ 采样起点 = cam × f,尺寸 = 视口
	var reg := ParallaxBg.layer_region(cam, 0.25, view)
	_chk(_near(reg.position.x, cam.x * 0.25) and _near(reg.position.y, cam.y * 0.25),
			"★ 采样起点 = cam×f(f=25%% ⇒ %s)" % str(reg.position))
	_chk(_near(reg.size.x, view.x) and _near(reg.size.y, view.y),
			"采样区域尺寸 = 视口(实得 %s)" % str(reg.size))

	# ⑦ 相机位移 Δ ⇒ 该层屏幕相对位移 = f·Δ(节点世界位移 (1−f)Δ,屏幕 = 世界 − cam ⇒ −fΔ)
	var delta := Vector2(400.0, -200.0)
	for i in 4:
		var f: float = ParallaxBg.DEPTH[i]
		var moved: Vector2 = ParallaxBg.layer_origin(cam + delta, f) - ParallaxBg.layer_origin(cam, f)
		var screen_move: Vector2 = moved - delta
		var want := -delta * f
		_chk(screen_move.is_equal_approx(want),
				"★ f=%d%% 时屏幕位移 = −f·Δ(期望 %s,实得 %s)" % [int(f * 100.0), str(want), str(screen_move)])

	# ⑧⑨⑩ v4 解析:bit3-6 的颜色层按层号落到 bgs[0..3],缺层为 null
	var n := 16
	var l0 := PackedInt32Array()
	l0.resize(n)
	var l3 := PackedInt32Array()
	l3.resize(n)
	for i in n:
		l0[i] = 0xFF0000FF
		l3[i] = 0x0000FFFF
	var with_two := MapFormatV4.parse(_make_v4(4, 4, [l0, null, null, l3]))
	_chk(bool(with_two.get("ok", false)), "合成的 v4 能被解析(错误:%s)" % str(with_two.get("error", "")))
	var bgs: Array = with_two.get("bgs", [])
	# ★ 先取数再断言:缺层时在断言消息里直接下标 null 会抛错 ⇒ 走不到 quit() ⇒ 整支冒烟挂住。
	var got0 := -1
	if bgs.size() == 4 and bgs[0] != null:
		got0 = int((bgs[0] as PackedInt32Array)[5]) & 0xFFFFFFFF
	_chk(got0 == 0xFF0000FF,
			"★ 层3(背景100%%)按 u32 RGBA 原样解出(期望 0xff0000ff,实得 0x%x)" % got0)
	var got3 := -1
	if bgs.size() == 4 and bgs[3] != null:
		got3 = int((bgs[3] as PackedInt32Array)[0]) & 0xFFFFFFFF
	_chk(got3 == 0x0000FFFF,
			"★ 层6(背景25%)解到 bgs[3](期望 0x0000ffff,实得 0x%x)" % got3)
	_chk(bgs[1] == null and bgs[2] == null,
			"★ flags 未置位的 75%/50% 两层必须是 null(缺层不是空数组)")

	# ⑪⑫ load_bg_layers:真图(只有场景层 bit1)⇒ 4 个 null;临时文件 ⇒ 4 项
	var real := MapFormat.load_bg_layers(MazeGenerator.map_file_path())
	var all_null := real.size() == 4 and real[0] == null and real[1] == null and real[2] == null and real[3] == null
	_chk(all_null, "★ 现存地图只有场景层 ⇒ load_bg_layers 恒 4 个 null(实得 %s)" % str(real))
	var tmp := "user://bg_parallax_probe.cyrm"
	var fw := FileAccess.open(tmp, FileAccess.WRITE)
	fw.store_buffer(_make_v4(4, 4, [l0, l0, l0, l0]))
	fw.close()
	var loaded := MapFormat.load_bg_layers(tmp)
	_chk(loaded.size() == 4 and loaded[0] != null and loaded[3] != null,
			"★ 四层齐全的临时文件 ⇒ load_bg_layers 四项都非 null")

	# ⑬⑭⑮ 烘焙:尺寸 = 格数 × CELL_PX;纯色 ⇒ 该色;全透明 ⇒ 全透明(alpha 加权均值不把黑混进来)
	var one_cell := PackedInt32Array()
	one_cell.resize(16)
	for i in 16:
		one_cell[i] = 0xFF0000FF
	var img := ParallaxBg.bake_layer_image(one_cell, Vector2i(1, 1))
	_chk(img.get_width() == ParallaxBg.CELL_PX and img.get_height() == ParallaxBg.CELL_PX,
			"烘图尺寸 = 格数 × CELL_PX(实得 %dx%d)" % [img.get_width(), img.get_height()])
	var px := img.get_pixel(0, 0)
	_chk(absf(px.r - 1.0) < 0.02 and absf(px.g) < 0.02 and absf(px.a - 1.0) < 0.02,
			"纯红层烘出来是纯红(实得 %s)" % str(px))
	var clear_cell := PackedInt32Array()
	clear_cell.resize(16)
	var clear_img := ParallaxBg.bake_layer_image(clear_cell, Vector2i(1, 1))
	_chk(absf(clear_img.get_pixel(0, 0).a) < 0.02,
			"★★ 全透明层烘成全透明(alpha=0;不做 alpha 加权就会混进黑)")
	# ★ 半透明混排:8 个不透明红 + 8 个全透明。alpha 加权 ⇒ 颜色仍是纯红(只有 alpha 打折);
	#   直接平均 ⇒ 红色被稀释成 0.5(边缘发暗的那种错)。这条才是"加权"的判据。
	var mixed := PackedInt32Array()
	mixed.resize(16)
	for i in 16:
		mixed[i] = 0xFF0000FF if i < 8 else 0
	var mixed_img := ParallaxBg.bake_layer_image(mixed, Vector2i(1, 1))
	var mp := mixed_img.get_pixel(0, 0)
	_chk(mp.r > 0.95 and absf(mp.g) < 0.02 and mp.a > 0.4 and mp.a < 0.6,
			"★★ 半透明混排:颜色不被透明格稀释(r=%.2f、alpha=%.2f;直接平均会得到 r≈0.5)" % [mp.r, mp.a])

	if _checks != EXPECTED_CHECKS:
		_fails.append("实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("BG PARALLAX OK(%d 条断言):景深档位 · 视差两式 · 位移比 · v4 四层解析 · 缺层 null · 烘焙加权" % _checks)
		quit(0)
	else:
		for f2 in _fails:
			print("  [FAIL] ", f2)
		print("BG PARALLAX: FAIL(%d 处)" % _fails.size())
		quit(1)
