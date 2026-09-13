extends Control

# L4 视觉验收探针(**必须带真实渲染,不能加 --headless** —— headless 下 get_image() 返回 null)。
# 跑法:
#   "$GODOT" --path . --quit-after 900 res://tests/kh_l4_visual_probe.tscn
# 把 L4 换装过的三张界面定格成 PNG 交给控制者读图,同时打数值断言(可当 CI 用):
#   _l4_1_mainmenu.png    主菜单(标题 + 5 个按钮 + 版本号,浮现动画跑完的稳定态)
#   _l4_2_pause.png       暂停菜单(继续 / 回到主菜单;底下一块纯色假装游戏画面)
#   _l4_3_matchmaking.png 匹配界面(**T6 评审点名**:房间行字号从 KH 的 24 抬到 32 后
#                         字宽 +33%,行最小宽 600 / 滚动区 640,长昵称可能横向溢出;
#                         这页不拍下来,这类版式问题只能靠用户真机撞到)
# PNG 落 res://.superpowers/sdd/(该目录自带 .gitignore = *,不入库)。
#
# 三张图的数值腿:
#  · 每张图与「纯背景基线」的逐像素差异 > 阈值(证明界面真的画出来了,不是空屏);
#  · 主菜单:标题/版本号/5 个按钮各自矩形内都有足够亮像素(证明显浮动画真的跑完了);
#  · 暂停:标题与两个按钮矩形内亮像素 > 0;
#  · 匹配:房间行按钮矩形内亮像素 > 0,并**打印**房间行的实际文本宽度 vs 行宽 600
#    (T6 那条溢出的疑点,数值留给控制者判断,不在这里判死活);
#  · 三张图两两不同(证明"切了界面"而不是"拍了三张一样的")。
#
# 两条 L2/L3 踩过的坑,这里照旧避开:
#  1) 截瞬态一律**帧驱动**(await process_frame / 轮询到条件成立),不用真实时间等待 ——
#     冷机/慢机不抖。主菜单的浮现 tween 是真实时间驱动的,故用「轮询到全不透明」而不是
#     "等固定几帧"。
#  2) --quit-after 的单位是**帧**不是秒(故给到 900 帧;60 会被几秒掐断)。
#
# ⚠ 不碰公网:实例化匹配场景前把 PvpSession.server_address 改成 127.0.0.1(本机无服务端
#   → 快速失败),免得探针为了拍张图对云上大厅发起无谓连接。探针进程随即退出,不必复原。

const OUT_DIR := "res://.superpowers/sdd"
const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"
const MATCHMAKING_SCENE := "res://scenes/matchmaking.tscn"

# 主菜单:期望 6 个模式按钮(单人/多人/大乱斗/设置/版本/退出)—— 多一个少一个都是"菜单换了脸"。
# (原为 5:大乱斗按钮加进来之后漏改,本探针一直红着。)
const EXPECTED_MENU_BUTTONS := 6
# 与纯背景基线的差异下限(step=4 采样,见 _diff_vs)
const DIFF_MIN := 400
# 标题/按钮矩形内的"亮像素"下限(字被画出来才有)
const BRIGHT_MIN := 120

var _failures: Array[String] = []
var _bg: ColorRect = null
var _baseline: Image = null
var _main_menu: Node = null
var _pause: PauseMenu = null
var _match: Node = null


func _ready() -> void:
	# 探针自持确定性:本机 user://settings.cfg 可能被用户改过
	Level0.pvp_mode = false

	var win := get_viewport().get_visible_rect().size
	print("[L4-VISUAL] 窗口可见区 = %s" % str(win))

	# 深色底:三态共用,也是"差异基线"的那块底(证明界面真的画在它上面)
	_bg = ColorRect.new()
	_bg.color = Color(0.07, 0.09, 0.13)
	_bg.position = Vector2.ZERO
	_bg.size = win
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)
	await _frames(2)
	_baseline = await _snap()   # 只入内存,不落盘(落盘的只有三态)
	if _baseline == null or _baseline.get_width() == 0:
		_failures.append("基线截图失败(是不是误加了 --headless?)")
		_finish()
		return

	await _state_main_menu()
	await _state_pause()
	await _state_matchmaking()

	_finish()


# ── 态1:主菜单 ────────────────────────────────────────────────────
func _state_main_menu() -> void:
	var ps: PackedScene = load(MAIN_MENU_SCENE)
	if ps == null:
		_failures.append("%s 载入失败" % MAIN_MENU_SCENE)
		return
	_main_menu = ps.instantiate()
	add_child(_main_menu)
	# 浮现动画:标题先淡入,按钮依次(最后一个 delay≈1.54s + 0.5s),轮询到全不透明为止
	var title := _find_label(_main_menu, "The Cyancular Ruins")
	var buttons := _find_buttons(_main_menu)
	_check(title != null, "态1:找不到标题「The Cyancular Ruins」")
	_check(buttons.size() == EXPECTED_MENU_BUTTONS,
			"态1:模式按钮 %d 个(期望 %d 个:单人/多人/设置/版本/退出)" % [buttons.size(), EXPECTED_MENU_BUTTONS])
	var ver := _find_label_where(_main_menu, func(t: String) -> bool:
		return t.strip_edges() != "" and t != "The Cyancular Ruins" and not t.contains("模"))
	# 帧驱动轮询(不用 create_timer:等的是"状态成立",不是"过了多久")
	var faded := false
	for _i in range(400):
		if _menu_faded(title, buttons):
			faded = true
			break
		await get_tree().process_frame
	_check(faded, "态1:等 400 帧后标题/按钮仍未完全浮现(modulate.a 还没到 1)")
	_check(ver != null, "态1:找不到版本号文本")
	if ver != null:
		print("[L4-VISUAL] 态1 版本号 = 「%s」" % ver.text)

	var img1 := await _shot("_l4_1_mainmenu.png")
	# 数值腿:标题/版本号/每个按钮矩形内都得有亮像素(证明"画出来了"且"全浮现了")
	if title != null:
		_check(_bright_in(img1, title) >= BRIGHT_MIN,
				"态1:标题矩形内亮像素 %d(<%d)——标题没画出来或还在淡入中" % [_bright_in(img1, title), BRIGHT_MIN])
	if ver != null:
		_check(_bright_in(img1, ver) >= 20, "态1:版本号矩形内亮像素过少(版本号没画出来?)")
	for i in buttons.size():
		var b: Button = buttons[i]
		_check(_bright_in(img1, b) >= BRIGHT_MIN,
				"态1:按钮「%s」矩形内亮像素 %d(<%d)" % [b.text.strip_edges(), _bright_in(img1, b), BRIGHT_MIN])
	var d_bg := _diff_vs(img1, _baseline)
	_check(d_bg > DIFF_MIN, "态1:主菜单与纯背景差异只有 %d(界面没画出来?)" % d_bg)
	print("[L4-VISUAL] 态1 按钮 = %s" % str(buttons.map(func(b: Button) -> String: return b.text.strip_edges())))
	print("[L4-VISUAL] 态1 与背景差异 = %d(阈值 %d)" % [d_bg, DIFF_MIN])


# ── 态2:暂停菜单(底下一块纯色假装游戏画面,不必真进 Level0)────────
func _state_pause() -> void:
	if _main_menu != null:
		_main_menu.queue_free()
		_main_menu = null
	await _frames(2)
	# 假游戏画面:一块和菜单底明显不同的纯色(证明暂停层是画在"游戏之上"的)
	var fake := ColorRect.new()
	fake.name = "FakeGame"
	fake.color = Color(0.42, 0.62, 0.70)
	fake.size = get_viewport().get_visible_rect().size
	fake.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(fake)

	_pause = PauseMenu.new(false)   # 单机版:open() 会暂停整棵树(见 pause_menu.gd)
	add_child(_pause)
	await _frames(2)
	_pause.open()
	await _frames(2)

	var label := _find_label(_pause, "—— 已暂停 ——")
	_check(label != null, "态2:找不到标题「—— 已暂停 ——」")
	var buttons := _find_buttons(_pause)
	_check(buttons.size() == 2, "态2:暂停菜单按钮 %d 个(期望 2:继续/回到主菜单)" % buttons.size())
	_check(label != null and label.get_theme_font_size("font_size") == 64,
			"态2:暂停标题字号不是 64(实际 %s)" % str(label.get_theme_font_size("font_size") if label != null else "<无标题>"))
	for b in buttons:
		_check(b.get_theme_font_size("font_size") % 16 == 0,
				"态2:按钮「%s」字号 %d 不是 16 的倍数" % [b.text, b.get_theme_font_size("font_size")])
	print("[L4-VISUAL] 态2 按钮 = %s" % str(buttons.map(func(b: Button) -> String: return b.text.strip_edges())))

	var img2 := await _shot("_l4_2_pause.png")
	if label != null:
		_check(_bright_in(img2, label) >= BRIGHT_MIN,
				"态2:暂停标题矩形内亮像素 %d(<%d)" % [_bright_in(img2, label), BRIGHT_MIN])
	for b in buttons:
		_check(_bright_in(img2, b) >= BRIGHT_MIN,
				"态2:按钮「%s」矩形内亮像素 %d(<%d)" % [b.text.strip_edges(), _bright_in(img2, b), BRIGHT_MIN])
	var d_bg2 := _diff_vs(img2, _baseline)
	_check(d_bg2 > DIFF_MIN, "态2:暂停界面与纯背景差异只有 %d" % d_bg2)
	print("[L4-VISUAL] 态2 与背景差异 = %d(阈值 %d)" % [d_bg2, DIFF_MIN])

	_pause.close()   # 解暂停(单机 open 会冻结整棵树,不解后面几态都不推进)
	await _frames(2)
	_check(not get_tree().paused, "态2:close() 后树仍是暂停态")
	_pause.queue_free()
	_pause = null
	if fake != null:
		fake.queue_free()
	await _frames(2)


# ── 态3:匹配界面(T6 点名的版式风险页)────────────────────────────
func _state_matchmaking() -> void:
	# 不进公网:改指 127.0.0.1(本机无大厅 → 快速失败);探针进程随即退出,不复原
	PvpSession.server_address = "127.0.0.1"
	var ps: PackedScene = load(MATCHMAKING_SCENE)
	if ps == null:
		_failures.append("%s 载入失败" % MATCHMAKING_SCENE)
		return
	_match = ps.instantiate()
	add_child(_match)
	await _frames(4)

	var addr: LineEdit = _match.get("_addr_edit")
	_check(addr != null and addr.text == "127.0.0.1",
			"态3:服务器地址框应显示 127.0.0.1(实际 %s)" % str(addr.text if addr != null else "<无控件>"))
	# 房间列表:真实列表要等大厅应答(本机无大厅),这里直接喂一帧「服务器应答」的形状,
	# 让房间行**真的被建出来**——它才是字号抬到 32 之后有溢出风险的那个控件。
	# 长昵称取真人会用的长度(12 字中文),不是极端值。
	var long_name := "一个很长的昵称玩家名字"
	_match.call("_on_room_list", [
		{"code": "AB12", "players": 1, "names": ["Anon"]},
		{"code": "CD34", "players": 2, "names": [long_name, "Anon"]},
	])
	await _frames(4)
	var rows := _find_buttons(_match)
	var room_rows: Array[Button] = []
	for b in rows:
		if b.text.begins_with("房间"):
			room_rows.append(b)
	_check(room_rows.size() == 2, "态3:房间行 %d 行(喂了 2 个房间,期望 2 行)" % room_rows.size())

	var img3 := await _shot("_l4_3_matchmaking.png")
	for b in room_rows:
		var bright := _bright_in(img3, b)
		_check(bright >= BRIGHT_MIN, "态3:房间行矩形内亮像素 %d(<%d)" % [bright, BRIGHT_MIN])
	# ★ T6 评审的疑点:房间行文本宽度 vs 行最小宽 600(数值只打印不判死,图留给控制者看)
	for b in room_rows:
		var f: Font = b.get_theme_font("font")
		var size := b.get_theme_font_size("font_size")
		if f != null:
			var tw := f.get_string_size(b.text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
			print("[L4-VISUAL] 态3 房间行(字号 %d):文本宽 %.1f / 行最小宽 600 / 滚动区 640 → 余量 %.1f%s" % [
					size, tw, 600.0 - tw, "  ← 溢出!" if tw > 600.0 else ""])
	var d_bg3 := _diff_vs(img3, _baseline)
	_check(d_bg3 > DIFF_MIN, "态3:匹配界面与纯背景差异只有 %d" % d_bg3)
	print("[L4-VISUAL] 态3 与背景差异 = %d(阈值 %d)" % [d_bg3, DIFF_MIN])


# ── 截图与数值工具 ─────────────────────────────────────────────────
# 截图:帧驱动(等两帧确保画完),存 PNG 并返回 Image 供数值断言
func _shot(png_name: String) -> Image:
	await _frames(2)
	var img := await _snap()
	if img == null or img.get_width() == 0:
		_failures.append("截图 %s 失败(get_image 返回 null —— 是不是误加了 --headless?)" % png_name)
		return Image.new()
	var path := OUT_DIR.path_join(png_name)
	var err := img.save_png(path)
	if err != OK:
		_failures.append("截图 %s 写入失败(err=%d,path=%s)" % [png_name, err, path])
	else:
		print("[L4-VISUAL] 已存 %s  %dx%d" % [
				ProjectSettings.globalize_path(path), img.get_width(), img.get_height()])
	return img


func _snap() -> Image:
	await get_tree().process_frame
	await get_tree().process_frame
	var tex := get_viewport().get_texture()
	return tex.get_image() if tex != null else null


# 主菜单浮现是否跑完:标题与全部按钮都已完全不透明
func _menu_faded(title: Label, buttons: Array[Button]) -> bool:
	if title == null or title.modulate.a < 0.99:
		return false
	for b in buttons:
		if b.modulate.a < 0.99:
			return false
	return true


# 与基线图(纯背景)的差异:step=4 采样(整图逐像素在 GDScript 里太慢;采样对"界面
# 画没画出来"这种大面积差异完全够用,阈值见 DIFF_MIN)
func _diff_vs(a: Image, base: Image) -> int:
	if a == null or base == null or a.get_width() == 0 or base.get_width() != a.get_width():
		return 0
	var step := 4
	var n := 0
	for y in range(0, a.get_height(), step):
		for x in range(0, a.get_width(), step):
			var ca := a.get_pixel(x, y)
			var cb := base.get_pixel(x, y)
			if absf(ca.r - cb.r) > 0.05 or absf(ca.g - cb.g) > 0.05 or absf(ca.b - cb.b) > 0.05:
				n += 1
	return n


# 控件矩形 → 图像像素矩形。stretch 下逻辑坐标与窗面像素可能不同比例,一律按
# 「图像宽 / 视口逻辑宽」换算,不写死 1.0(改分辨率/缩放后探针不失效)。
func _px_rect(img: Image, ctrl: Control) -> Rect2i:
	var vr := get_viewport().get_visible_rect().size
	var s := float(img.get_width()) / maxf(vr.x, 1.0)
	var r := ctrl.get_global_rect()
	var x0 := clampi(int(r.position.x * s), 0, maxi(img.get_width() - 1, 0))
	var y0 := clampi(int(r.position.y * s), 0, maxi(img.get_height() - 1, 0))
	var x1 := clampi(int((r.position.x + r.size.x) * s), 0, img.get_width())
	var y1 := clampi(int((r.position.y + r.size.y) * s), 0, img.get_height())
	return Rect2i(x0, y0, maxi(x1 - x0, 0), maxi(y1 - y0, 0))


# 矩形内的"亮像素"计数(像素亮度过半即算):字/描边画出来才有;深底不会误判
func _bright_in(img: Image, ctrl: Control) -> int:
	if img == null or img.get_width() == 0 or ctrl == null:
		return 0
	var rc := _px_rect(img, ctrl)
	var n := 0
	for y in range(rc.position.y, rc.position.y + rc.size.y):
		for x in range(rc.position.x, rc.position.x + rc.size.x):
			var c := img.get_pixel(x, y)
			if (c.r + c.g + c.b) / 3.0 > 0.5:
				n += 1
	return n


# ── 找控件 ────────────────────────────────────────────────────────
func _find_buttons(root: Node) -> Array[Button]:
	var out: Array[Button] = []
	_collect_buttons(root, out)
	return out


func _collect_buttons(n: Node, out: Array[Button]) -> void:
	for c in n.get_children():
		if c is Button:
			out.append(c)
		_collect_buttons(c, out)


func _find_label(root: Node, text: String) -> Label:
	return _find_label_where(root, func(t: String) -> bool: return t == text)


func _find_label_where(root: Node, pred: Callable) -> Label:
	for c in root.get_children():
		if c is Label and bool(pred.call((c as Label).text)):
			return c
		var sub := _find_label_where(c, pred)
		if sub != null:
			return sub
	return null


func _frames(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_failures.append(msg)


func _finish() -> void:
	if _failures.is_empty():
		print("KH L4 VISUAL: ALL-OK")
		get_tree().quit(0)
	else:
		print("KH L4 VISUAL: FAIL | " + "; ".join(_failures))
		get_tree().quit(1)
