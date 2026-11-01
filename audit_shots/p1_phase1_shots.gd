extends Node

# 【一次性】Phase 1 暂停菜单取图夹具(收尾删除)。固定在纯色底上,不拉世界(随机地图/动画不进图)。
# 用法(★ 不带 --headless):
#   "<GODOT>" --path . --quit-after 600 res://audit_shots/p1_phase1_shots.tscn -- docs/archive/audit/2026-10-27-ui/p1/phase1/before
# 迁移前:PauseMenu.new(bool) 现建节点;迁移后:res://ui/screens/pause_menu.tscn 存在 ⇒ 走场景。
# 同一夹具前后各跑一次,逐像素 diff 必须全 0。

const CLEAR_BG := Color(0.07, 0.08, 0.10, 1.0)

var _out := ""
var _fails := 0


func _ready() -> void:
	await get_tree().process_frame
	var argv := OS.get_cmdline_user_args()
	if argv.is_empty():
		print("P1P1SHOT: FAIL 缺输出子目录")
		get_tree().quit(1)
		return
	var sub := str(argv[0]).trim_prefix("/")
	_out = sub if sub.begins_with("res://") else "res://" + sub
	if not _out.ends_with("/"):
		_out += "/"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out))
	await _shot("pause_sp", false)
	await _shot("pause_pvp", true)
	print("P1P1SHOT: DONE fails=%d" % _fails)
	get_tree().quit(0 if _fails == 0 else 1)


func _shot(name: String, is_pvp: bool) -> void:
	var bg := ColorRect.new()
	bg.color = CLEAR_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	await get_tree().process_frame
	var pm: Node = null
	if ResourceLoader.exists("res://ui/screens/pause_menu.tscn"):
		var ps: PackedScene = load("res://ui/screens/pause_menu.tscn")
		pm = ps.instantiate()
		pm.set("is_pvp", is_pvp)
	else:
		pm = PauseMenu.new()
		pm.set("is_pvp", is_pvp)
	add_child(pm)
	await get_tree().process_frame
	pm.call("open")
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	var tex := get_viewport().get_texture()
	var img: Image = tex.get_image() if tex != null else null
	if img == null:
		print("P1P1SHOT: FAIL 取不到视口纹理 %s" % name)
		_fails += 1
	else:
		var path := _out + name + ".png"
		var err := img.save_png(path)
		print("P1P1SHOT: SHOT %s err=%d %dx%d" % [path, err, img.get_width(), img.get_height()])
		if err != OK:
			_fails += 1
	pm.call("close")
	await get_tree().process_frame
	remove_child(pm)
	pm.queue_free()
	remove_child(bg)
	bg.queue_free()
	await get_tree().process_frame
