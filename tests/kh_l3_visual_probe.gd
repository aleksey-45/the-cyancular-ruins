extends Control

# L3 视觉验收探针(**必须带真实渲染,不能加 --headless** —— headless 下 get_image() 返回 null)。
# 跑法:
#   "$GODOT" --path . --quit-after 600 res://tests/kh_l3_visual_probe.tscn
# 把 HUD 换弹玩法的三态定格成 PNG 交给控制者读图,同时打数值断言(可当 CI 用):
#   _l3_1_ammo.png     满弹「12/12」+ 武器剪影 + 名称
#   _l3_2_reloading.png「装填中…」+ 换弹进度条(进度在中段)
#   _l3_3_low.png      残弹低位「1/12」
# PNG 落 res://.superpowers/sdd/(该目录 .gitignore 为 *,不入库)。
#
# 两条 L2 踩过的坑,这里刻意避开:
#  1) 截瞬态一律用**帧驱动**(await process_frame),不用真实时间等待 —— 冷机/慢机不抖。
#     本探针更进一步:玩家 set_physics_process(false),换弹进度只由探针显式 tick 推进,
#     进度条停在哪由代码决定,与帧率完全无关。
#  2) --quit-after 的单位是**帧**不是秒(故用 600 帧 ≈ 20s@30fps,用 60 会被 ~2s 掐断)。
#
# 数值腿与视觉腿缺一不可:断言判「文本/尺寸/显隐对不对」,PNG 判「肉眼看着对不对」。

const OUT_DIR := "res://.superpowers/sdd"
const PLAYER_SCENE := "res://scenes/player/Player.tscn"
const RELOAD_SAMPLE_DT := 0.5          # 手动推进的换弹时长(秒):手枪 reload_time=1.0 → 进度 50%

var _failures: Array[String] = []
var _hud: HUD = null
var _w: WeaponBase = null


func _ready() -> void:
	# 探针自持确定性:本机 user://settings.cfg 可能被用户开着 pvp(换弹恒定开启,无开关)。
	Level0.pvp_mode = false

	# 窗口尺寸实取(不写死:stretch/mode=viewport 下与工程设置解耦,改分辨率探针不失效)。
	# 注意不要给根 Control 赋 size —— 它的锚点是全屏,赋值会被引擎在 _ready 后覆盖并告警。
	var win := get_viewport().get_visible_rect().size
	print("[L3-VISUAL] 窗口可见区 = %s" % str(win))

	# 深色底:金色残弹/进度条在暗底上才读得出(也便于统计"金色像素数")
	var bg := ColorRect.new()
	bg.color = Color(0.09, 0.10, 0.13)
	bg.position = Vector2.ZERO
	bg.size = win
	add_child(bg)

	var ps: PackedScene = load(PLAYER_SCENE)
	if ps == null:
		_failures.append("Player.tscn 载入失败")
		_finish()
		return
	var p: Node = ps.instantiate()
	add_child(p)
	# 冻结玩家物理:换弹进度不受真实物理 tick 推进,只由本探针显式 tick(帧率无关、可复现)
	p.set_physics_process(false)
	p.global_position = Vector2(win.x * 0.5, win.y * 0.62)   # 远离左下角 HUD 区,不干扰像素统计
	await _frames(3)   # 武器是 call_deferred 入树的,等它 _ready(mag_ammo = mag_size)

	_hud = HUD.new()
	add_child(_hud)    # HUD._ready 从 "player" 组找玩家并接管剪影/名称/残弹显示
	await _frames(3)

	_w = p.weapons.current_weapon()
	if _w == null or _hud == null or _hud._ammo_label == null:
		_failures.append("前置失败:HUD 未建起残弹标签(weapon=%s)" % str(_w))
		_finish()
		return
	print("[L3-VISUAL] HUD 残弹标签全局矩形 = %s" % str(_hud._ammo_label.get_global_rect()))

	# ── 态1:满弹 12/12 ──────────────────────────────────────────────
	_check(_w.mag_ammo == 12, "态1:开局残弹应 12(实际 %d)" % _w.mag_ammo)
	var img1 := await _shot("_l3_1_ammo.png")
	_check(_hud._ammo_label.visible, "态1:残弹标签不可见")
	_check(_hud._ammo_label.text == "12/12", "态1:文本应为「12/12」(实际「%s」)" % _hud._ammo_label.text)
	_check(_hud._weapon_icon.texture != null, "态1:武器剪影贴图为空")
	_check(_hud._weapon_name.text == "手枪", "态1:武器名应为「手枪」(实际「%s」)" % _hud._weapon_name.text)
	_check(not _hud._reload_bar.visible, "态1:非换弹态进度条不应可见")
	var bright1 := _bright_in(img1, _hud._ammo_label)
	var gold1 := _gold_in(img1, _hud._ammo_label)
	var accent1 := _accent_in(img1, _hud._reload_bar)
	_check(bright1 > 0, "态1:残弹文本区域没有画出中性亮文本(文本没渲染出来?)")
	_check(gold1 == 0, "态1:满弹不该是金色(金色只表「弹夹见底」;实测金色像素 %d)" % gold1)
	_check(accent1 == 0, "态1:非换弹态进度条区不该有强调青像素(%d)" % accent1)
	print("[L3-VISUAL] 态1 像素:残弹区亮文本=%d 金色=%d 进度条区青=%d" % [bright1, gold1, accent1])

	# ── 态2:装填中(进度中段 0.5)────────────────────────────────────
	_w.mag_ammo = 3
	_w.start_reload()
	_w.tick(RELOAD_SAMPLE_DT)      # 手动推进:tick 是武器帧逻辑唯一入口,不依赖真实时间
	await _frames(2)
	_check(_w.is_reloading(), "态2:start_reload()+tick(0.5) 后未处于装填中")
	var prog := _w.reload_progress()
	_check(prog > 0.0 and prog < 1.0, "态2:换弹进度 %.3f 不在 (0,1) 中段" % prog)
	var img2 := await _shot("_l3_2_reloading.png")
	_check(_hud._ammo_label.text == "装填中…", "态2:文本应为「装填中…」(实际「%s」)" % _hud._ammo_label.text)
	_check(_hud._reload_bar.visible, "态2:换弹进度条不可见")
	_check(_hud._bar_back.visible, "态2:换弹进度条底板不可见")
	_check(absf(_hud._reload_bar.size.x - HUD.WEAPON_ICON_W * prog) < 2.0,
			"态2:进度条长度 %.1f 与进度 %.2f 不符(期望 %.1f)" % [
				_hud._reload_bar.size.x, prog, HUD.WEAPON_ICON_W * prog])
	var gold2 := _gold_in(img2, _hud._ammo_label)
	var gold_bar2 := _gold_in(img2, _hud._reload_bar)
	var accent2 := _accent_in(img2, _hud._reload_bar)
	_check(gold2 > 0, "态2:残弹已见底(3/12)却没转金 —— 「低弹量」警告没画出来")
	_check(accent2 > 0, "态2:进度条区域没有画出强调青像素(进度条没渲染出来?)")
	_check(gold_bar2 == 0, "态2:进度条不该是金色(金色只留给残弹见底;实测 %d)" % gold_bar2)
	print("[L3-VISUAL] 态2 像素:残弹区金色=%d 进度条区青=%d 金=%d 进度=%.2f 条长=%.1f" % [
			gold2, accent2, gold_bar2, prog, _hud._reload_bar.size.x])

	# ── 态3:残弹低位 1/12 ───────────────────────────────────────────
	_w.tick(2.0)                   # 推进到底:补满并退出装填
	_check(not _w.is_reloading(), "态3:tick(2.0) 后仍在装填(装填收尾坏了?)")
	_check(_w.mag_ammo == 12, "态3:装填收尾未补满(实际 %d)" % _w.mag_ammo)
	_w.mag_ammo = 1                # 残留 1 发
	await _frames(2)
	var img3 := await _shot("_l3_3_low.png")
	_check(_hud._ammo_label.text == "1/12", "态3:文本应为「1/12」(实际「%s」)" % _hud._ammo_label.text)
	_check(_hud._ammo_label.visible, "态3:残弹标签不可见")
	_check(not _hud._reload_bar.visible, "态3:非换弹态进度条不应可见")
	var gold3 := _gold_in(img3, _hud._ammo_label)
	var accent3 := _accent_in(img3, _hud._reload_bar)
	_check(gold3 > 0, "态3:残弹见底(1/12)却没转金 —— 「低弹量」警告没画出来")
	_check(accent3 == 0, "态3:非换弹态进度条区不该有强调青像素(%d)" % accent3)
	print("[L3-VISUAL] 态3 像素:残弹区金色=%d 进度条区青=%d" % [gold3, accent3])

	# ── 三态必须真的画得不一样(否则"改了状态但画面没变")──────────────
	var d12 := _diff_in_hud_region(img1, img2)
	var d13 := _diff_in_hud_region(img1, img3)
	_check(d12 > 50, "态1→态2 HUD 区像素几乎没变(差异 %d):换弹进度条/文本没画出来?" % d12)
	_check(d13 > 50, "态1→态3 HUD 区像素几乎没变(差异 %d):残弹数字变化没画出来?" % d13)
	print("[L3-VISUAL] HUD 区像素差异:态1→态2 = %d,态1→态3 = %d" % [d12, d13])

	_finish()


# 截图:帧驱动(等两帧确保画完),存 PNG 并返回 Image 供数值断言
func _shot(png_name: String) -> Image:
	await get_tree().process_frame
	await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	if img == null:
		_failures.append("截图 %s 失败(get_image 返回 null —— 是不是误加了 --headless?)" % png_name)
		return Image.new()
	var path := OUT_DIR.path_join(png_name)
	var err := img.save_png(path)
	if err != OK:
		_failures.append("截图 %s 写入失败(err=%d,path=%s)" % [png_name, err, path])
	else:
		print("[L3-VISUAL] 已存 %s  %dx%d" % [
				ProjectSettings.globalize_path(path), img.get_width(), img.get_height()])
	return img


# 控件矩形 → 图像像素矩形。stretch/mode=viewport 下逻辑坐标与窗面像素可能不同比例,
# 一律按「图像宽 / 视口逻辑宽」换算,不写死 1.0(改分辨率/缩放后探针不失效)。
func _px_rect(img: Image, ctrl: Control) -> Rect2i:
	var vr := get_viewport().get_visible_rect().size
	var s := float(img.get_width()) / maxf(vr.x, 1.0)
	var r := ctrl.get_global_rect()
	var x0 := clampi(int(r.position.x * s), 0, maxi(img.get_width() - 1, 0))
	var y0 := clampi(int(r.position.y * s), 0, maxi(img.get_height() - 1, 0))
	var x1 := clampi(int((r.position.x + r.size.x) * s), 0, img.get_width())
	var y1 := clampi(int((r.position.y + r.size.y) * s), 0, img.get_height())
	return Rect2i(x0, y0, maxi(x1 - x0, 0), maxi(y1 - y0, 0))


# 矩形内"金色像素"(UiFactory.C_WARN = 0.95,0.85,0.55)计数。背景深灰,不误判。
# ★ 2026-09-13 语义收窄:金色**只**表示「弹夹见底」,不再兼任满弹常态色与装填进度色
#   (原先三者同色 = 没有警告)。故本探针同时断言「该金的要金」与「不该金的一个都不能有」。
func _gold_in(img: Image, ctrl: Control) -> int:
	return _color_in(img, ctrl, func(c: Color) -> bool:
		return c.r > 0.6 and c.g > 0.5 and c.r > c.b + 0.15)


# 矩形内"强调青像素"(UiFactory.C_ACCENT = 0.349,0.851,0.902)计数:换弹进度条用色。
func _accent_in(img: Image, ctrl: Control) -> int:
	return _color_in(img, ctrl, func(c: Color) -> bool:
		return c.g > 0.6 and c.b > 0.6 and c.b > c.r + 0.15)


# 矩形内"中性亮文本像素"(UiFactory.C_TEXT = 0.878,0.914,0.949)计数:满弹常态色。
# 判据排除金色(r-b≈0.4)与强调青(b-r≈0.55),故三种语义互不误计。
func _bright_in(img: Image, ctrl: Control) -> int:
	return _color_in(img, ctrl, func(c: Color) -> bool:
		return c.r > 0.6 and c.g > 0.6 and c.b > 0.6 and absf(c.r - c.b) < 0.12)


func _color_in(img: Image, ctrl: Control, pred: Callable) -> int:
	if img == null or img.get_width() == 0 or ctrl == null:
		return 0
	var rc := _px_rect(img, ctrl)
	var n := 0
	for y in range(rc.position.y, rc.position.y + rc.size.y):
		for x in range(rc.position.x, rc.position.x + rc.size.x):
			if pred.call(img.get_pixel(x, y)):
				n += 1
	return n


# 左下角 HUD 区(剪影/名称/残弹/进度条都在这一块)的逐像素差异计数
func _diff_in_hud_region(a: Image, b: Image) -> int:
	if a.get_width() == 0 or b.get_width() == 0 or a.get_width() != b.get_width():
		return 0
	var x0 := 0
	var x1 := mini(int(a.get_width() * 0.30), a.get_width())
	var y0 := maxi(a.get_height() - 180, 0)
	var y1 := a.get_height()
	var n := 0
	for y in range(y0, y1):
		for x in range(x0, x1):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			if absf(ca.r - cb.r) > 0.05 or absf(ca.g - cb.g) > 0.05 or absf(ca.b - cb.b) > 0.05:
				n += 1
	return n


func _frames(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_failures.append(msg)


func _finish() -> void:
	if _failures.is_empty():
		print("KH L3 VISUAL: ALL-OK")
		get_tree().quit(0)
	else:
		print("KH L3 VISUAL: FAIL | " + "; ".join(_failures))
		get_tree().quit(1)
