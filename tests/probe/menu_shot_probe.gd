extends Control

# 主菜单 / 设置页 **取图探针** —— 「窗口与显示设置」批次 Task 0 的裁决证据生成器。
#
# 跑法(★★ 必须**不带** `--headless`:`tests/probe/hue_tint_probe.gd:4` 记着 headless 下
# `get_viewport().get_texture().get_image()` 返回 null ⇒ 量不到像素):
#
#   "$GODOT" --path . --quit-after 3600 --resolution 1280x960 \
#       res://tests/probe/menu_shot_probe.tscn \
#       -- .superpowers/sdd/<批次>/shots/<主菜单名>.png \
#          .superpowers/sdd/<批次>/shots/<设置页名>.png
#
# ★ 输出路径**由调用方在 `--` 之后给**(本探针不写死文件名),支持 `res://` / `user://` /
#   绝对原生路径三种写法,父目录不存在时会建。取图手法照仓内既有那套
#   (`get_viewport().get_texture().get_image()` + `save_png`,见 `kh_l4_visual_probe.gd:248-268`)。
#
# ★★ 为什么本探针**多**走一步「取屏幕上那块窗口的像素」,而不是只存视口纹理:
#   在 `stretch/mode="viewport"` 下**根视口的纹理是"缩放前"的那整块 1920×1440 画布** ——
#   把它存成 PNG 恰好**看不见**本次要判的那件事(整块画布缩放/放大到窗口的那一步)。
#   ⇒ 两种 mode 一律取"屏幕上窗口那块的像素":两张图**同尺寸、同为"用户看到的样子"**,
#   可以直接并排比。OS 级取屏失败时才回落到视口纹理,且**回落事实进日志与退出码**
#   (不回落成静默的"看起来也存了图")。
#
# ★★ 那"缩放到窗口的那一步"到底是什么(2026-10-04 本任务实测,别再照抄"发虚"这个猜想):
#   把 1:1 那张设置页(1920×1440)分别按 NEAREST / BILINEAR 缩到 1280×960,与 viewport 模式下
#   **真截到的** 1280×960 比 —— 平均绝对差 NEAREST=0.00004、BILINEAR=0.01362(差 300 倍),
#   两者中间色占比也逐位相同 ⇒ 4.7.1 上这条 blit 走的是**最近邻**。
#   后果:非整数缩放是**丢/重复源像素**(笔画断、粗细不均),**不是**线性滤波那种发虚。
#   ★ 覆盖上限:只在 0.667× (窗口 1280×960) 上量过;1:1 时两种 mode 逐字节相同(另见下面 1:1 对照),
#     其他比例未实测。
#
# ★ 为什么这里**不是**守卫:本探针不判"数值对不对",只负责"把那一刻的窗口像素落成 PNG
#   并把环境读数打全";判据是**人看那几张图**。唯一会红的是"图没取到/没写成功/页面没就绪",
#   那是证据链断了,不是版式判据。
#
# ★ 已知边界(照实登记):
#   1. OS 级取屏抓的是**屏幕上那块矩形**,若窗口被别的窗口压住,抓到的就是压住它的东西
#      —— 本探针只看"取到的尺寸对不对 + 自己存的图",**分辨不出遮挡**;
#   2. `screen_get_image_rect` 的坐标系与 `window_get_position/size` 在 Windows 上是否
#      逐像素对齐(标题栏算不算在内)由**引擎实现**决定 —— 本探针把实际取到的尺寸打进日志,
#      版式对不对仍然只能看图;
#   3. 主菜单背景是一段**随时间漂移**的镜头(固定种子,不是固定相位)⇒ 两次运行的同名图
#      **不会逐像素相同**;要逐像素对比得另找办法(本探针不负责)。

const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"
const SETTINGS_SCENE := "res://scenes/settings_menu.tscn"
# 主菜单要等两件事:① 背景材质(运行时烘 4800×3200 的地形图 + shader)挂上;
# ② 标题与各按钮的浮现动画跑完(最后一个 delay≈1.54s + 0.5s)。60fps 下约 150 帧,给足 900。
const READY_MAX_FRAMES := 900
const SETTLE_FRAMES := 3      # 就绪后再等几帧,让本帧的绘制真的落到屏幕上
# 取屏自证的下限(见 `_screen_selfcheck`):屏幕那块缩回逻辑尺寸后与根视口纹理的 16×16 粗差。
# 同内容实测 ≈0.00x,**被别的窗口压住**时是这个量级的几十倍(本任务真踩过一次:抓到了浏览器)
const SCREEN_MATCH_MAX := 0.08

var _failures: Array[String] = []
var _shots := 0


func _ready() -> void:
	_report_env()
	var outs := _out_paths()
	if outs.size() < 2:
		_fail("`--` 之后要两个输出路径(主菜单 PNG / 设置页 PNG),实得 %d 个:%s"
				% [outs.size(), str(outs)])
		_finish()
		return
	await _shot_main_menu(outs[0])
	await _shot_settings(outs[1])
	_finish()


# ── 环境读数:两种 mode 的图要能并排比,前提是"这次的配置"写在日志里 ─────────
func _report_env() -> void:
	var w := get_window()
	print("[MENU-SHOT] 引擎 = %s" % str(Engine.get_version_info().get("string", "?")))
	print("[MENU-SHOT] 工程 stretch: mode=%s aspect=%s scale_mode=%s" % [
		str(ProjectSettings.get_setting("display/window/stretch/mode")),
		str(ProjectSettings.get_setting("display/window/stretch/aspect")),
		str(ProjectSettings.get_setting("display/window/stretch/scale_mode"))])
	print("[MENU-SHOT] 运行时 content_scale: size=%s mode=%d aspect=%d" % [
		str(w.content_scale_size), w.content_scale_mode, w.content_scale_aspect])
	print("[MENU-SHOT] 窗口 size=%s pos=%s  逻辑可见区=%s  屏幕=%s" % [
		str(DisplayServer.window_get_size()), str(DisplayServer.window_get_position()),
		str(get_viewport().get_visible_rect().size), str(DisplayServer.screen_get_size())])
	print("[MENU-SHOT] 用户参数 = %s" % str(OS.get_cmdline_user_args()))
	_report_geometry()


# ── 窗口几何:窗口/屏幕/可用区三者的关系决定"取到的是什么",必须随每张图落进日志 ──
# ★ 这三行是控制者点名要的:用来**定罪或排除**"窗口比屏幕还高 ⇒ 被 OS 钳位 ⇒ 看着既不
#   全屏也不居中"。本机屏幕是 2560×1600(不是 1080p)⇒ 1920×1440 的窗口**放得下**,
#   这一条应被排除;读数写在日志里,别靠猜。
func _report_geometry() -> void:
	var screen := DisplayServer.window_get_current_screen()
	var win := DisplayServer.window_get_size()
	var pos := DisplayServer.window_get_position()
	var usable := DisplayServer.screen_get_usable_rect(screen)
	var base := get_viewport().get_visible_rect().size
	print("[geo] 屏幕=%s 可用区=%s" % [DisplayServer.screen_get_size(screen), usable])
	print("[geo] 窗口尺寸=%s 位置=%s 模式=%d" % [win, pos, DisplayServer.window_get_mode()])
	print("[geo] 窗口比屏幕高? %s  (高差 %d px)" % [
		win.y > DisplayServer.screen_get_size(screen).y,
		win.y - DisplayServer.screen_get_size(screen).y])
	print("[geo] 窗口比**可用区**高? %s (高差 %d px;可用区已扣掉任务栏)" % [
		win.y > usable.size.y, win.y - usable.size.y])
	print("[geo] 窗口整块在屏幕内? %s(越界量 x=%d y=%d)" % [
		pos.x >= 0 and pos.y >= 0 and pos.x + win.x <= DisplayServer.screen_get_size(screen).x
				and pos.y + win.y <= DisplayServer.screen_get_size(screen).y,
		maxi(pos.x + win.x - DisplayServer.screen_get_size(screen).x, 0),
		maxi(pos.y + win.y - DisplayServer.screen_get_size(screen).y, 0)])
	# 真实内容缩放:`aspect="keep"` 取两轴比的**较小者**,余下是黑边(不是等比拉伸)。
	var s := minf(win.x / maxf(base.x, 1.0), win.y / maxf(base.y, 1.0))
	var content := Vector2(base.x * s, base.y * s)
	print("[geo] 逻辑基准=%s ⇒ keep 内容缩放=%.4f 内容区=%s 黑边左右共 %d px / 上下共 %d px" % [
		str(base), s, str(content), win.x - int(content.x), win.y - int(content.y)])


# ── 态1:主菜单 ────────────────────────────────────────────────────────────
func _shot_main_menu(out_path: String) -> void:
	var ps := load(MAIN_MENU_SCENE) as PackedScene
	if ps == null:
		_fail("载入失败:%s" % MAIN_MENU_SCENE)
		return
	var menu: Node = ps.instantiate()
	add_child(menu)

	var bg := _find_by_name(menu, "Bg") as ColorRect
	var title := _find_label(menu, "The Cyancular Ruins")
	var buttons := _all_buttons(menu)

	var waited := -1
	for i in range(READY_MAX_FRAMES):
		if _menu_ready(bg, title, buttons):
			waited = i
			break
		await get_tree().process_frame
	if waited < 0:
		_fail("主菜单等 %d 帧仍未就绪(背景材质=%s / 标题 a=%s / 按钮 %d 个 ⇒ 会截到没画完的样子)"
				% [READY_MAX_FRAMES, str(bg != null and bg.material != null),
				str(snappedf(title.modulate.a, 0.01) if title != null else "<无标题>"), buttons.size()])
	else:
		print("[MENU-SHOT] 主菜单就绪:等了 %d 帧;背景材质已挂=%s 按钮 %d 个=%s" % [
			waited, str(bg != null and bg.material != null), buttons.size(),
			str(buttons.map(func(b: Button) -> String: return b.text.strip_edges()))])
	await _capture(out_path, "主菜单")

	menu.queue_free()
	await _frames(2)


# 就绪判据两条都成立:背景材质挂上 + 标题与全部按钮完全不透明(浮现跑完)
func _menu_ready(bg: ColorRect, title: Label, buttons: Array[Button]) -> bool:
	if bg == null or bg.material == null:
		return false
	if title == null or title.modulate.a < 0.99:
		return false
	if buttons.is_empty():
		return false
	for b in buttons:
		if b.modulate.a < 0.99:
			return false
	return true


# ── 态2:设置页 ────────────────────────────────────────────────────────────
func _shot_settings(out_path: String) -> void:
	var ps := load(SETTINGS_SCENE) as PackedScene
	if ps == null:
		_fail("载入失败:%s" % SETTINGS_SCENE)
		return
	var page: Node = ps.instantiate()
	add_child(page)

	# 键位表是 `_ready` 里**动态填**的那一块(骨架里只有静态部分)⇒ 它填完 = 页面建完。
	var grid := _find_by_name(page, "BindGrid")
	var waited := -1
	for i in range(120):
		if grid != null and grid.get_child_count() > 0:
			waited = i
			break
		await get_tree().process_frame
	if waited < 0:
		_fail("设置页等 120 帧后键位表仍是空的(BindGrid=%s,子节点=%d)"
				% [str(grid != null), grid.get_child_count() if grid != null else -1])
	else:
		print("[MENU-SHOT] 设置页就绪:等了 %d 帧;键位表 %d 个子节点;标签样例=%s" % [
			waited, grid.get_child_count(), str(_sample_labels(page))])
	await _capture(out_path, "设置页")

	page.queue_free()
	await _frames(2)


# ── 取图:优先"屏幕上窗口那块",失败才回落视口纹理 ──────────────────────────
func _capture(out_path: String, tag: String) -> void:
	await _frames(SETTLE_FRAMES)

	var mode := str(ProjectSettings.get_setting("display/window/stretch/mode"))
	var win_pos := DisplayServer.window_get_position()
	var win_size := DisplayServer.window_get_size()
	var img: Image = null
	var how := ""

	# ① 首选:屏幕裁窗(= 用户眼睛看到的那块)
	var shot := DisplayServer.screen_get_image_rect(Rect2i(win_pos, win_size))
	if shot is Image and (shot as Image).get_width() > 0:
		img = shot
		how = "屏幕裁窗(窗口 pos=%s size=%s)" % [str(win_pos), str(win_size)]
		_screen_selfcheck(shot, tag)

	# ② 回落:根视口纹理(`viewport` 模式下是**放大前**的画布 ⇒ 看不见缩放发虚)
	if img == null:
		var tex := get_viewport().get_texture()
		img = tex.get_image() if tex != null else null
		if img != null and img.get_width() > 0:
			how = "视口纹理(回落!看不到窗口缩放那一步)"
	if img == null or img.get_width() == 0:
		_fail("%s 取图失败:屏幕裁窗与视口纹理都拿不到像素(是不是误加了 --headless?)" % tag)
		return
	if not how.begins_with("屏幕裁窗"):
		_fail("%s 只拿到视口纹理(%dx%d),没拿到屏幕上的窗口像素 ⇒ 这张图**不能**用来判缩放发虚"
				% [tag, img.get_width(), img.get_height()])

	var abs_path := _abs_path(out_path)
	_ensure_dir(abs_path)
	var err := img.save_png(abs_path)
	if err != OK:
		_fail("%s 写入失败 err=%d path=%s" % [tag, err, abs_path])
		return
	_shots += 1
	# ★ 报"真实内容缩放"(keep 取两轴较小者),**不是** 图宽÷逻辑宽 —— 后者在 keep 有黑边时
	#   会把边也算进去(2560×1600 全屏下那算式给 1.333,而真实内容是 1.111 + 左右黑边)。
	var base := get_viewport().get_visible_rect().size
	var win := DisplayServer.window_get_size()
	var scale_keep := minf(win.x / maxf(base.x, 1.0), win.y / maxf(base.y, 1.0))
	print("[MENU-SHOT] 已存 %s(%s,mode=%s)图=%dx%d 逻辑=%s 内容缩放=%.4f" % [
		tag, how, mode, img.get_width(), img.get_height(), str(base), scale_keep])
	print("[MENU-SHOT]   路径 = %s" % abs_path)


# ── 取屏自证:屏幕那块**真的是我们的窗口**吗 ────────────────────────────────
# ★★ 为什么非要这一条:OS 级取屏抓的是"屏幕上那块矩形",**窗口被别的窗口压住时抓到的是压住它的
#   东西**,而文件名/日志照旧写着"设置页" —— 2026-10-04 本任务真踩过一次(抓到浏览器里的文档页,
#   图看着完全正常,只是**不是我们的游戏**)。这条把它变成一条会红的失败,而不是一张假证据。
# 手法:屏幕那块按 `aspect="keep"` 的内容区裁出来、缩回逻辑尺寸,与**根视口纹理**做 16×16 粗比。
#   ★ 它测不到:只压住一小块(粗比会被整图摊薄)、以及"游戏自己画错了"。
func _screen_selfcheck(screen_img: Image, tag: String) -> void:
	var tex := get_viewport().get_texture()
	var canvas := tex.get_image() if tex != null else null
	if canvas == null or canvas.get_width() == 0:
		return     # 视口纹理都拿不到(多半是 headless):上面那条失败已经报过,别重复报
	var base := get_viewport().get_visible_rect().size
	var win := Vector2(DisplayServer.window_get_size())
	var s := minf(win.x / maxf(base.x, 1.0), win.y / maxf(base.y, 1.0))
	var content := Vector2i(base * s)
	var off := Vector2i((win - Vector2(content)) * 0.5)
	var r := Rect2i(off, content).intersection(Rect2i(Vector2i.ZERO, screen_img.get_size()))
	if r.size.x <= 0 or r.size.y <= 0:
		_fail("%s 取屏自证:内容区算出来是空的(win=%s base=%s)" % [tag, str(win), str(base)])
		return
	var crop := screen_img.get_region(r)
	crop.resize(canvas.get_width(), canvas.get_height(), Image.INTERPOLATE_BILINEAR)
	var d := _coarse_diff(crop, canvas)
	print("[MENU-SHOT] 取屏自证 %s:屏幕 vs 视口纹理 16×16 粗差=%.4f(阈值 %.2f,%s)" % [
		tag, d, SCREEN_MATCH_MAX, "通过" if d <= SCREEN_MATCH_MAX else "★不通过"])
	if d > SCREEN_MATCH_MAX:
		_fail("%s 取屏自证不通过(粗差 %.4f > %.2f):屏幕那块**不是我们的窗口**(被别的窗口压住了?加 `--always-on-top` 再跑)"
				% [tag, d, SCREEN_MATCH_MAX])


func _coarse_diff(a: Image, b: Image) -> float:
	var ca: Image = a.duplicate()
	ca.resize(16, 16, Image.INTERPOLATE_BILINEAR)
	var cb: Image = b.duplicate()
	cb.resize(16, 16, Image.INTERPOLATE_BILINEAR)
	var s := 0.0
	for y in 16:
		for x in 16:
			var pa := ca.get_pixel(x, y)
			var pb := cb.get_pixel(x, y)
			s += absf(pa.r - pb.r) + absf(pa.g - pb.g) + absf(pa.b - pb.b)
	return s / (16.0 * 16.0 * 3.0)


# ── 命令行:输出路径 ───────────────────────────────────────────────────────
func _out_paths() -> Array[String]:
	var out: Array[String] = []
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):     # 本探针不认开关;留给将来(现在一律当路径)
			continue
		out.append(a)
	return out


func _abs_path(p: String) -> String:
	if p.begins_with("res://") or p.begins_with("user://"):
		return ProjectSettings.globalize_path(p)
	return p


func _ensure_dir(abs_path: String) -> void:
	var dir := abs_path.get_base_dir()
	if dir.is_empty() or DirAccess.dir_exists_absolute(dir):
		return
	var err := DirAccess.make_dir_recursive_absolute(dir)
	if err != OK:
		_fail("建目录失败 err=%d dir=%s" % [err, dir])


# ── 小工具 ────────────────────────────────────────────────────────────────
func _frames(n: int) -> void:
	for _i in n:
		await get_tree().process_frame


func _find_by_name(root: Node, want: String) -> Node:
	if root.name == want:
		return root
	for c in root.get_children():
		var hit := _find_by_name(c, want)
		if hit != null:
			return hit
	return null


func _find_label(root: Node, text: String) -> Label:
	for l in _all_labels(root):
		if l.text == text:
			return l
	return null


func _all_labels(root: Node) -> Array[Label]:
	var out: Array[Label] = []
	_collect_labels(root, out)
	return out


func _collect_labels(root: Node, out: Array[Label]) -> void:
	if root is Label:
		out.append(root)
	for c in root.get_children():
		_collect_labels(c, out)


func _all_buttons(root: Node) -> Array[Button]:
	var out: Array[Button] = []
	_collect_buttons(root, out)
	return out


func _collect_buttons(root: Node, out: Array[Button]) -> void:
	if root is Button:
		out.append(root)
	for c in root.get_children():
		_collect_buttons(c, out)


# 页面里的标签样例(证明截到的是"有内容的那一页",不是空场景)
func _sample_labels(root: Node) -> Array[String]:
	var out: Array[String] = []
	for l in _all_labels(root):
		var t := l.text.strip_edges()
		if t != "" and out.size() < 8:
			out.append(t)
	return out


func _fail(why: String) -> void:
	_failures.append(why)
	print("[MENU-SHOT] ✗ " + why)


func _finish() -> void:
	if _failures.is_empty():
		print("MENU SHOT PROBE: OK(%d 张)" % _shots)
		get_tree().quit(0)
	else:
		print("MENU SHOT PROBE: %d 处问题" % _failures.size())
		for f in _failures:
			print("  ✗ " + f)
		get_tree().quit(1)
