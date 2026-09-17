extends Control

# L3 视觉验收探针(**必须带真实渲染,不能加 --headless** —— headless 下 get_image() 返回 null)。
# 跑法:
#   "$GODOT" --path . --quit-after 600 res://tests/kh_l3_visual_probe.tscn
# 把 HUD 换弹玩法的三态定格成 PNG 交给控制者读图,同时打数值断言(可当 CI 用):
#   _l3_1_ammo.png     满弹「12/12」+ 武器剪影 + 名称
#   _l3_2_reloading.png 换弹中(进度条已取消 → 角色旁圆环 + 环心一位小数倒计时)
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
const PLAYER_SCENE := "res://scenes/player/player.tscn"
const RELOAD_SAMPLE_DT := 0.5          # 手动推进的换弹时长(秒):手枪 reload_time=1.0 → 进度 50%

var _failures: Array[String] = []
var _hud: Hud = null
var _w: WeaponBase = null



# hoisted from locals when __ready was split (first assignment kept in place).
var win: Vector2 = Vector2.ZERO
var p: Node = null
var _bg: ColorRect = null   # 探针底色(见 _setup_scene);槽位那一段会临时改成地图色再取一张
var img1: Image = null
var img2: Image = null
var img3: Image = null
var _aborted: bool = false
func _ready() -> void:
	# 每段后查 _aborted:段内原来的 `return` 退出的是**整个函数**,拆完只退出该段。
	await _setup_scene()
	if _aborted:
		return
	# ★ 必须 await:本段内部有 await _shot(),漏了 await 它会挂起后**立刻**往下走进态2
	#   (那里 mag_ammo=3 + start_reload),本段恢复时 HUD 已在"装填中" —— 表现为
	#   态1 全部断言红 + 态1/态2 截图像素完全相同(2026-09-15 实测;是 _ready 拆段重构
	#   漏加的那一个 await,另两段(_capture_reloading / _capture_low_ammo)都在 await)。
	await _capture_full_ammo()
	if _aborted:
		return
	await _capture_reloading()
	if _aborted:
		return
	await _capture_low_ammo()
	if _aborted:
		return
	_assert_states_differ()
	if _aborted:
		return
	await _check_slot_colors()
	if _aborted:
		return

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


# 探针底色(深色)。★ 槽位格子是**半透明**的,画面上看到的颜色 = 格子色按 alpha 混到这层
# 再压上 HUD 底板之后的结果,不等于常量本身 —— 取色断言必须先做这个合成,否则恒红。
const PROBE_BG := Color(0.09, 0.10, 0.13)


# 把 c 按自己的 alpha 混到底色 bg 上(得到不透明的实际像素值)
func _blend_over(c: Color, bg: Color) -> Color:
	var a := c.a
	return Color(c.r * a + bg.r * (1.0 - a), c.g * a + bg.g * (1.0 - a),
			c.b * a + bg.b * (1.0 - a), 1.0)


# 某个槽位格子在屏幕上**实际**会呈现的颜色(格子色 → 底板 → 探针底色)
func _slot_screen_color(c: Color) -> Color:
	var backdrop := _blend_over(WeaponSlots.PLATE_COLOR, PROBE_BG)
	return _blend_over(c, backdrop)


# 某个槽位格子在屏幕上的像素矩形(由控件全局矩形 + 格子常量算出 —— 格子是 _draw 自绘的,
# 没有逐个 Control 可取)
func _slot_cell_rect(slots: WeaponSlots, cell: int) -> Rect2i:
	var r := slots.get_global_rect()
	var col := cell % WeaponSlots.COLS
	var row := cell / WeaponSlots.COLS
	var p := r.position + Vector2(
		WeaponSlots.PAD + col * (WeaponSlots.CELL + WeaponSlots.GAP),
		WeaponSlots.PAD + row * (WeaponSlots.CELL + WeaponSlots.GAP))
	return Rect2i(int(p.x), int(p.y), int(WeaponSlots.CELL), int(WeaponSlots.CELL))


# 矩形内"接近某色"的像素计数(格子是纯色填充,容许截图的极小色差)
func _count_near(img: Image, rc: Rect2i, want: Color, tol: float = 0.06) -> int:
	if img == null or img.get_width() == 0:
		return 0
	var n := 0
	for y in range(maxi(0, rc.position.y), mini(img.get_height(), rc.position.y + rc.size.y)):
		for x in range(maxi(0, rc.position.x), mini(img.get_width(), rc.position.x + rc.size.x)):
			var c := img.get_pixel(x, y)
			if absf(c.r - want.r) < tol and absf(c.g - want.g) < tol and absf(c.b - want.b) < tol:
				n += 1
	return n


# ── 槽位格子三态 ─────────────────────────────────────────────────────
# ★ 这里**只断言"每格是不是它该有的颜色"+"三态两两可区分"**,**不**断言"哪个更醒目":
#   本探针的底是**深色**(见 _setup_scene 的 bg),而实机 HUD 的底板是压在地图浅灰蓝上的
#   `黑 0.1`(≈#6C8790,**浅底**)—— 同一个色在这两种底上的醒目程度是**相反**的,
#   在深底上比"谁更醒目"会把实机上正确的配色判成错的。
#   明度阶梯那条不变量写在 ui_factory.gd 的常量注释里,由人眼看实图确认。
func _check_slot_colors() -> void:
	var slots: WeaponSlots = _hud._slots
	var img := await _shot("l3_slots")
	var full := int(WeaponSlots.CELL * WeaponSlots.CELL)   # 每格总像素数

	var active_n := _count_near(img, _slot_cell_rect(slots, 0), _slot_screen_color(UiFactory.C_SLOT_ACTIVE))
	var filled_n := _count_near(img, _slot_cell_rect(slots, 3), _slot_screen_color(UiFactory.C_SLOT_FILLED))
	var empty_n := _count_near(img, _slot_cell_rect(slots, 7), _slot_screen_color(UiFactory.C_SLOT_EMPTY))
	_check(active_n > full / 2, "手持那把占的格应为深青(命中 %d/%d)" % [active_n, full])
	_check(filled_n > full / 2, "已占据的格应为淡青(命中 %d/%d)" % [filled_n, full])
	_check(empty_n > full / 2, "未占据的格应为淡灰(命中 %d/%d)" % [empty_n, full])

	# ★ 双向:不该是**别的态**的颜色。只判"有青色像素"会把"三态画成同一个色"放过去。
	_check(_count_near(img, _slot_cell_rect(slots, 0), _slot_screen_color(UiFactory.C_SLOT_FILLED)) < full / 10,
		"手持格不得等于已占格颜色(两者必须区分得开)")
	_check(_count_near(img, _slot_cell_rect(slots, 3), _slot_screen_color(UiFactory.C_SLOT_ACTIVE)) < full / 10,
		"已占格不得是手持色")
	_check(_count_near(img, _slot_cell_rect(slots, 7), _slot_screen_color(UiFactory.C_SLOT_FILLED)) < full / 10,
		"空格不得是已占色")
	_check(UiFactory.C_SLOT_EMPTY != UiFactory.C_SLOT_FILLED
			and UiFactory.C_SLOT_FILLED != UiFactory.C_SLOT_ACTIVE
			and UiFactory.C_SLOT_EMPTY != UiFactory.C_SLOT_ACTIVE,
		"槽位三态颜色必须两两不同(配色改重复了肉眼很难发现)")

	# 紧凑排布的**位置**也要钉:5 格武器占 0..4,手持的是它——整段同色,不是只染第一格
	_check(_count_near(img, _slot_cell_rect(slots, 1), _slot_screen_color(UiFactory.C_SLOT_ACTIVE)) > full / 2,
		"手持武器的第二格也该是深青(紧凑排布 = 整段同色)")
	_check(_count_near(img, _slot_cell_rect(slots, 5), _slot_screen_color(UiFactory.C_SLOT_FILLED)) > full / 2,
		"重狙的最后一格(第 6 格)也该是淡青")
	_check(_count_near(img, _slot_cell_rect(slots, 6), _slot_screen_color(UiFactory.C_SLOT_EMPTY)) > full / 2,
		"第 7 格应是空的(1只手枪2格 + 1把重狙4格 = 6 格,后两格空)")

	# ── 再取一张**浅底**的图 ──
	# ★ 实机 HUD 垫的是 `黑 0.1` 压在地图开阔区(≈#78969F,浅灰蓝)上 —— 底板是**浅**的。
	#   本探针默认的深色底会把"浅底上读不出来"这类问题**遮掉**(正是 CLAUDE.md 里
	#   combat_hud_visual_probe 记过的坑:单机 HUD 的 1.9:1 血条就是这么漏掉的)。
	#   这一张不参与断言(两种底上"谁更醒目"的答案是相反的,拿它判会把对的配色判错),
	#   只落盘供**人眼**验收 —— 配色是审美值,以实图为准。
	if _bg != null:
		_bg.color = Color(0.471, 0.588, 0.624)   # = 地图开阔区 #78969F
		await _frames(2)
		await _shot("l3_slots_on_map")
		_bg.color = PROBE_BG
		await _frames(2)
		print("[L3-VISUAL] 已另存浅底版 l3_slots_on_map(仅供人眼配色验收)")


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
	_aborted = true   # 见 _ready 顶部:置位后各段之间就不再往下跑
	if _failures.is_empty():
		print("KH L3 VISUAL: ALL-OK")
		get_tree().quit(0)
	else:
		print("KH L3 VISUAL: FAIL | " + "; ".join(_failures))
		get_tree().quit(1)


func _setup_scene() -> void:
	# 探针自持确定性:本机 user://settings.cfg 可能被用户开着 pvp(换弹恒定开启,无开关)。
	Level0.pvp_mode = false

	# 窗口尺寸实取(不写死:stretch/mode=viewport 下与工程设置解耦,改分辨率探针不失效)。
	# 注意不要给根 Control 赋 size —— 它的锚点是全屏,赋值会被引擎在 _ready 后覆盖并告警。
	win = get_viewport().get_visible_rect().size
	print("[L3-VISUAL] 窗口可见区 = %s" % str(win))

	# 深色底:金色残弹/进度条在暗底上才读得出(也便于统计"金色像素数")
	var bg := ColorRect.new()
	bg.color = PROBE_BG   # ★ 注意:这是**深**底,与实机 HUD 的浅灰蓝底不同,
	#   所以槽位格子的"哪个更醒目"不能在这个背景下断言(实机上判据是反的)。见 _check_slot_colors。
	bg.position = Vector2.ZERO
	bg.size = win
	add_child(bg)
	_bg = bg

	var ps: PackedScene = load(PLAYER_SCENE)
	if ps == null:
		_failures.append("player.tscn 载入失败")
		_finish()
		return
	p = ps.instantiate()
	add_child(p)
	# 冻结玩家物理:换弹进度不受真实物理 tick 推进,只由本探针显式 tick(帧率无关、可复现)
	p.set_physics_process(false)
	p.global_position = Vector2(win.x * 0.5, win.y * 0.62)   # 远离左下角 HUD 区,不干扰像素统计

	# ── 已知背包(必须排在**创建 HUD 之前**)──
	# 用 手枪(2格)+ 重狙(4格)= 6 格 / 2 把,手持的是手枪:
	#   格 0-1 = 手持(深青) · 格 2-5 = 已占(淡青) · 格 6-7 = 空(淡灰)
	# 三段**各占多个格且不重叠**,取色时不会互相串。
	# ★ 单机开局空手之后,player.tscn 直接实例化出来是**没有武器**的(_ready 给空背包),
	#   而下面几段都要 current_weapon() 非空 —— 所以这一段必须排在任何 `_w = ...` 之前。
	p.weapons.set_initial_inventory([1, 3])
	await _frames(4)   # 武器是 call_deferred 入树的,等它 _ready(mag_ammo = mag_size)

	_hud = Hud.new()
	add_child(_hud)    # HUD._ready 从 "player" 组找玩家并接管剪影/名称/残弹显示
	await _frames(3)

	_w = p.weapons.current_weapon()
	if _w == null or _hud == null or _hud._ammo_label == null:
		_failures.append("前置失败:HUD 未建起残弹标签(weapon=%s)" % str(_w))
		_finish()
		return
	print("[L3-VISUAL] HUD 残弹标签全局矩形 = %s" % str(_hud._ammo_label.get_global_rect()))

	if _hud._slots == null:
		_failures.append("前置失败:HUD 未建起武器槽位格子")
		_finish()
		return

func _capture_full_ammo() -> void:
	# ── 态1:满弹 12/12 ──────────────────────────────────────────────
	_check(_w.mag_ammo == 12, "态1:开局残弹应 12(实际 %d)" % _w.mag_ammo)
	img1 = await _shot("_l3_1_ammo.png")
	_check(_hud._ammo_label.visible, "态1:残弹标签不可见")
	_check(_hud._ammo_label.text == "12/12", "态1:文本应为「12/12」(实际「%s」)" % _hud._ammo_label.text)
	_check(_hud._weapon_icon.texture != null, "态1:武器剪影贴图为空")
	_check(_hud._weapon_name.text == "手枪", "态1:武器名应为「手枪」(实际「%s」)" % _hud._weapon_name.text)
	# ★ 换弹进度条与"装填中…"文案已取消(用户 2026-09-16:改用角色旁的圆环倒计时)。
	#   这两条改成钉"它们真的不在了",免得日后有人又加回一条 HUD 换弹条。
	_check(_hud.get("_reload_bar") == null, "态1:HUD 上不该再有换弹进度条节点(已改角色旁圆环)")
	var bright1 := _bright_in(img1, _hud._ammo_label)
	var gold1 := _gold_in(img1, _hud._ammo_label)
	var accent1 := 0   # 进度条已删,这里没有它的矩形可量
	_check(bright1 > 0, "态1:残弹文本区域没有画出中性亮文本(文本没渲染出来?)")
	_check(gold1 == 0, "态1:满弹不该是金色(金色只表「弹夹见底」;实测金色像素 %d)" % gold1)

	print("[L3-VISUAL] 态1 像素:残弹区亮文本=%d 金色=%d 进度条区青=%d" % [bright1, gold1, accent1])

func _capture_reloading() -> void:
	# ── 态2:装填中(进度中段 0.5)────────────────────────────────────
	_w.mag_ammo = 3
	_w.start_reload()
	_w.tick(RELOAD_SAMPLE_DT)      # 手动推进:tick 是武器帧逻辑唯一入口,不依赖真实时间
	await _frames(2)
	_check(_w.is_reloading(), "态2:start_reload()+tick(0.5) 后未处于装填中")
	var prog := _w.reload_progress()
	_check(prog > 0.0 and prog < 1.0, "态2:换弹进度 %.3f 不在 (0,1) 中段" % prog)
	# ★ 探针冻了玩家物理 → `_update_reload_ring` 不跑,得自己推一拍;
	#   **必须在取图之前**(第一版加在断言里,结果断言绿了、PNG 里却没环)。
	p._update_reload_ring()
	img2 = await _shot("_l3_2_reloading.png")
	# ★ 换弹中**不再**改文案(用户 2026-09-16 取消"装填中…"),恒显示残弹/满弹。
	_check(_hud._ammo_label.text == "%d/%d" % [_w.mag_ammo, _w.mag_size],
			"态2:换弹中文本应仍是残弹/满弹(实际「%s」)" % _hud._ammo_label.text)
	# 进度改由**角色旁的圆环**表达(ui/reload_ring.gd,挂玩家身上)——这里验它在、且亮着
	var ring = p.get("_reload_ring")
	_check(ring != null and is_instance_valid(ring), "态2:玩家身上应有换弹圆环节点")
	p._update_reload_ring()   # ★ 探针冻了玩家物理,_update_reload_ring 不跑,得自己推一拍
	_check(ring != null and bool(ring.visible), "态2:换弹中圆环应可见")
	var gold2 := _gold_in(img2, _hud._ammo_label)
	# ★ 进度条已删(改角色旁圆环),原先那两条"进度条区不许有金/青像素"的断言随之作废 ——
	#   留下的只有"残弹见底要转金"这一条 HUD 语义。
	_check(gold2 > 0, "态2:残弹已见底(3/12)却没转金 —— 「低弹量」警告没画出来")
	print("[L3-VISUAL] 态2 像素:残弹区金色=%d 进度=%.2f(圆环) 圆环可见=%s" % [
			gold2, prog, str(ring != null and bool(ring.visible))])

func _capture_low_ammo() -> void:
	# ── 态3:残弹低位 1/12 ───────────────────────────────────────────
	_w.tick(2.0)                   # 推进到底:补满并退出装填
	_check(not _w.is_reloading(), "态3:tick(2.0) 后仍在装填(装填收尾坏了?)")
	_check(_w.mag_ammo == 12, "态3:装填收尾未补满(实际 %d)" % _w.mag_ammo)
	_w.mag_ammo = 1                # 残留 1 发
	await _frames(2)
	img3 = await _shot("_l3_3_low.png")
	_check(_hud._ammo_label.text == "1/12", "态3:文本应为「1/12」(实际「%s」)" % _hud._ammo_label.text)
	_check(_hud._ammo_label.visible, "态3:残弹标签不可见")
	_check(not _hud._reload_bar.visible, "态3:非换弹态进度条不应可见")
	var gold3 := _gold_in(img3, _hud._ammo_label)
	var accent3 := _accent_in(img3, _hud._reload_bar)
	_check(gold3 > 0, "态3:残弹见底(1/12)却没转金 —— 「低弹量」警告没画出来")
	_check(accent3 == 0, "态3:非换弹态进度条区不该有强调青像素(%d)" % accent3)
	print("[L3-VISUAL] 态3 像素:残弹区金色=%d 进度条区青=%d" % [gold3, accent3])

func _assert_states_differ() -> void:
	# ── 三态必须真的画得不一样(否则"改了状态但画面没变")──────────────
	var d12 := _diff_in_hud_region(img1, img2)
	var d13 := _diff_in_hud_region(img1, img3)
	_check(d12 > 50, "态1→态2 HUD 区像素几乎没变(差异 %d):换弹进度条/文本没画出来?" % d12)
	_check(d13 > 50, "态1→态3 HUD 区像素几乎没变(差异 %d):残弹数字变化没画出来?" % d13)
	print("[L3-VISUAL] HUD 区像素差异:态1→态2 = %d,态1→态3 = %d" % [d12, d13])