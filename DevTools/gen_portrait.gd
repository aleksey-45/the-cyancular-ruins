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
