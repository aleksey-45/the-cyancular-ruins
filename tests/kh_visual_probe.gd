extends Node

# L2 视觉验收探针(必须带真实渲染,--headless 下 get_image() 返回 null):
#   Godot_console --path . --quit-after 600 res://tests/kh_visual_probe.tscn
# 把受击红闪 / 命中 X / 击杀播报 / 连杀分别定格成 PNG 供控制者读图,同时打数值断言。
# 两条腿缺一不可:PNG 给肉眼判"画出来对不对",断言给 CI 判"数值/显隐对不对"。
# 为什么不能用 -s / --headless:PostProcess 的受击红闪是 shader 出图,CombatFeedback 的
# X 标记与骷髅是 _draw 自绘——两者都不进逻辑层,只有真实渲染后截屏才能证明"画出来了"。

const OUT_DIR := "res://.superpowers/sdd"

var _failures: Array[String] = []
var _pp: PostProcess = null
var _vp: SubViewport = null


func _ready() -> void:
	# 窗口尺寸实取(不写死:stretch/mode=viewport 下与工程设置解耦,改分辨率探针不失效)
	var win := get_viewport().get_visible_rect().size
	print("[VISUAL] 窗口可见区 = %s" % str(win))

	# 世界视口:一块纯色中灰,铺满(便于看红闪偏色——灰底偏红才读得出)
	_vp = SubViewport.new()
	_vp.size = Vector2i(win)
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)
	var bg := ColorRect.new()
	bg.color = Color(0.22, 0.26, 0.30)
	bg.size = win
	_vp.add_child(bg)

	# 后处理(受击红闪挂在它身上)
	_pp = PostProcess.new()
	_pp.world_viewport = _vp
	add_child(_pp)

	# 打击反馈层(spawn 内部是 call_deferred,下面两帧等它落树 + _ready)
	CombatFeedback.spawn(self)

	await get_tree().process_frame
	await get_tree().process_frame

	# 0) 基线
	var base: Image = await _shot("_visual_0_baseline.png")
	var base_px := _center(base)

	# 1) 受击红闪:flash_hit(1.0) 后中心像素应明显偏红
	_pp.flash_hit(1.0)
	await get_tree().process_frame
	var flash: Image = await _shot("_visual_1_hitflash.png")
	var flash_px := _center(flash)
	_check(flash_px.r > base_px.r + 0.15, "受击红闪未让画面变红(base.r=%.2f flash.r=%.2f)" % [base_px.r, flash_px.r])
	_check(flash_px.r > flash_px.b, "受击红闪偏色不对(r 应 > b)")
	print("[VISUAL] 红闪 基线中心=(%.2f,%.2f,%.2f) 闪后=(%.2f,%.2f,%.2f)" % [base_px.r, base_px.g, base_px.b, flash_px.r, flash_px.g, flash_px.b])

	# 让红闪衰减掉,免得污染后面几张
	await get_tree().create_timer(0.6).timeout

	# 2) 命中 X 标记:调后应可见,且在中心
	var t_hit := Time.get_ticks_msec()
	CombatFeedback.hit_marker()
	# 帧驱动(关键):X 只活 HIT_LIFE=0.22s,用真实时间等(create_timer)去截瞬态
	# 在低帧率下(首跑编译 shader / 机器负载)会越过存活期 → 截到空场。
	# 只等一帧:hit_age ≈ 一个帧时长(30fps≈33ms)恒 < 0.22s,与帧率无关地稳。
	await get_tree().process_frame
	var t_frame := Time.get_ticks_msec()
	await _shot("_visual_2_hitmarker.png")
	print("[VISUAL] X 标记 时序:1帧=%dms 到截图=%dms hit_age=%.3f visible=%s fps=%d" % [
		t_frame - t_hit, Time.get_ticks_msec() - t_hit, _hit_age(), str(_marker_visible()), Engine.get_frames_per_second()])
	_check(_marker_visible(), "命中 X 标记未显示")

	# 等 X 消失
	await get_tree().create_timer(0.4).timeout
	_check(not _marker_visible(), "命中 X 标记未按时消失")

	# 3) 击杀播报(含骷髅 + x1)
	CombatFeedback.kill("测试鸟")
	await get_tree().process_frame
	await get_tree().create_timer(0.12).timeout
	await _shot("_visual_3_kill.png")
	var txt := _kill_text()
	_check("测试鸟" in txt, "击杀播报文本里没有受害者名(实际:%s)" % txt)

	# 4) 连杀:窗口内再杀一只 → x2
	CombatFeedback.kill("第二只")
	await get_tree().process_frame
	await get_tree().create_timer(0.12).timeout
	await _shot("_visual_4_streak.png")
	_check(_streak_text() == "x2", "连杀计数不对(实际:%s)" % _streak_text())

	_finish()


# 截图:等两帧确保画完,存 PNG 并返回 Image(供数值断言)
func _shot(name: String) -> Image:
	await get_tree().process_frame
	await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	if img == null:
		_failures.append("截图 %s 失败(get_image 返回 null——是不是误加了 --headless?)" % name)
		return Image.new()
	var path := OUT_DIR.path_join(name)
	var err := img.save_png(path)
	if err != OK:
		_failures.append("截图 %s 写入失败(err=%d,path=%s)" % [name, err, path])
	print("[VISUAL] 已存 ", path, " ", img.get_width(), "x", img.get_height())
	return img


func _center(img: Image) -> Color:
	if img.get_width() == 0:
		return Color.BLACK
	return img.get_pixel(img.get_width() / 2, img.get_height() / 2)


# 反馈层成员的取值口(统一判空:CombatFeedback 没落树时断言应失败而非崩在 null 上)
func _marker_visible() -> bool:
	return CombatFeedback.current != null and CombatFeedback.current._marker.visible


func _hit_age() -> float:
	if CombatFeedback.current == null:
		return -1.0
	return CombatFeedback.current._hit_age


func _kill_text() -> String:
	if CombatFeedback.current == null:
		return ""
	return CombatFeedback.current._kill_label.text


func _streak_text() -> String:
	if CombatFeedback.current == null:
		return ""
	return CombatFeedback.current._streak_label.text


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_failures.append(msg)


func _finish() -> void:
	if _failures.is_empty():
		print("KH VISUAL PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("KH VISUAL PROBE: FAIL | " + "; ".join(_failures))
		get_tree().quit(1)
