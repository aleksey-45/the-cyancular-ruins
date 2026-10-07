extends Control

# 圆形小地图探针(**必须带真实渲染,不能加 --headless**)。
# 跑法: "$GODOT" --path . --quit-after 3600 res://tests/probe/minimap_circle_probe.tscn
# 判据: 圆外的像素仍是背景色(discard 生效)+ 圆内有地形 + 敌人点只在范围内显示。
# PNG 落 res://.superpowers/sdd/(该目录自带 .gitignore = *,不入库)。
#
# - 判据为什么是这三个:圆形裁剪与"范围过滤"都是**数值断言抓不住**的东西 ——
#   旧实现(整图缩略贴右下角)在这三条里会挂一、二、四,而它看起来"功能正常"。
# - 背景故意铺品红:与地图三色(空气深/水蓝/墙灰)都不会撞,圆外只要不是品红就说明没裁干净。

const OUT_DIR := "res://.superpowers/sdd"
const PVP_HUD_SCENE := "res://ui/hud/pvp_hud.tscn"
const ROYALE_GAME := "res://scenes/royale_game.gd"   # 阶段 9 的源码级面(A 项)
const BG := Color(1.0, 0.0, 1.0)          # 品红背景
const WALL := Color(0.62, 0.68, 0.75)     # ui/minimap.gd 里墙的颜色(半透明 alpha 0.95)

var _failures: Array[String] = []
var _local := Vector2(1600.0, 1600.0)     # 玩家 canonical 位置(格 25,25)
var _enemy := Vector2.INF


func _ready() -> void:
	Settings.pvp_minimap_show_enemy = true

	# 合成地图:250×150 全实心(整张都是墙色)。-  尺寸必须与 GameParameters 的
	# MAP_WIDTH/HEIGHT 一致 —— 小地图把"格数"当贴图尺寸、把"世界像素"当坐标,
	# 两者不一致时圆里画的是错位的图(而断言可能照样绿)。
	# - 故意比真图(125×75 / 150×100)大一倍:下面要构造"环面最短距离在范围外"的样本,
	#   而那个距离受"地图半宽"封顶(超半宽就绕回来了)。图太小的话,RANGE_CELLS 调大一点
	#   就构造不出范围外样本 —— 断言会从"该红"变成"真绿"或反过来。
	const COLS := 250
	const ROWS := 150
	# - 底图**故意做成有结构的图案**(空底 + 每 8 列/6 行一道墙),不是"整张全实心":
	#   全实心取出来是一块均匀灰盘,人眼验收读不出"地形在 2.8px/格 下清不清楚" ——
	#   而那正是调过 RANGE_CELLS 之后**唯一需要人眼回答**的问题。
	var grid: Array[Array] = []
	for y in range(ROWS):
		var row: Array[int] = []
		row.resize(COLS)          # resize 填 0 == MazeGenerator.EMPTY
		for x in range(COLS):
			if x % 8 == 0 or y % 6 == 0:
				row[x] = MazeGenerator.SOLID
		grid.append(row)
	# - MAP_WIDTH/HEIGHT 是 **int**(core/config/game_parameters.gd:22),别用浮点赋值
	GameParameters.MAP_WIDTH = COLS * GameParameters.TILE_SIZE
	GameParameters.MAP_HEIGHT = ROWS * GameParameters.TILE_SIZE
	MazeGenerator.current_grid = grid

	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var mm := Minimap.new()
	mm.setup(func() -> Vector2: return _local, func() -> Vector2: return _enemy)
	add_child(mm)

	# - 两个样本距离都从 Minimap.RANGE_CELLS **推导**,不写死格数 ——
	#   写死的话调一次范围常量,这两条断言就可能悄悄翻面(本该红的变绿,或反之)。
	var ts := float(GameParameters.TILE_SIZE)
	var in_cells: float = minf(3.0, float(Minimap.RANGE_CELLS) * 0.5)
	var out_cells: float = float(Minimap.RANGE_CELLS) + 10.0
	_check(out_cells * ts < float(GameParameters.MAP_WIDTH) * 0.5,
			"合成地图够大,能构造出范围外样本(需要 < 半宽,实际 %.0f 格)" % out_cells)

	# ── ① 范围内的敌人点必须显示 ──
	_enemy = _local + Vector2(ts * in_cells, 0.0)
	await _frames(3)
	_check(mm._dot_enemy.visible, "范围内(%.0f 格)的敌人点应显示" % in_cells)

	# ── ② 范围外的敌人点必须不显示 ──
	_enemy = _local + Vector2(ts * out_cells, 0.0)
	await _frames(3)
	_check(not mm._dot_enemy.visible, "范围外(%.0f 格)的敌人点不得显示" % out_cells)

	# ── ③ 跨接缝:地图另一头、但环面距离在范围内的敌人**必须**显示 ──
	# 放到玩家左边整整一张图宽再回退 2 格 —— 直线距离 123 格,环面距离只有 2 格。
	_enemy = Vector2(_local.x - float(GameParameters.MAP_WIDTH) + ts * 2.0, _local.y)
	await _frames(3)
	_check(mm._dot_enemy.visible, "跨接缝 2 格的敌人点应显示(走环面最短向量)")

	# ── ⑤ 小地图的圆不得压到右下角的延迟条 ──
	# - 为什么单开这一条:小地图 layer 131 画在 PvpHud(130) **之上**,而两者都在右下角 ——
	#   2026-09-17 就是从"整图缩略 200px 高"换成"圆 280×280"时**盖住了延迟数字**
	#   (用户报「不要挡住下方的延迟」)。这条只有把两块 HUD 真摆在一起才测得出来。
	#   也在取图之前挂,好让 PNG 里能一眼看出圆和延迟条的间距。
	var pvp: CanvasLayer = (load(PVP_HUD_SCENE) as PackedScene).instantiate()
	add_child(pvp)
	# - 必须收掉它的全屏压暗罩:Mask 是一整块黑 0.3,会把下面④要验的"圆外=纯背景色"
	#   压成 (0.702,0,0.702) 而虚假失败（测试用例误报）(实测踩到)。实机里小地图 layer 131 画在 Mask(130) 之上、
	#   不受它影响,所以收掉它并不改变本探针要验的东西。
	pvp._mask.visible = false
	pvp._on_ping(24)
	await _frames(3)
	var ping_label := pvp.get_node("PingWrap/PingLabel") as Label
	_check(ping_label.text == "24ms", "延迟条文案应为「24ms」而不是「延迟 24 ms」(实际「%s」)" % ping_label.text)
	var ping_rect: Rect2 = (pvp.get_node("PingWrap") as Control).get_global_rect()
	var c := _circle_center_on_screen()
	var r := Minimap.RADIUS_PX
	# 矩形上离圆心最近的点:若它落在圆内 → 圆压住了延迟条
	var q := Vector2(clampf(c.x, ping_rect.position.x, ping_rect.end.x),
			clampf(c.y, ping_rect.position.y, ping_rect.end.y))
	_check(c.distance_to(q) > r,
			"小地图的圆不得压到延迟条(圆心 %s / 半径 %.0f / 最近点 %s / 距离 %.1f)"
					% [str(c), r, str(q), c.distance_to(q)])

	# ── ④ 取图:圆外必须还是背景色,圆内必须出现地形 ──
	_enemy = Vector2.INF
	await _frames(2)
	var img := await _shot("minimap_circle.png")
	if img.get_width() > 0:
		var g := _circle_geom(img)
		# 圆的**外接方框**左上角往内 4px —— 在方框内、但在圆外(距圆心 ≈192px > 140)
		var outside := Vector2i(int(g["left"]) + 4, int(g["top"]) + 4)
		_check(_near(img.get_pixelv(outside), BG, 0.08),
				"圆外像素应仍是背景色(实际 %s)" % str(img.get_pixelv(outside)))
		# 圆内:地形真的画出来了。-  判"墙色像素够多"而不是"某一点是墙色" ——
		#   底图现在有结构,某一点恰好落在空气上是正常的(而且玩家自己的点也画在圆心,
		#   采圆心会取到 SELF_COLOR,实测踩过)。
		#   墙色 alpha 0.95 压在品红上 → 实际像素是两者的合成,故给 0.12 容差。
		var wall_px := _count_near(img, g, WALL, 0.12)
		_check(wall_px > 500, "圆内应画出地形(墙色像素 %d,期望 > 500)" % wall_px)

	# ── ⑥ 3v3:自己那个点 = **队色** + 一圈白描边(与颜色正交的维度)──
	# - 必须真渲染:判据落在像素上(headless 下 get_image() 返回 null  ->  整段静默跳过)。
	# - 编号从 ⑥ 起 —— 上面那个 ⑤ 是"圆不得压到延迟条"(几何断言),别与它混。
	mm.visible = false
	var TEAM_B := UiFactory.C_TEAM_B
	# - 一格数组:下面 ④ 要**改它**来验"提供器是每帧求值、不是建点时缓存一次"。
	#   写成 `func() -> Color: return TEAM_B` 那个常量闭包**验不出**这条(两种实现测试均通过)。
	var self_col := [TEAM_B]
	var mm_team := Minimap.new()
	mm_team.setup_multi(
		func() -> Vector2: return _local,
		func() -> Array: return [],          # 无他人点:本阶段只验"我"
		func() -> Array: return [],
		func() -> Color: return self_col[0])
	add_child(mm_team)
	await _frames(2)
	var img_team := await _shot("minimap_self_dot.png")
	if img_team.get_width() > 0:
		var center := _circle_center_on_screen()
		# ① 点的**底色**是队色,不是 SELF_COLOR
		var px_dot := img_team.get_pixelv(Vector2i(int(center.x), int(center.y)))
		_check(_near(px_dot, TEAM_B, 0.08),
				"3v3 自己那个点的底色应是队色(实际 %s、期望 %s、SELF_COLOR 是 %s)" % [
					str(px_dot), str(TEAM_B), str(Minimap.SELF_COLOR)])
		_check(not _near(px_dot, Minimap.SELF_COLOR, 0.08),
				"★ 反向:底色**不得**还是 SELF_COLOR(那就是没修)")
		# ② 描边存在:点在点外侧、但仍在描边框内的一圈取色(8×8 点 + 4px 边框  ->  半径 4..8 那一带)
		var ring_px := 0
		for i in range(24):
			var a := TAU * float(i) / 24.0
			# - 变量名不能叫 `q`:`_ready()` 上面那条"圆不压延迟条"的几何断言已经声明过 `q`
			#   (GDScript 里嵌套块重名是 Parse Error  ->  整条探针一行都跑不到)。
			var q_ring := Vector2i(int(center.x + cos(a) * 6.0), int(center.y + sin(a) * 6.0))
			if _near(img_team.get_pixelv(q_ring), Color(1, 1, 1), 0.08):
				ring_px += 1
		_check(ring_px >= 18,
				"自己那个点应有**白描边**(24 个采样点里 %d 个命中白色,期望 ≥ 18)" % ring_px)
		# ③ 正交维度的**测试有效性**:把描边关掉,同样的采样必须掉下来
		# - 必须先 `set_process(false)` —— `Minimap._process` 每帧都会把 `_ring_self.visible`
		#   按 `_self_color_provider` 写回去,直接改 `visible` 会被下一帧覆盖
		#    ->  两张图一模一样  ->  下面那条**必然**失败(那是探针自己的错,不是实现的错)。
		mm_team.set_process(false)
		mm_team._ring_self.visible = false
		await _frames(2)
		var img_no_ring := await _shot("minimap_self_dot_noring.png")
		if img_no_ring.get_width() > 0:
			var ring2 := 0
			for i in range(24):
				var a2 := TAU * float(i) / 24.0
				var q_ring2 := Vector2i(int(center.x + cos(a2) * 6.0), int(center.y + sin(a2) * 6.0))
				if _near(img_no_ring.get_pixelv(q_ring2), Color(1, 1, 1), 0.08):
					ring2 += 1
			_check(ring2 < 6,
					"★ 关掉描边后白色采样必须掉下来(实际 %d)—— 否则上面那条是恒真的" % ring2)
		# - 恢复写在内层 `if` **之外**:`img_no_ring` 取图失败(width 0)时内层整段跳过,
		#   恢复写在内层就会漏  ->  下面 ④ 的换色验不到(那是探针自己的错,不是实现的错)。
		mm_team.set_process(true)
		mm_team._ring_self.visible = true

		# ── ④ 提供器必须**每帧求值**,不是建点时缓存一次 ──
		# - 这条钉的正是"第四参为什么是 Callable 而不是 Color":队色由 `match_sync` 下发、
		#   比小地图建立**晚**  ->  若在 `setup_multi` 里把颜色解析一次存起来,3v3 整局那个点
		#   会**恒为建点时的颜色**(中性亮白)—— 而那正是设计要避免的那个失败。
		# - 判据必须**跟着一次变化**走(改掉闭包返回的颜色,看像素跟不跟);恒定的闭包
		#   (`func() -> Color: return TEAM_B`)对"每帧求值"与"缓存一次"**两种实现都给绿**。
		self_col[0] = UiFactory.C_TEAM_A
		await _frames(2)
		var img_swap := await _shot("minimap_self_dot_swapped.png")
		if img_swap.get_width() > 0:
			var px_swap := img_swap.get_pixelv(Vector2i(int(center.x), int(center.y)))
			_check(_near(px_swap, UiFactory.C_TEAM_A, 0.08),
					"★ 提供器必须**每帧求值**:返回色从 C_TEAM_B 改成 C_TEAM_A 后自己那个点应跟着变(实际 %s、期望 %s;停在上一个颜色 = 建点时缓存了一次)" % [
						str(px_swap), str(UiFactory.C_TEAM_A)])

	# ── ⑦ 反向对照:不传自色提供器  ->  退回 SELF_COLOR、且描边不可见 ──
	# - 这条是"1v1 / 大乱斗行为逐字不变"的守卫 —— 没有它,把默认分支写成"恒走队色"
	#   (或干脆恒真)也能让阶段 6测试全部通过,而那会让那两模式的小地图自己那个点变成中性亮白。
	mm_team.visible = false
	var mm_plain := Minimap.new()
	# - 2026-09-29 起 `setup_multi` 四个参数**全部必填**(B 项)——大乱斗这条"不给自己上色"
	#   现在是**显式**的空 `Callable()`,不再是默认值。
	mm_plain.setup_multi(
		func() -> Vector2: return _local,
		func() -> Array: return [],
		func() -> Array: return [],
		Callable())
	add_child(mm_plain)
	await _frames(2)
	_check(_near(mm_plain._dot_self.color, Minimap.SELF_COLOR, 0.001),
			"不传自色提供器 ⇒ 自己那个点应保持 SELF_COLOR(实际 %s)" % str(mm_plain._dot_self.color))
	_check(not mm_plain._ring_self.visible,
			"传空自色提供器 ⇒ 白描边**不可见**(1v1 / 大乱斗没有这个问题,别给它们加标记)")

	# ── ⑧ 他人点是**按下标**取色(大乱斗上色那条改动的地基)──
	# - 为什么必须有:2026-09-29 起大乱斗的他人点不再恒红,而是按 role 取 `ROLE_COLORS`。
	#   而 `Minimap` 的取色是 `_other_dots[i].color = cols[i]` —— **下标**对齐,不是按 role 查表。
	#   这一条钉住"颜色数组是按提供器给的顺序、一个不差地落到对应点上";同时它也钉住
	#   "点比颜色数组多时,多出来的点保持 ENEMY_COLOR"(不然越界会被读成 0 号色)。
	# - 本阶段**不看像素**(读的是 `ColorRect.color`),故 headless 下也真的在跑 ——
	#   但整个探针仍需要真渲染(前面几相要取图),所以判据仍是那一行 verdict。
	mm_plain.visible = false
	var mm_multi := Minimap.new()
	var COL_A := Color(0.1, 0.9, 0.2)
	var COL_B := Color(0.9, 0.2, 0.1)
	mm_multi.setup_multi(
		func() -> Vector2: return _local,
		func() -> Array: return [_local + Vector2(64.0, 0.0), _local + Vector2(0.0, 64.0)],
		func() -> Array: return [COL_A, COL_B],
		Callable())
	add_child(mm_multi)
	await _frames(2)
	_check(mm_multi._other_dots.size() == 2,
			"⑧ 两个他人点应被建出来(实际 %d)" % mm_multi._other_dots.size())
	if mm_multi._other_dots.size() == 2:
		_check(_near(mm_multi._other_dots[0].color, COL_A, 0.001)
				and _near(mm_multi._other_dots[1].color, COL_B, 0.001),
				"⑧ ★ 他人点的颜色必须**按下标**一一对应(实得 [%s, %s]、期望 [%s, %s];" % [
					str(mm_multi._other_dots[0].color), str(mm_multi._other_dots[1].color),
					str(COL_A), str(COL_B)]
				+ " 错位 = 某人的点画成别人的色,而不报错)")
		_check(not _near(mm_multi._other_dots[0].color, Minimap.ENEMY_COLOR, 0.001),
				"⑧ ★ 反向:喂了颜色提供器之后**不得**还是 ENEMY_COLOR(那就是没生效)")

	# ── ⑨ 源码级:**大乱斗**两个提供器必须共用同一份 entries(2026-09-29,A 项)──
	# - 为什么行为相(⑧)不够:`Minimap` 只保证"按下标落色"**,它管不到上游两个数组是否同长**。
	#   大乱斗的副本是懒建 + 会 erase(`_remove_replica`),位置提供器自带 `is_instance_valid`
	#   过滤 —— 颜色提供器少写一个同样的过滤就会**错位一格**。这条纪律 3v3 已经吃过一次
	#   (`team_room_smoke` ⑨③),这里是它的**大乱斗那一半**。
	# - 判据落在**函数体**里:`royale_game.gd` 里**没有 `static func`**,故 `func_body` 的
	#   边界(`\nfunc `)是准的(那处 `static func` 盲区对本文件不成立 —— 已在落地时核过)。
	var rg := ScanUtil.read(ROYALE_GAME)
	_check(not rg.is_empty(), "⑨ 读到 %s(读不到就是红,不是静默跳过)" % ROYALE_GAME)
	var rgc := ScanUtil.code_only(rg)
	var ent := ScanUtil.func_body(rgc, "_minimap_entries")
	_check(ent.contains("is_instance_valid("),
			"⑨ ★ `_minimap_entries` 必须**自己**带 `is_instance_valid` 过滤(两个数组同源的唯一落点)")
	var oth := ScanUtil.func_body(rgc, "_minimap_others")
	var cols := ScanUtil.func_body(rgc, "_minimap_colors")
	_check(oth.contains("_minimap_entries()") and cols.contains("_minimap_entries()"),
			"⑨ ★★ 位置与颜色两个提供器**都**必须从 `_minimap_entries()` 取数"
			+ "(各写一份 `for role in _replicas` = 错位一格的成因,而不报错)")
	_check(not oth.contains("for role in _replicas") and not cols.contains("for role in _replicas"),
			"⑨ ★ 反向:两个提供器体内**不得**再出现 `for role in _replicas`(那是第二份过滤)")
	_check(cols.contains("ROLE_COLORS["),
			"⑨ 他人点的颜色必须走**头顶 ID 同源**的色板 `ROLE_COLORS`(实得体内「%s」)" % cols)
	_check(rgc.contains("Callable(self, \"_minimap_colors\")")
			and rgc.contains("Callable(self, \"_minimap_others\")"),
			"⑨ 两个提供器必须**真的接到** `setup_multi` 上(定义了没人用 = 点还是恒红)")

	_finish()


# 圆心在**屏幕**坐标(未按取图缩放)。与 ui/minimap.gd 的常量保持一致:
# 右留白 EDGE、下留白 EDGE_BOTTOM(-  两者不同 —— 下边要给延迟条让位)。
func _circle_center_on_screen() -> Vector2:
	var r: float = Minimap.RADIUS_PX
	return Vector2(1920.0 - Minimap.EDGE - r, 1440.0 - Minimap.EDGE_BOTTOM - r)


# 圆在取到的图上的几何
func _circle_geom(img: Image) -> Dictionary:
	var s := Vector2(img.get_width(), img.get_height()) / get_viewport().get_visible_rect().size
	var r: float = Minimap.RADIUS_PX
	var c := _circle_center_on_screen()
	var cx := c.x * s.x
	var cy := c.y * s.y
	return {"cx": cx, "cy": cy, "top": cy - r * s.y, "left": cx - r * s.x}


func _near(a: Color, b: Color, tol: float) -> bool:
	return absf(a.r - b.r) < tol and absf(a.g - b.g) < tol and absf(a.b - b.b) < tol


# 圆**内部**(按 _circle_geom 给的圆心/半径)里接近给定颜色的像素数。
func _count_near(img: Image, g: Dictionary, want: Color, tol: float) -> int:
	var r: float = Minimap.RADIUS_PX
	var cx: float = g["cx"]
	var cy: float = g["cy"]
	var n := 0
	for y in range(int(cy - r), int(cy + r)):
		for x in range(int(cx - r), int(cx + r)):
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			if Vector2(float(x), float(y)).distance_to(Vector2(cx, cy)) > r:
				continue
			if _near(img.get_pixel(x, y), want, tol):
				n += 1
	return n


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
		print("[MINIMAP] 已存 %s  %dx%d" % [
				ProjectSettings.globalize_path(path), img.get_width(), img.get_height()])
	return img


func _frames(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("[MINIMAP] ✓ %s" % msg)
	else:
		_failures.append(msg)
		print("[MINIMAP] ✗ %s" % msg)


func _finish() -> void:
	if _failures.is_empty():
		print("MINIMAP CIRCLE PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("MINIMAP CIRCLE PROBE: FAIL")
		for f in _failures:
			print("  - %s" % f)
		get_tree().quit(1)
