extends Control

const MAP_OPEN_COLOR := Color(0.47, 0.588, 0.624)   # 地图开阔区域底色

const OUT_DIR := "res://.superpowers/sdd"
const PVP_HUD_SCENE := "res://ui/hud/pvp_hud.tscn"
const ROYALE_HUD_SCENE := "res://ui/hud/royale_hud.tscn"
const TEAM_HUD_SCENE := "res://ui/hud/team_hud.tscn"

var _failures: Array[String] = []

# 预期断言总数：15 处顶层检查 + 1 处排行榜首行 + 1 处掉线行裁切 + 5 处状态差异比较 = 22
const EXPECTED_CHECKS := 22
var _checks := 0

# 广播布局基线：在 1920×1440 渲染分辨率下的标准布局尺寸
const BROADCAST_OUTER_W := 826.0
const BROADCAST_OUTER_H := 371.0
const BROADCAST_STRIP_W := 680.0
const BROADCAST_STRIP_H := 185.0

func _ready() -> void:
	Level0.pvp_mode = false   # 仅测试对局 HUD 自身元素，避免单人 HUD 干扰
	await _run_round()
	_finish()


func _run_round() -> void:
	# 创建全屏底色矩形，模拟游戏背景
	var bg := ColorRect.new()
	bg.color = MAP_OPEN_COLOR
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# 实例化各模式 HUD，按测试阶段分别显示
	var pvp: CanvasLayer = (load(PVP_HUD_SCENE) as PackedScene).instantiate()
	add_child(pvp)

	var royale: RoyaleHud = (load(ROYALE_HUD_SCENE) as PackedScene).instantiate() as RoyaleHud
	add_child(royale)
	royale.visible = false

	var team: TeamHud = (load(TEAM_HUD_SCENE) as PackedScene).instantiate() as TeamHud
	add_child(team)
	team.visible = false
	await _frames(3)

	# 态1: 1v1 进行中状态
	pvp._on_round_state({"state": 1, "round": 2, "scores": {1: 3, 2: 5},
			"rounds_won": {1: 1, 2: 0}, "timer": 0.0, "grace": {}})
	pvp._on_ping(72)
	await _frames(2)
	var img1 := await _shot("_hud_1_pvp_playing.png")
	_check(_bright_in(img1, pvp._score_label) > 0, "态1: 1v1 记分条绘制正常")
	print("[HUD-VISUAL] 态1 记分条 = 「%s」" % pvp._score_label.text)

	# 态2: 1v1 局中倒计时广播
	pvp._on_round_state({"state": 0, "round": 2, "scores": {1: 3, 2: 5},
			"rounds_won": {1: 1, 2: 0}, "timer": 3.0, "grace": {}})
	await _frames(2)
	var img2 := await _shot("_hud_2_pvp_broadcast.png")
	_check(_bright_in(img2, pvp._big) > 0, "态2: 中央大字广播绘制正常")
	var big_f: Font = pvp._big.get_theme_font("font")
	var big_fs: int = pvp._big.get_theme_font_size("font_size")
	print("[HUD-VISUAL] 态2 大字度量: font_size=%d get_height=%s label.size=%s"
			% [big_fs, "<无字体>" if big_f == null else str(big_f.get_height(big_fs)),
			str(pvp._big.size)])
	var bcast = pvp.get("_broadcast")
	var panel: Control = null if bcast == null else bcast.get("_panel") as Control
	var strip: Control = pvp._big.get_parent() as Control
	print("[HUD-VISUAL] 态2 广播外框 size = %s rect = %s; 标题带 size = %s rect = %s; panel.scale = %s"
			% ["<无节点>" if panel == null else str(panel.size),
			"<无节点>" if panel == null else str(panel.get_global_rect()),
			"<无节点>" if strip == null else str(strip.size),
			"<无节点>" if strip == null else str(strip.get_global_rect()),
			"<无节点>" if panel == null else str(panel.scale)])
	_check(panel != null and panel.size.is_equal_approx(
			Vector2(BROADCAST_OUTER_W, BROADCAST_OUTER_H)),
			"态2: 广播外框布局尺寸 = %d×%d(实得 %s)"
			% [BROADCAST_OUTER_W, BROADCAST_OUTER_H,
			"无节点" if panel == null else str(panel.size)])
	_check(strip != null and strip.size.is_equal_approx(
			Vector2(BROADCAST_STRIP_W, BROADCAST_STRIP_H)),
			"态2: 广播标题带布局尺寸 = %d×%d(实得 %s)"
			% [BROADCAST_STRIP_W, BROADCAST_STRIP_H,
			"无节点" if strip == null else str(strip.size)])
	_check(pvp._mask.visible, "态2: 广播背景遮罩可见")

	# 态7: 1v1 对手断线保护提示
	pvp._on_round_state({"state": 1, "round": 2, "scores": {1: 3, 2: 5},
			"rounds_won": {1: 1, 2: 0}, "grace": {3 - PvpSession.role: 42.0}})
	await _frames(2)
	var img7 := await _shot("_hud_7_pvp_grace.png")
	_check(pvp._grace_wrap.visible and pvp._grace_label.text.contains("42"),
			"态7: 1v1 对手掉线提示正常显示(role %d / 「%s」)"
			% [3 - PvpSession.role, pvp._grace_label.text])
	print("[HUD-VISUAL] 态7 掉线条 = 「%s」 rect=%s(记分条 rect=%s)"
			% [pvp._grace_label.text, str(pvp._grace_wrap.get_global_rect()),
			str(pvp.get_node("ScoreWrap").get_global_rect())])
	var d17 := _diff(img1, img7)
	_check(d17 > 500, "态7: 相对态1的像素差异 = %d" % d17)
	_check(pvp._grace_wrap.get_global_rect().position.y
			>= pvp.get_node("ScoreWrap").get_global_rect().end.y,
			"态7: 掉线提示框必须位于记分条下方，不与记分条重叠")

	# 态3: 大乱斗排行榜
	pvp.visible = false
	royale.visible = true
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
	_check(royale._rows.size() == 4, "态3: 排行榜行数 = %d(期望 4)" % royale._rows.size())
	if royale._rows.size() == 4:
		_check(_bright_in(img3, royale._rows[0]) > 0, "态3: 排行榜首行绘制正常")
		print("[HUD-VISUAL] 态3 首行 = 「%s」" % royale._rows[0].text)
		print("[HUD-VISUAL] 态3 底板 = %s" % str(royale._board_bg.get_rect()))

	# 态4: 大乱斗结算广播
	royale._on_round_state({
		"state": 3, "timer": 0.0, "match_winner": 1,
		"names": {"1": "Anon", "2": "一个很长很长的昵称"},
		"scores": {1: 9, 2: 5}, "deaths": {1: 2, 2: 4},
		"alive": {1: true, 2: true}, "left": [],
	})
	await _frames(2)
	var img4 := await _shot("_hud_4_royale_over.png")
	_check(_bright_in(img4, royale._big) > 0, "态4: 结算广播文本绘制正常")

	# 态8: 大乱斗排行榜显示断线重连倒计时
	royale._on_round_state({"state": 1, "round": 1, "scores": {1: 7, 2: 3, 3: 1},
			"deaths": {1: 0, 2: 1, 3: 2}, "rounds_won": {}, "timer": 214.0,
			"names": {1: "阿甲", 2: "bob", 3: "电脑玩家3-computer"},
			"alive": {1: true, 2: false, 3: true}, "left": [], "grace": {2: 42.0}})
	await _frames(2)
	var img8 := await _shot("_hud_8_royale_grace.png")
	var grace_row: Label = null
	for r in royale._rows:
		if r.text.contains("掉线"):
			grace_row = r
	_check(grace_row != null and grace_row.text.contains("掉线 42s"),
			"态8: 排行榜断线玩家状态应显示为「掉线 42s」; 实得「%s」"
			% ("(没有任何一行带「掉线」)" if grace_row == null else grace_row.text))
	if grace_row != null:
		var gf: Font = grace_row.get_theme_font("font")
		var tw: float = gf.get_string_size(grace_row.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
				grace_row.get_theme_font_size("font_size")).x
		var clip_w: float = RoyaleHud.BOARD_W - 8.0
		_check(tw <= clip_w,
			"态8: 掉线状态行文本未被裁切(文本宽度 %0.1f ≤ 限制宽度 %0.1f)" % [tw, clip_w])
		print("[HUD-VISUAL] 态8 掉线行 = 「%s」 文本宽=%0.1f 裁剪界=%0.1f 行宽=%0.1f"
				% [grace_row.text, tw, clip_w, grace_row.size.x])
	var d48 := _diff(img4, img8)
	_check(d48 > 500, "态8: 相对态4的像素差异 = %d" % d48)

	# 态5: 3v3 团队记分条
	royale.visible = false
	team.visible = true
	team.set_my_team(1)
	team._on_round_state({"state": 1, "round": 2, "scores": {1: 4, 2: 6},
			"rounds_won": {1: 1, 2: 0}, "timer": 0.0})
	team._on_ping(48)
	await _frames(2)
	var img5 := await _shot("_hud_5_team_playing.png")
	_check(_bright_in(img5, team._score_label) > 0, "态5: 3v3 记分条绘制正常")
	print("[HUD-VISUAL] 态5 记分条 = 「%s」" % team._score_label.text)

	# 态6: 3v3 平局广播
	team._on_round_state({"state": 3, "round": 3, "scores": {1: 12, 2: 11},
			"rounds_won": {1: 1, 2: 1}, "match_winner": 0, "timer": 0.0})
	await _frames(2)
	var img6 := await _shot("_hud_6_team_tie.png")
	_check(_bright_in(img6, team._big) > 0, "态6: 3v3 终局平局大字绘制正常")
	_check(team._big.text.contains("平"), "态6: 平局文案应包含「平」")
	print("[HUD-VISUAL] 态6 终局大字 = 「%s」/ 副文案 = 「%s」" % [team._big.text, team._sub.text])

	# 验证各状态画面之间存在显著差异
	for pair in [[img1, img2, "1→2"], [img2, img3, "2→3"], [img3, img4, "3→4"],
			[img4, img5, "4→5"], [img5, img6, "5→6"]]:
		var d := _diff(pair[0], pair[1])
		_check(d > 500, "态%s 画面有差异(%d)" % [pair[2], d])
		print("[HUD-VISUAL] 态%s 像素差异 = %d" % [pair[2], d])

	bg.queue_free()
	pvp.queue_free()
	royale.queue_free()
	team.queue_free()
	await _frames(2)


# 截图与视觉比对工具
func _shot(png_name: String) -> Image:
	await _frames(2)
	var img := get_viewport().get_texture().get_image()
	if img == null or img.get_width() == 0:
		_failures.append("截图 %s 失败(无头渲染环境下视口未激活)" % png_name)
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


const BRIGHT_MARGIN := 0.10


func _bright_in(img: Image, ctrl: Control) -> int:
	if img == null or img.get_width() == 0 or ctrl == null or not is_instance_valid(ctrl):
		return 0
	var s := Vector2(img.get_width(), img.get_height()) / get_viewport().get_visible_rect().size
	var r := ctrl.get_global_rect()
	var x0 := clampi(int(r.position.x * s.x), 0, img.get_width())
	var y0 := clampi(int(r.position.y * s.y), 0, img.get_height())
	var x1 := clampi(int((r.position.x + r.size.x) * s.x), 0, img.get_width())
	var y1 := clampi(int((r.position.y + r.size.y) * s.y), 0, img.get_height())
	return count_bright(img, Rect2i(x0, y0, x1 - x0, y1 - y0))


static func count_bright(img: Image, rect: Rect2i) -> int:
	if img == null or img.get_width() == 0:
		return 0
	var x0 := clampi(rect.position.x, 0, img.get_width())
	var y0 := clampi(rect.position.y, 0, img.get_height())
	var x1 := clampi(rect.position.x + rect.size.x, 0, img.get_width())
	var y1 := clampi(rect.position.y + rect.size.y, 0, img.get_height())
	var lums: Array[float] = []
	for y in range(y0, y1):
		for x in range(x0, x1):
			var c := img.get_pixel(x, y)
			lums.append((c.r + c.g + c.b) / 3.0)
	if lums.is_empty():
		return 0
	lums.sort()
	var base: float = lums[int(float(lums.size() - 1) * 0.25)]
	var thresh := base + BRIGHT_MARGIN
	var n := 0
	for l in lums:
		if l > thresh:
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
	_checks += 1
	if ok:
		print("[HUD-VISUAL] ✓ %s" % msg)
	else:
		_failures.append(msg)
		print("[HUD-VISUAL] ✗ %s" % msg)


func _finish() -> void:
	# 校验断言总数是否与预期一致
	if _checks != EXPECTED_CHECKS:
		_failures.append("实跑 %d 条断言，与预期数量 EXPECTED_CHECKS=%d 不一致"
				% [_checks, EXPECTED_CHECKS])
	if _failures.is_empty():
		print("COMBAT HUD VISUAL PROBE: ALL-OK(%d 条断言)" % _checks)
		get_tree().quit(0)
	else:
		print("COMBAT HUD VISUAL PROBE: FAIL")
		for f in _failures:
			print("  - %s" % f)
		get_tree().quit(1)
