extends Node

# 【一次性校验工具】把任意 `.tscn` 当子节点挂上、跑几帧、存一张图。
# 用途:把 `tools/gen_menu_scene` 导出的骨架**画出来**,与改前的基线图逐像素比对
# —— 这是"迁移 = 外观不变"唯一的判据(静态检查看不出渲染差异)。
#
# 用法(★ **不带 `--headless`** —— headless 下 root 视口纹理是空壳,取图静默为空):
#   "<GODOT>" --path . res://tools/_shot_scene.tscn -- <res://某个.tscn> <输出文件名.png>

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		print("SHOT: 用法 `-- <res://场景> <输出名.png>`")
		get_tree().quit(1)
		return
	var src := str(args[0])
	var out := str(args[1])
	var ps: PackedScene = load(src)
	if ps == null:
		print("SHOT: FAIL 读不到 %s" % src)
		get_tree().quit(1)
		return
	add_child(ps.instantiate())
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
