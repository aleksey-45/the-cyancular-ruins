extends ProbeBase

var _spr: Dictionary = {}
var _roots: Dictionary = {}
var _img: Image
const PLAYER_SCENE := "res://scenes/player/player.tscn"
const BODY_SCALE := 4.0
const BACKDROP := UiFactory.C_SURFACE
const PVP_GAME := "res://scenes/pvp_match_client.gd"
const BODY_TEXTURE := "res://assets/textures/player.png"
const OUT_DIR := "res://.test_logs"

func probe_id() -> String:
	return "HUE"

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var scene: PackedScene = load(PLAYER_SCENE)
	var bg := ColorRect.new()
	bg.color = BACKDROP
	bg.size = get_viewport().get_visible_rect().size
	add_child(bg)
	var game := PvpMatchClient.new()
	var saved_mode := PvpSession.room_mode
	var saved_role := PvpSession.role
	for entry in [["P1", 1, PvpSession.MODE_PVP, 1], ["P2", 2, PvpSession.MODE_PVP, 2],
			["队1", 1, PvpSession.MODE_TEAM, 1], ["队2", 2, PvpSession.MODE_TEAM, 2],
			["Royale", 1, PvpSession.MODE_ROYALE, 1]]:
		var index := _spr.size()
		var sprite := _spawn(scene, entry[0], Vector2(280 + (index % 3) * 600, 400 + (index / 3) * 500))
		_spr[entry[0]] = sprite
		PvpSession.room_mode = entry[2]
		PvpSession.role = entry[1]
		game._teams = {entry[1]: entry[3]}
		game._hues = {entry[1]: 120.0}
		game._tint(sprite, entry[1])
	_check(_spr["Royale"].material is ShaderMaterial, "大乱斗没有消费个人色相")
	PvpSession.room_mode = saved_mode
	PvpSession.role = saved_role
	game.free()
	await _frames(6)
	_img = await _shot("_hue_guard_p1_p2.png")
	_check(_same_rgb(_modal(_spr["P1"]), UiFactory.C_TEAM_A), "P1 颜色与队色不符")
	_check(_same_rgb(_modal(_spr["P2"]), UiFactory.C_TEAM_B), "P2 颜色与队色不符")
	_check(_same_rgb(_modal(_spr["队1"]), UiFactory.C_TEAM_A), "队 1 自身颜色错误")
	_check(_same_rgb(_modal(_spr["队2"]), UiFactory.C_TEAM_B), "队 2 自身颜色错误")
	_check(not _same_rgb(_modal(_spr["Royale"]), UiFactory.C_TEAM_A), "大乱斗色相未生效")
	_finish()


func _spawn(ps: PackedScene, key: String, pos: Vector2) -> AnimatedSprite2D:
	var p: Node2D = ps.instantiate()
	add_child(p)
	p.set_physics_process(false)
	p.scale = Vector2(BODY_SCALE, BODY_SCALE)
	p.position = pos
	_roots[key] = p
	var spr: AnimatedSprite2D = p.animator
	if spr == null:
		_check(false, "player.tscn 里没有 AnimatedSprite2D")
		return null
	# 冻到同一帧:防御性校验 A 要逐像素比较,各人动画帧不同就没法比
	spr.play(&"idle")
	spr.pause()
	spr.frame = 0
	return spr


# 身体矩形(图像像素)。用 sprite 自己的变换算,不假设 player.tscn 的内部偏移。
func _rect_px(spr: AnimatedSprite2D) -> Rect2i:
	if spr == null or _img == null:
		return Rect2i()
	var fr := spr.sprite_frames.get_frame_texture(spr.animation, spr.frame)
	if fr == null:
		return Rect2i()
	var sz: Vector2 = fr.get_size() * spr.global_scale
	var vs := get_viewport().get_visible_rect().size
	var s := float(_img.get_width()) / maxf(vs.x, 1.0)
	var r := Rect2((spr.global_position - sz * 0.5) * s, sz * s)
	return Rect2i(int(r.position.x), int(r.position.y), int(r.size.x), int(r.size.y))


# 矩形内"非背景"像素的众数 = 本体主色(它占不透明像素的 83.6%,众数稳定是它)。
func _modal(spr: AnimatedSprite2D) -> Color:
	var rc := _rect_px(spr)
	var hist: Dictionary = {}
	for y in range(maxi(rc.position.y, 0), mini(_img.get_height(), rc.position.y + rc.size.y)):
		for x in range(maxi(rc.position.x, 0), mini(_img.get_width(), rc.position.x + rc.size.x)):
			var c := _img.get_pixel(x, y)
			if absf(c.r - BACKDROP.r) < 0.02 and absf(c.g - BACKDROP.g) < 0.02 \
					and absf(c.b - BACKDROP.b) < 0.02:
				continue
			var k := Vector3i(roundi(c.r * 255.0), roundi(c.g * 255.0), roundi(c.b * 255.0))
			hist[k] = int(hist.get(k, 0)) + 1
	var best := Vector3i(0, 0, 0)
	var bn := -1
	for k in hist:
		if int(hist[k]) > bn:
			bn = int(hist[k])
			best = k
	return Color(best.x / 255.0, best.y / 255.0, best.z / 255.0)


# 8bit 量纲上的同色(截图往返有极小误差;口径仍是"逐字节相等")
func _same_rgb(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.004 and absf(a.g - b.g) < 0.004 and absf(a.b - b.b) < 0.004


func _hex(c: Color) -> String:
	return "#%02X%02X%02X" % [roundi(c.r * 255.0), roundi(c.g * 255.0), roundi(c.b * 255.0)]




func _frames(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


# - PNG 只是给人看的那一份,断言全在像素上  ->  落盘失败不算探针失败(否则
#   `.superpowers/sdd/`(gitignore 目录)在别的机器上不存在就会把防御性校验染红,理由还与本
#   guard 无关)。目录不存在就自己建。
func _shot(png_name: String) -> Image:
	await _frames(2)
	var img := get_viewport().get_texture().get_image()
	if img == null:
		return null
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(OUT_DIR)):
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var path := OUT_DIR.path_join(png_name)
	if img.save_png(path) != OK:
		print("[HUE-TINT] (提示)截图 %s 写入失败 —— 不影响断言,只是少了人眼那一份" % png_name)
	else:
		print("[HUE-TINT] 已存 %s" % ProjectSettings.globalize_path(path))
	return img
