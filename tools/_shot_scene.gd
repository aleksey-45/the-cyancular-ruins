extends Node

# 【一次性校验工具】把任意 `.tscn` 当子节点挂上、跑几帧、存一张图。
# 用途:把 `tools/gen_menu_scene` 导出的骨架**画出来**,与改前的基线图逐像素比对
# —— 这是"迁移 = 外观不变"唯一的判据(静态检查看不出渲染差异)。
#
# 用法(★ **不带 `--headless`** —— headless 下 root 视口纹理是空壳,取图静默为空):
#   "<GODOT>" --path . res://tools/_shot_scene.tscn -- <res://某个.tscn> <输出文件名.png> [方法名 ...]
#
# ★ 可选**方法名**存在的理由:大厅那三个弹层是"启动即建、默认隐藏"的 —— 要取到
#   「加入面板开 / 创建弹层开 / 等待室开」这三张**打开态**的图,只能像玩家那样先调一次
#   打开方法(`_toggle_join_panel` / `_open_create_dialog`)。**按顺序**调、每个之间等 2 帧
#   (方法里可能改可见性/尺寸,同帧连调会读到中间态)。方法名不存在 ⇒ 当场判失败退出:
#   静默跳过就等于"取了一张没打开任何东西的图",而它与真·打开态在文件名上分不出来。
#   ★ 参数只能给**方法名**(命令行传不了字典)—— 需要实参的相(如 `_show_wait_room(state, mode)`)
#     由 `.superpowers/sdd/_gen/` 下的**一次性驱动脚本**按同一份夹具喂(见 t1 报告)。

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		print("SHOT: 用法 `-- <res://场景> <输出名.png> [方法名 ...]`")
		get_tree().quit(1)
		return
	var src := str(args[0])
	var out := str(args[1])
	var ps: PackedScene = load(src)
	if ps == null:
		print("SHOT: FAIL 读不到 %s" % src)
		get_tree().quit(1)
		return
	var root: Node = ps.instantiate()
	add_child(root)
	# 实例化即 `add_child`:下面这些方法都假定自己已入树(锚点/尺寸依赖父级尺寸)。
	for i in range(2, args.size()):
		var m := str(args[i])
		if not root.has_method(m):
			print("SHOT: FAIL 无此方法 %s" % m)
			get_tree().quit(1)
			return
		root.call(m)
		for f in 2:
			await get_tree().process_frame
	for i in 4:
		await get_tree().process_frame
	var img: Image = get_viewport().get_texture().get_image()
	if img == null:
		print("SHOT: FAIL 取不到视口纹理")
		get_tree().quit(1)
		return
	var path := "res://.superpowers/sdd/_gen/" + out
	var err := img.save_png(path)
	print("SHOT: %s → %s(err=%d, %dx%d)" % [src.get_file(), path, err, img.get_width(),
			img.get_height()])
	get_tree().quit(0 if err == OK else 1)
