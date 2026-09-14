extends SceneTree

# 卡片像素画生成器(DevTools,-s 脚本):按 --card=<type>/<id> 分派,纯程序化绘制,
# 零外部素材(构建 profile 已禁 FastNoiseLite)。每张新卡追加一个分支函数,不改旧分支。
# 用法: Godot_console --headless --path . -s res://DevTools/gen_portrait.gd -- --card=weapon/wp_machete

func _initialize() -> void:
	var card := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--card="):
			card = a.trim_prefix("--card=")
	match card:
		"weapon/wp_machete":
			_machete()
		"operator/op_vanguard":
			_vanguard()
		"prop/pr_attraction":
			_pr_attraction()
		"prop/pr_knockback":
			_pr_knockback()
		"prop/pr_smoke":
			_pr_smoke()
		"prop/pr_731505":
			_pr_731505()
		_:
			printerr("GEN FAIL | 未知卡: '%s'(期望 weapon/wp_machete 等)" % card)
			quit(1)
			return
	print("GEN OK")


func _save(path: String, img: Image) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	img.save_png(path)
	print("  生成: " + path + " (%dx%d)" % [img.get_width(), img.get_height()])


# ── 开山砍刀(96×48,水平持握朝右):宽背厚刃+刀尖双锯齿缺口+黄铜圆护手+木柄黑胶带 ──
func _machete() -> void:
	var img := Image.create(96, 48, false, Image.FORMAT_RGBA8)
	var spine_y := 16      # 刀背上缘
	var edge_y := 32       # 刀刃下缘
	var blade_gray := Color8(138, 146, 156)
	var blade_dark := Color8(90, 96, 104)
	var scratch := Color8(178, 184, 190)
	var brass := Color8(176, 141, 63)
	var wood := Color8(122, 82, 48)
	var tape := Color8(34, 34, 34)
	# 刀身:x 30..90,上缘刀背厚(3px 深灰),下缘开刃(1px 亮灰)
	for x in range(30, 91):
		img.set_pixel(x, spine_y, blade_dark)
		img.set_pixel(x, spine_y + 1, blade_dark)
		img.set_pixel(x, spine_y + 2, blade_dark)
		for y in range(spine_y + 3, edge_y):
			img.set_pixel(x, y, blade_gray)
		img.set_pixel(x, edge_y, Color8(200, 206, 212))   # 开刃亮线
	# 刀尖收窄(x 84..92 收成斜尖)
	for x in range(84, 92):
		var t := float(x - 84) / 8.0
		for y in range(spine_y + int(t * 8.0), edge_y + 1):
			img.set_pixel(x, y, blade_gray if y < edge_y else Color8(200, 206, 212))
	# 刀尖两道锯齿缺口(下缘 x 74/80 处向内咬 4px)
	for nx in [74, 80]:
		for x in range(nx, nx + 4):
			for y in range(edge_y - 3, edge_y + 1):
				img.set_pixel(x, y, Color(0, 0, 0, 0))
			img.set_pixel(x, edge_y - 4, blade_dark)
	# 划痕(随机短横线)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260906
	for i in range(14):
		var sx := rng.randi_range(34, 82)
		var sy := rng.randi_range(spine_y + 3, edge_y - 1)
		img.set_pixel(sx, sy, scratch)
	# 黄铜圆护手(x 26..32 圆盘)
	for x in range(25, 33):
		for y in range(spine_y - 4, edge_y + 3):
			var dx := (x - 29.0) / 4.0
			var dy := (y - 24.0) / 10.0
			if dx * dx + dy * dy <= 1.0:
				img.set_pixel(x, y, brass)
	# 木柄(x 4..25,略下倾)+ 黑胶带缠带(三段)
	for x in range(4, 26):
		var drop := int((25 - x) * 0.18)
		for y in range(22 + drop, 30 + drop):
			var is_tape := (x % 7) < 2
			img.set_pixel(x, y, tape if is_tape else wood)
		# 柄尾圆角
		if x < 6:
			img.set_pixel(x, 22 + drop, Color(0, 0, 0, 0))
			img.set_pixel(x, 29 + drop, Color(0, 0, 0, 0))
	_save("res://assets/weapons/wp_machete.png", img)
	# 副本:DevTools 卡片目录(编辑器剪影页读这份)
	_save("res://DevTools/cards/weapons/wp_machete.png", img.duplicate())
	# 枪身贴图(对局内武器精灵 48×16,握把在左、刃朝右;槽位文件 + 游戏镜像)
	var gun := Image.create(48, 16, false, Image.FORMAT_RGBA8)
	_machete_gun(gun)
	_save_ai_slot("res://DevTools/cards/weapons/wp_machete__gun.png", gun,
			"res://assets/custom/guns/wp_machete.png")
	# HUD 白剪影(96×48:卡面像素全白保 alpha,单色剪影;槽位文件 + 游戏镜像)
	var sil := img.duplicate()
	for y in range(sil.get_height()):
		for x in range(sil.get_width()):
			if sil.get_pixel(x, y).a > 0.05:
				sil.set_pixel(x, y, Color.WHITE)
	_save_ai_slot("res://DevTools/cards/weapons/wp_machete__silhouette.png", sil,
			"res://assets/custom/silhouettes/wp_machete.png")


# 槽位文件 + 游戏镜像各存一份,均写 source=ai meta(布局与 editor_art 上传镜像一致:
# 编辑器槽位状态读 DevTools 卡片目录的 meta,游戏侧读 assets/custom 镜像;画师上传
# 会覆盖同名文件并把 meta 改回 human,AI 占位只做兜底)。
func _save_ai_slot(slot_path: String, img: Image, mirror_path: String) -> void:
	_save(slot_path, img)
	if mirror_path == "":
		return
	DirAccess.make_dir_recursive_absolute(mirror_path.get_base_dir())
	img.duplicate().save_png(mirror_path)
	print("  镜像: " + mirror_path)
	for p in [slot_path + ".meta", mirror_path + ".meta"]:
		var f := FileAccess.open(p, FileAccess.WRITE)
		if f != null:
			f.store_string("source=ai\nupdated=%s\n" % Time.get_datetime_string_from_system())
			f.close()


# 枪身像素画(48×16):木柄缠黑胶带 → 黄铜圆护手 → 宽背厚刃(3px 深灰刀背)带划痕,
# 靠刀尖两道锯齿缺口 + 斜收刀尖;1px 深描边。配色与卡面同源(appearance 描述的像素化)。
func _machete_gun(img: Image) -> void:
	var blade_gray := Color8(138, 146, 156)
	var blade_dark := Color8(90, 96, 104)
	var scratch := Color8(178, 184, 190)
	var bright := Color8(200, 206, 212)
	var brass := Color8(176, 141, 63)
	var brass_dk := Color8(120, 94, 40)
	var wood := Color8(122, 82, 48)
	var tape := Color8(34, 34, 34)
	# 木柄 x0..11(左半略下沉 1px)+ 黑胶带缠带
	for x in range(0, 12):
		var drop := 1 if x < 6 else 0
		for y in range(6 + drop, 11 + drop):
			img.set_pixel(x, y, tape if (x % 4) < 1 else wood)
	# 黄铜圆护手 x12..14(竖盘,上下凸出刀身,缘圈压暗)
	for x in range(12, 15):
		for y in range(2, 14):
			img.set_pixel(x, y, brass_dk if (y < 4 or y > 11) else brass)
	# 刀身 x15..46:刀背 3px 厚(突出厚背),刃体冷灰,下缘开刃亮线
	for x in range(15, 47):
		for y in range(3, 6):
			img.set_pixel(x, y, blade_dark)
		for y in range(6, 12):
			img.set_pixel(x, y, blade_gray)
		img.set_pixel(x, 12, bright)
	# 刀尖斜收(刀背向刃线收,尖端落在开刃线上)
	for x in range(40, 47):
		for y in range(3, 4 + int(float(x - 40) * 9.0 / 7.0)):
			img.set_pixel(x, y, Color(0, 0, 0, 0))
	# 靠刀尖两道锯齿缺口(下缘向内咬 2px,缺口上沿压深灰读作咬口)
	for nx in [33, 38]:
		for x in range(nx, nx + 2):
			for y in range(11, 13):
				img.set_pixel(x, y, Color(0, 0, 0, 0))
			img.set_pixel(x, 10, blade_dark)
	# 划痕(短横点)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260914
	for i in range(8):
		img.set_pixel(rng.randi_range(17, 36), rng.randi_range(6, 11), scratch)
	_outline_silhouette(img)


# ── 先锋 干员头像(96×96):蓝灰作战服短发突击手,橙色护目镜推在额头,冷蓝主调 ──
func _vanguard() -> void:
	var img := Image.create(96, 96, false, Image.FORMAT_RGBA8)
	var bg := Color8(24, 30, 38)
	var skin := Color8(224, 182, 150)
	var hair := Color8(46, 40, 36)
	var uniform := Color8(74, 92, 110)    # 蓝灰作战服
	var uniform_d := Color8(58, 72, 88)
	var goggle := Color8(232, 126, 28)    # 护目镜橙(醒目点缀)
	var goggle_d := Color8(160, 84, 16)
	var outline := Color8(12, 14, 18)
	# 深色底
	img.fill(bg)
	# 头(圆角方):y 18..44,x 30..66
	for y in range(18, 45):
		for x in range(30, 67):
			img.set_pixel(x, y, skin)
	# 短发(头顶+两侧,y 12..30)
	for y in range(12, 30):
		for x in range(28, 69):
			if y < 22 or x < 34 or x > 62:
				img.set_pixel(x, y, hair)
	# 额头护目镜(橙色横带,y 24..30,镜框深橙描边)
	for y in range(24, 31):
		for x in range(32, 65):
			var frame := y == 24 or y == 30 or x == 32 or x == 64
			img.set_pixel(x, y, goggle_d if frame else goggle)
	# 眼/嘴(发带下方一线)
	for x in range(38, 58):
		img.set_pixel(x, 36, Color8(90, 70, 58))
	img.set_pixel(42, 40, Color8(150, 110, 90))
	img.set_pixel(52, 40, Color8(150, 110, 90))
	# 脖子+肩(作战服,y 46..92)
	for y in range(46, 93):
		for x in range(18, 79):
			var shoulder := y < 58
			var col := uniform
			if (x < 26 or x > 70) and y > 60:
				col = uniform_d   # 侧影
			if shoulder and (x < 30 or x > 66):
				col = uniform_d
			img.set_pixel(x, y, col)
	# 斜挎弹药盒肩带(左肩→右腰)
	for y in range(48, 90):
		var x := 24 + int((y - 48) * 0.55)
		for dx in range(4):
			img.set_pixel(x + dx, y, uniform_d)
	# 领口/下巴阴影
	for x in range(38, 59):
		img.set_pixel(x, 45, Color8(190, 150, 120))
	# 1px 外描边(整像外围非透明边界)
	var bounds := Image.create(96, 96, false, Image.FORMAT_RGBA8)
	for y in range(96):
		for x in range(96):
			if img.get_pixel(x, y).a > 0.0:
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						var px := x + dx
						var py := y + dy
						if px >= 0 and px < 96 and py >= 0 and py < 96:
							bounds.set_pixel(px, py, outline)
	for y in range(96):
		for x in range(96):
			if img.get_pixel(x, y).a > 0.0:
				bounds.set_pixel(x, y, img.get_pixel(x, y))
	_save("res://assets/operators/op_vanguard.png", bounds)
	# 副本:DevTools 卡片目录(编辑器头像页读这份)
	_save("res://DevTools/cards/operators/op_vanguard.png", bounds.duplicate())


# ── 引力核心 道具(卡 pr_attraction):卡面 96×96 暗底展示 + 对局贴图设计稿 48×48 透明底 ──
# appearance 约定:青蓝色圆柱罐体 + 罐体螺旋吸入纹样 + 顶部引信带小涡旋标(像素风)。
func _pr_attraction() -> void:
	var card := Image.create(96, 96, false, Image.FORMAT_RGBA8)
	_canister(card, 48, 24, 34, 52)
	# 顺序:环先画在透明像素上,再补底色——底色一填满就再无透明像素可落环
	_rings_where_empty(card, Vector2(47.5, 51.5), Color8(36, 56, 70))   # 同心环底纹(吸引主题)
	_fill_bg_where_empty(card, Color8(24, 30, 38))
	_save("res://DevTools/cards/props/pr_attraction.png", card)

	var world := Image.create(48, 48, false, Image.FORMAT_RGBA8)
	_canister(world, 24, 10, 20, 30)
	_outline_silhouette(world)   # 透明底 sprite:1px 深色外描边
	_save("res://DevTools/cards/props/pr_attraction__world.png", world)

	for p in ["res://DevTools/cards/props/pr_attraction.png",
			"res://DevTools/cards/props/pr_attraction__world.png"]:
		var f := FileAccess.open(p + ".meta", FileAccess.WRITE)
		if f != null:
			f.store_string("source=ai\nupdated=%s\n" % Time.get_datetime_string_from_system())
			f.close()


# ── 排斥弹头 道具(卡 pr_knockback):卡面 96×96 暗底展示 + 对局贴图设计稿 48×48 透明底 ──
# appearance 约定:橙红色圆柱罐体 + 顶部按压引信 + 罐体白色冲击波标识(像素风:3px 描边+两阶明暗)。
func _pr_knockback() -> void:
	var pal := {
		"body": Color8(198, 90, 40),
		"body_lite": Color8(240, 152, 92),
		"body_hi": Color8(255, 214, 168),
		"body_dk": Color8(134, 50, 24),
		"mark": Color8(250, 250, 246),   # 白色冲击波标识
	}
	var card := Image.create(96, 96, false, Image.FORMAT_RGBA8)
	_canister(card, 48, 24, 34, 52, pal, "shock")
	# 顺序:环先画在透明像素上,再补底色——底色一填满就再无透明像素可落环
	_rings_where_empty(card, Vector2(47.5, 51.5), Color8(76, 44, 32))   # 同心环底纹(排斥主题,暖暗色)
	_fill_bg_where_empty(card, Color8(24, 30, 38))
	_save("res://DevTools/cards/props/pr_knockback.png", card)

	var world := Image.create(48, 48, false, Image.FORMAT_RGBA8)
	_canister(world, 24, 10, 20, 30, pal, "shock_small")
	_outline_silhouette(world)   # 透明底 sprite:1px 深色外描边
	_save("res://DevTools/cards/props/pr_knockback__world.png", world)

	for p in ["res://DevTools/cards/props/pr_knockback.png",
			"res://DevTools/cards/props/pr_knockback__world.png"]:
		var f := FileAccess.open(p + ".meta", FileAccess.WRITE)
		if f != null:
			f.store_string("source=ai\nupdated=%s\n" % Time.get_datetime_string_from_system())
			f.close()


# ── 烟雾弹 道具(卡 pr_smoke):卡面 96×96 暗底展示 + 对局贴图设计稿 48×48 透明底 ──
# appearance 约定:灰绿色圆罐,罐体三道横向散烟孔,顶部拉环引信(像素风)。
func _pr_smoke() -> void:
	var pal := {
		"body": Color8(108, 122, 106),
		"body_lite": Color8(154, 168, 148),
		"body_hi": Color8(202, 214, 194),
		"body_dk": Color8(72, 84, 68),
	}
	var card := Image.create(96, 96, false, Image.FORMAT_RGBA8)
	_canister(card, 48, 24, 34, 52, pal, "vents", true)
	# 顺序:环先画在透明像素上,再补底色——底色一填满就再无透明像素可落环
	_rings_where_empty(card, Vector2(47.5, 51.5), Color8(40, 52, 44))   # 同心环底纹(烟雾主题,冷暗绿)
	_fill_bg_where_empty(card, Color8(24, 30, 38))
	_save("res://DevTools/cards/props/pr_smoke.png", card)

	var world := Image.create(48, 48, false, Image.FORMAT_RGBA8)
	_canister(world, 24, 10, 20, 30, pal, "vents", true)
	_outline_silhouette(world)   # 透明底 sprite:1px 深色外描边
	_save("res://DevTools/cards/props/pr_smoke__world.png", world)

	for p in ["res://DevTools/cards/props/pr_smoke.png",
			"res://DevTools/cards/props/pr_smoke__world.png"]:
		var f := FileAccess.open(p + ".meta", FileAccess.WRITE)
		if f != null:
			f.store_string("source=ai\nupdated=%s\n" % Time.get_datetime_string_from_system())
			f.close()


# ── 投掷爆炸团 道具(卡 pr_731505,槽 11):卡面 96×96 暗底展示 + 对局贴图设计稿 48×48 透明底 ──
# appearance 约定:冷色调像素手雷——青蓝罐体,顶部引信,白色爆芒标识(两阶明暗+深描边)。
func _pr_731505() -> void:
	var pal := {
		"body": Color8(56, 110, 158),
		"body_lite": Color8(112, 178, 224),
		"body_hi": Color8(190, 232, 250),
		"body_dk": Color8(32, 70, 108),
		"mark": Color8(250, 250, 246),   # 白色爆芒标识
	}
	var card := Image.create(96, 96, false, Image.FORMAT_RGBA8)
	_canister(card, 48, 24, 34, 52, pal, "shock")
	# 顺序:环先画在透明像素上,再补底色——底色一填满就再无透明像素可落环
	_rings_where_empty(card, Vector2(47.5, 51.5), Color8(30, 46, 66))   # 同心环底纹(倒计时主题,冷暗蓝)
	_fill_bg_where_empty(card, Color8(24, 30, 38))
	_save("res://DevTools/cards/props/pr_731505.png", card)

	var world := Image.create(48, 48, false, Image.FORMAT_RGBA8)
	_canister(world, 24, 10, 20, 30, pal, "shock_small")
	_outline_silhouette(world)   # 透明底 sprite:1px 深色外描边
	_save("res://DevTools/cards/props/pr_731505__world.png", world)

	for p in ["res://DevTools/cards/props/pr_731505.png",
			"res://DevTools/cards/props/pr_731505__world.png"]:
		var f := FileAccess.open(p + ".meta", FileAccess.WRITE)
		if f != null:
			f.store_string("source=ai\nupdated=%s\n" % Time.get_datetime_string_from_system())
			f.close()


# 圆柱罐体(cx=中轴,top=顶沿,y 向下,w×h 含顶/底金属帽):
# 引信竖条 + 顶帽(盖标识)+ 罐身(左亮缘/右暗影 + 对角螺旋纹)+ 底帽,四角去 1px 圆角。
# pal 缺省 = 引力核心青蓝套;emblem:vortex=顶帽涡旋标(吸引)/ shock|shock_small=罐身中央
# 白色冲击波标(排斥,大/小尺寸)/ vents=罐身三道横向散烟孔(烟雾弹)。
# pull_ring=true 时引信旁加拉环(烟雾弹)。旧分支不传参,输出与历史一致。
func _canister(img: Image, cx: int, top: int, w: int, h: int, pal: Dictionary = {},
		emblem: String = "vortex", pull_ring: bool = false) -> void:
	var cap: Color = pal.get("cap", Color8(66, 74, 86))
	var cap_lite: Color = pal.get("cap_lite", Color8(132, 142, 154))
	var body: Color = pal.get("body", Color8(56, 142, 168))
	var body_lite: Color = pal.get("body_lite", Color8(110, 206, 232))
	var body_hi: Color = pal.get("body_hi", Color8(190, 238, 250))
	var body_dk: Color = pal.get("body_dk", Color8(32, 86, 106))
	var mark: Color = pal.get("mark", body_hi)
	var x0 := cx - w / 2
	var x1 := cx + (w - 1) / 2
	var cap_h := maxi(5, h / 8)
	var fuse_h := maxi(3, h / 14)
	# 引信(顶帽上方 2px 竖条)+ 火花点
	for y in range(top - fuse_h, top):
		img.set_pixel(cx, y, cap_lite)
		img.set_pixel(cx + 1, y, cap)
	img.set_pixel(cx - 1, top - fuse_h, body_hi)
	# 顶帽(顶沿提亮一圈)
	for y in range(top, top + cap_h):
		for x in range(x0 + 1, x1):
			img.set_pixel(x, y, cap_lite if y == top else cap)
	# 罐身:亮左缘/暗右缘;对角螺旋带(周期 9:2px 暗槽 + 1px 亮棱,读作绕罐螺旋)
	var by0 := top + cap_h
	var by1 := top + h - cap_h
	for y in range(by0, by1):
		for x in range(x0, x1 + 1):
			var col := body
			if x < x0 + 2:
				col = body_lite
			elif x >= x1 - 1:
				col = body_dk
			else:
				var ph := posmod((x - x0) + (y - by0), 9)
				if ph < 2:
					col = body_dk
				elif ph < 3:
					col = body_lite
			img.set_pixel(x, y, col)
	# 标识(压在罐体之上):涡旋=顶帽中央(吸引)/ 冲击波=罐身中央(排斥)/ 散烟孔=罐身(烟雾弹)
	match emblem:
		"vortex":
			_vortex(img, cx, top + cap_h / 2, body_hi, body_dk)
		"shock":
			_shock_mark(img, cx, (by0 + by1) / 2, mark, 7)
		"shock_small":
			_shock_mark(img, cx, (by0 + by1) / 2, mark, 5)
		"vents":
			_vent_slits(img, cx, by0, by1, x0, x1, body_dk, body_lite)
	# 底帽(底沿提亮一圈)
	for y in range(by1, top + h):
		for x in range(x0 + 1, x1):
			img.set_pixel(x, y, cap_lite if y == top + h - 1 else cap)
	# 圆角:罐身与帽衔接的四角去 1px
	for c in [Vector2i(x0, by0), Vector2i(x1, by0), Vector2i(x0, by1 - 1), Vector2i(x1, by1 - 1)]:
		img.set_pixel(c.x, c.y, Color(0, 0, 0, 0))
	# 拉环引信(烟雾弹):D 形环挂在引信竖条左侧,中段 1px 连接位搭在竖条旁
	if pull_ring:
		var ry := top - fuse_h - 2
		for x in range(cx - 5, cx - 1):
			img.set_pixel(x, ry, cap_lite)
			img.set_pixel(x, ry + 2, cap_lite)
		for y in range(ry, ry + 3):
			img.set_pixel(cx - 5, y, cap_lite)
		img.set_pixel(cx - 1, ry + 1, cap_lite)


# 白色冲击波标(排斥弹头罐身标识):中心实点 + 菱形环 + 四正位放射点,读作由中心向外炸开
func _shock_mark(img: Image, cx: int, cy: int, col: Color, size: int) -> void:
	var rows: Array[String]
	if size < 7:
		rows = ["..#..", ".#.#.", "#.#.#", ".#.#.", "..#.."]
	else:
		rows = ["...#...", ".#...#.", "..#.#..", "#..#..#", "..#.#..", ".#...#.", "...#..."]
	var off := (size - 1) / 2
	for y in range(size):
		for x in range(size):
			if rows[y][x] == "#":
				img.set_pixel(cx - off + x, cy - off + y, col)


# 三道横向散烟孔(烟雾弹罐身标识):2px 暗槽 + 下缘 1px 亮棱,均布罐身高度 25/50/75%
func _vent_slits(img: Image, cx: int, by0: int, by1: int, x0: int, x1: int,
		dark: Color, lite: Color) -> void:
	var half := int(float(x1 - x0) * 0.30)   # 孔半宽
	var body_h := by1 - by0
	for i in range(3):
		var cy := by0 + int(float(body_h) * (0.25 + 0.25 * float(i)))
		for x in range(cx - half, cx + half + 1):
			img.set_pixel(x, cy, dark)
			img.set_pixel(x, cy + 1, dark)
			img.set_pixel(x, cy + 2, lite)


# 5×5 涡旋标:环(右中开口)+ 中点(暗)+ 钩尾(开口卷向中点),亮色描环
func _vortex(img: Image, cx: int, cy: int, col: Color, inner: Color) -> void:
	var rows := [".###.", "#...#", "#.##.", "#...#", ".###."]
	for y in range(5):
		for x in range(5):
			if rows[y][x] == "#":
				var dark := x == 2 and y == 2   # 中点用暗色:旋涡有进深
				img.set_pixel(cx - 2 + x, cy - 2 + y, inner if dark else col)


# 只填完全透明像素(卡面:罐体已画好后补底色,不伤罐体圆角)
func _fill_bg_where_empty(img: Image, col: Color) -> void:
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			if img.get_pixel(x, y).a <= 0.0:
				img.set_pixel(x, y, col)


# 同心环底纹:只落在底色像素上(吸引主题的极淡圆环)
func _rings_where_empty(img: Image, c: Vector2, col: Color) -> void:
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			if img.get_pixel(x, y).a > 0.0:
				continue
			var d := Vector2(x - c.x, y - c.y).length()
			if absf(d - 43.0) < 1.0 or absf(d - 35.0) < 0.8 or absf(d - 27.0) < 0.6:
				img.set_pixel(x, y, col)


# 1px 深色外描边(透明底 sprite 用;同 _vanguard 的轮廓法,原地写回)
func _outline_silhouette(img: Image) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var bounds := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var outline := Color8(12, 14, 18)
	for y in range(h):
		for x in range(w):
			if img.get_pixel(x, y).a > 0.0:
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						var px := x + dx
						var py := y + dy
						if px >= 0 and px < w and py >= 0 and py < h:
							bounds.set_pixel(px, py, outline)
	for y in range(h):
		for x in range(w):
			if img.get_pixel(x, y).a > 0.0:
				bounds.set_pixel(x, y, img.get_pixel(x, y))
	img.blit_rect(bounds, Rect2i(0, 0, w, h), Vector2i.ZERO)
