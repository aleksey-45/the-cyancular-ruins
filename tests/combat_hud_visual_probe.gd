extends Control

# 对局内 HUD(PvpHud / RoyaleHud)视觉验收探针(**必须带真实渲染,不能加 --headless**)。
# 跑法:
#   "$GODOT" --path . --quit-after 900 res://tests/combat_hud_visual_probe.tscn
# 把两块对局 HUD 的关键状态定格成 PNG 交给控制者读图,同时打数值断言:
#   _hud_1_pvp_playing.png  1v1 记分条 + 延迟(PLAYING)
#   _hud_2_pvp_broadcast.png 1v1 中央广播(倒计时巨字)
#   _hud_3_royale_board.png 大乱斗排行榜(4 行:自己/他人/复活中/离开)
#   _hud_4_royale_over.png  大乱斗终局广播
# PNG 落 res://.superpowers/sdd/(该目录自带 .gitignore = *,不入库)。
#
# ★ 背景故意铺**地图开阔区的浅灰蓝**(#78969F),不是深色底:
#   对局 HUD 是直接叠在地图上的,垫深底取图会把「浅底上读不出来」这类问题整个遮掉 ——
#   单机 HUD 就是这么漏掉 1.9:1 的血条的(见 ui/hud.gd 的 PLATE_COLOR 注释)。
const MAP_OPEN_COLOR := Color(0.47, 0.588, 0.624)   # ≈#78969F,实测取的地图开阔区色

const OUT_DIR := "res://.superpowers/sdd"
const PVP_HUD_SCENE := "res://ui/pvp_hud.tscn"

var _failures: Array[String] = []


func _ready() -> void:
	Level0.pvp_mode = false   # 对局 HUD 与单机 HUD 会同时在场,量的是对局 HUD 自己的元素
	await _run_round()
	_finish()


func _run_round() -> void:
	# 地图色底:整个视口铺满,两块 HUD 都叠在它上面
	var bg := ColorRect.new()
	bg.color = MAP_OPEN_COLOR
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# 两块 HUD 分别在场:它们都常驻同一屏(1v1 与 大乱斗 各一套),但取图必须分开 ——
	# 否则 PvP 的中央倒计时广播会串进大乱斗那张,读图时无法判断哪条属于哪套。
	var pvp: CanvasLayer = (load(PVP_HUD_SCENE) as PackedScene).instantiate()
	add_child(pvp)
	var royale: RoyaleHud = RoyaleHud.new()
	add_child(royale)
	royale.visible = false
	await _frames(3)

	# ── 态1:1v1 PLAYING ──
	pvp._on_round_state({"state": 1, "round": 2, "scores": {1: 3, 2: 5},
			"rounds_won": {1: 1, 2: 0}, "timer": 0.0})
	pvp._on_ping(72)
	await _frames(2)
	var img1 := await _shot("_hud_1_pvp_playing.png")
	_check(_bright_in(img1, pvp._score_label) > 0, "态1:1v1 记分条画出了文本")
	print("[HUD-VISUAL] 态1 记分条 = 「%s」" % pvp._score_label.text)

	# ── 态2:1v1 中央广播(倒计时)──
	pvp._on_round_state({"state": 0, "round": 2, "scores": {1: 3, 2: 5},
			"rounds_won": {1: 1, 2: 0}, "timer": 3.0})
	await _frames(2)
	var img2 := await _shot("_hud_2_pvp_broadcast.png")
	_check(_bright_in(img2, pvp._big) > 0, "态2:中央大字画出来了")
	_check(pvp._mask.visible, "态2:广播遮罩可见")

	# ── 态3:大乱斗排行榜 ──
	pvp.visible = false    # 收起 1v1(含它的中央广播),只留大乱斗这一套
	royale.visible = true
	# names 键是**字符串** role(协议里就是字符串键,见 royale_host 的 round_state 载荷)
	royale._on_round_state({
		"state": 1, "timer": 187.0,
		"names": {"1": "Anon", "2": "一个很长很长的昵称", "3": "Bob", "4": "Carol"},
		"scores": {1: 7, 2: 5, 3: 5, 4: 0},
		"deaths": {1: 2, 2: 4, 3: 1, 4: 3},
		"alive": {1: true, 2: false, 3: true, 4: true},
		"left": [4],
	})
	await _frames(2)
	var img3 := await _shot("_hud_3_royale_board.png")
	_check(royale._rows.size() == 4, "态3:排行榜行数 = %d(期望 4)" % royale._rows.size())
	if royale._rows.size() == 4:
		_check(_bright_in(img3, royale._rows[0]) > 0, "态3:排行榜首行画出了文本")
		print("[HUD-VISUAL] 态3 首行 = 「%s」" % royale._rows[0].text)
		print("[HUD-VISUAL] 态3 底板 = %s" % str(royale._board_bg.get_rect()))

	# ── 态4:大乱斗终局广播 ──
	royale._on_round_state({
		"state": 3, "timer": 0.0, "match_winner": 1,
		"names": {"1": "Anon", "2": "一个很长很长的昵称"},
		"scores": {1: 9, 2: 5}, "deaths": {1: 2, 2: 4},
		"alive": {1: true, 2: true}, "left": [],
	})
	await _frames(2)
	var img4 := await _shot("_hud_4_royale_over.png")
	_check(_bright_in(img4, royale._big) > 0, "态4:终局大字画出来了")

	# ── 四态两两不同(证明"切了状态"而不是"拍了四张一样的")──
	for pair in [[img1, img2, "1→2"], [img2, img3, "2→3"], [img3, img4, "3→4"]]:
		var d := _diff(pair[0], pair[1])
		_check(d > 500, "态%s 画面有差异(%d)" % [pair[2], d])
		print("[HUD-VISUAL] 态%s 像素差异 = %d" % [pair[2], d])

	bg.queue_free()
	pvp.queue_free()
	royale.queue_free()
	await _frames(2)


# ── 截图与数值工具 ──
func _shot(png_name: String) -> Image:
	await _frames(2)
	var img := get_viewport().get_texture().get_image()
	if img == null or img.get_width() == 0:
		_failures.append("截图 %s 失败(是不是误加了 --headless?)" % png_name)
		return Image.new()
	var path := OUT_DIR.path_join(png_name)
	if img.save_png(path) != OK:
		_failures.append("截图 %s 写入失败(%s)" % [png_name, path])
	else:
		print("[HUD-VISUAL] 已存 %s  %dx%d" % [
				ProjectSettings.globalize_path(path), img.get_width(), img.get_height()])
	return img


func _frames(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


# 控件矩形内"亮像素"(三通道均值 > 0.5)计数 —— 证明文本真的画出来了
func _bright_in(img: Image, ctrl: Control) -> int:
	if img == null or img.get_width() == 0 or ctrl == null or not is_instance_valid(ctrl):
		return 0
	var s := Vector2(img.get_width(), img.get_height()) / get_viewport().get_visible_rect().size
	var r := ctrl.get_global_rect()
	var x0 := clampi(int(r.position.x * s.x), 0, img.get_width())
	var y0 := clampi(int(r.position.y * s.y), 0, img.get_height())
	var x1 := clampi(int((r.position.x + r.size.x) * s.x), 0, img.get_width())
	var y1 := clampi(int((r.position.y + r.size.y) * s.y), 0, img.get_height())
	var n := 0
	for y in range(y0, y1):
		for x in range(x0, x1):
			var c := img.get_pixel(x, y)
			if (c.r + c.g + c.b) / 3.0 > 0.5:
				n += 1
	return n


func _diff(a: Image, b: Image) -> int:
	if a.get_width() == 0 or b.get_width() == 0 or a.get_width() != b.get_width():
		return 0
	var n := 0
	for y in range(0, a.get_height(), 4):
		for x in range(0, a.get_width(), 4):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			if absf(ca.r - cb.r) > 0.05 or absf(ca.g - cb.g) > 0.05 or absf(ca.b - cb.b) > 0.05:
				n += 1
	return n


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("[HUD-VISUAL] ✓ %s" % msg)
	else:
		_failures.append(msg)
		print("[HUD-VISUAL] ✗ %s" % msg)


func _finish() -> void:
	if _failures.is_empty():
		print("COMBAT HUD VISUAL PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("COMBAT HUD VISUAL PROBE: FAIL")
		for f in _failures:
			print("  - %s" % f)
		get_tree().quit(1)
