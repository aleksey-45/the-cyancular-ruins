extends Node

# 录屏 / 死亡倒带服务（autoload: Recorder）。
#  - F5：960×720 抓帧视口 → worker JPEG q0.80 → 单文件 MJPEG AVI，落盘 exe 同目录 record/。
#  - 死亡倒带：常驻内存环形缓冲（640×480 JPEG，不落盘）；倒地按 R 时播放倒带到本局起点，
#    播完调 Level0.restart_single()。回放是纯表现，不改世界状态。
#
# 抓帧目标不是 1920 主视口：实测主视口 get_image() 26 ms/帧，必掉帧；960×720 视口读回约 4 ms。
# headless / Web 直接禁用（headless 视口纹理为空、Web 无 exe 伴随目录）。

const AviMjpegWriter := preload("res://core/present/record/avi_writer.gd")
const RewindTape := preload("res://core/present/record/rewind_tape.gd")
const REWIND_SHADER := preload("res://core/present/record/rewind_tape.gdshader")

const CAP_W := 960
const CAP_H := 720
const CAP_FPS := 60
const JPG_QUALITY := 0.80
const MAX_PENDING := 4

const TAPE_W := 640
const TAPE_H := 480
const TAPE_HZ := 30.0
const TAPE_QUALITY := 0.75
const TAPE_MAX_PENDING := 2

# ── UI 版式：对齐 HUD 的 24/32 系（ui/hud/hud.gd）──
# REWIND：顶部居中，做法与 HUD 时钟同款（anchor 0.5 + 对称 offset + 居中对齐）；
# REC：右上角，右边缘与击杀计数器同一条 -32 线，纵向排在击杀计数器下方。
const UI_MARGIN := 24.0
const REWIND_HALF_W := 240.0
const REWIND_FONT := 64          # 16 的倍数（UiFactory.style_control 会 assert）
const REC_FONT := 32             # 与 HUD 时钟同号
# 击杀计数器的 PanelContainer 右边缘是 -32，但它的文字还有 16px 右 content margin；
# REC 没有底板，要对齐的是**文字右缘**，所以取 32+16=48。
const REC_RIGHT := 48.0
const REC_TOP := 16.0 + 48.0 + 12.0 + 8.0   # 击杀计数器 top16 + 48 字 + 上下 margin 12 + 间距 8

var _enabled := true
var _cap: SubViewport = null
var _dir_root := ""

# ── F5 录制 ──
var _recording := false
var _draining := false
var _writer = null
var _path := ""
var _seq := 0
var _flushed_seq := -1
var _pending := 0
var _results: Array = []
var _mutex := Mutex.new()
var _last_path := ""
var _indicator: CanvasLayer = null
var _indicator_label: Label = null

# ── 死亡倒带 ──
var _tape = RewindTape.new()
var _run_t := 0.0
var _last_tape_t := -1.0
var _level_id := 0
var _player: Node = null
var _tape_pending := 0
var _tape_results: Array = []
var _tape_mutex := Mutex.new()

var _replaying := false
var _replay_elapsed := 0.0
var _sched: Dictionary = {}
var _tape_frames: Array = []
var _tape_ages: Array = []
var _decoded: Dictionary = {}
var _decoding: Dictionary = {}
var _decode_results: Array = []
var _decode_mutex := Mutex.new()
var _overlay: CanvasLayer = null
var _overlay_rect: ColorRect = null
var _overlay_label: Label = null
var _tape_mat: ShaderMaterial = null
var _tape_tex: ImageTexture = null
var _frame_seed := 0.0
var _tape_time := 0.0
var _last_speed := 1.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if DisplayServer.get_name() == "headless" or OS.has_feature("web"):
		_enabled = false
		set_process(false)
		set_process_input(false)
		return
	_dir_root = _record_dir()
	var err := DirAccess.make_dir_recursive_absolute(_dir_root)
	if err != OK:
		push_warning("Recorder: 无法创建录屏目录 %s (err=%d)，回退 user://record" % [_dir_root, err])
		_dir_root = "user://record"
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir_root))
	set_process_input(true)


func _record_dir() -> String:
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://").path_join("record")
	return OS.get_executable_path().get_base_dir().path_join("record")


func _input(event: InputEvent) -> void:
	if not _enabled:
		return
	if _replaying:
		# 演出中任意“跳过”键：R / 空格 / Esc / 左键
		if event.is_action_pressed("R") or event.is_action_pressed("ui_accept") \
				or event.is_action_pressed("ui_cancel") \
				or (event is InputEventMouseButton and event.pressed
					and event.button_index == MOUSE_BUTTON_LEFT):
			_finish_replay(true)
			get_viewport().set_input_as_handled()
		return
	var k := event as InputEventKey
	if k != null and k.pressed and not k.echo and k.physical_keycode == KEY_F5:
		if _active_level() != null:
			if _recording:
				stop_recording()
			else:
				start_recording()
			get_viewport().set_input_as_handled()
		return
	if _player != null and is_instance_valid(_player) and _player.is_downed() \
			and event.is_action_pressed("R"):
		if start_rewind():
			get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not _enabled:
		return
	var lvl := _active_level()
	if lvl == null:
		if _recording:
			stop_recording()
		if _draining:
			_finish_drain()
		if _replaying:
			_finish_replay(false)
		_reset_run()
		return
	if lvl.get_instance_id() != _level_id:
		_level_id = lvl.get_instance_id()
		_reset_run()
		_player = lvl.get_node_or_null("WorldViewport/Player")
	if _replaying:
		_tick_replay(delta, lvl)
		return

	_run_t += delta
	# 死亡带采样：F5 录制时每帧都抓（60Hz），否则按 TAPE_HZ 抽（30Hz）。
	var tape_due := _last_tape_t < 0.0 or (_run_t - _last_tape_t) >= (1.0 / TAPE_HZ)
	if _recording or tape_due:
		_ensure_capture()
		if _cap != null:
			var img: Image = _cap.get_texture().get_image()
			if img != null:
				if _recording:
					_submit_record(img)
				if tape_due:
					_last_tape_t = _run_t
					_submit_tape(img)
	_flush_record()
	_flush_tape()
	_flush_decodes()
	if _draining and _pending == 0:
		_finish_drain()


func _active_level() -> Level0:
	var scene := get_tree().current_scene
	if scene is Level0 and not Level0.pvp_mode:
		return scene as Level0
	return null


func _reset_run() -> void:
	_run_t = 0.0
	_last_tape_t = -1.0
	_tape.clear()
	_tape_pending = 0
	_tape_results.clear()
	_player = null


# ══════════════════════════ F5 普通录屏 ══════════════════════════

func start_recording() -> void:
	if not _enabled or _recording or _draining:
		return
	if _active_level() == null:
		return
	var dir := _dir_root.path_join("rec_" + _stamp())
	DirAccess.make_dir_recursive_absolute(dir)
	_path = dir.path_join("clip.avi")
	_writer = AviMjpegWriter.new()
	var err: Error = _writer.open(_path, CAP_W, CAP_H, CAP_FPS)
	if err != OK:
		push_error("Recorder: 打开 AVI 失败 %s (err=%d)" % [_path, err])
		_writer = null
		return
	_recording = true
	_draining = false
	_seq = 0
	_flushed_seq = -1
	_results.clear()
	_pending = 0
	_ensure_capture()
	_show_indicator(true)


func stop_recording() -> void:
	if not _recording:
		return
	_recording = false
	_draining = true
	_show_indicator(false)


func is_recording() -> bool:
	return _recording or _draining


func is_replaying() -> bool:
	return _replaying


func tape_size() -> int:
	return _tape.size()


func last_file_path() -> String:
	return _last_path


func _finish_drain() -> void:
	_flush_record()
	if _pending > 0:
		return
	if _writer != null:
		_writer.close()
		_last_path = _path
		print("[Recorder] 录屏结束: %s (%d 帧)" % [_path, _flushed_seq + 1])
	_writer = null
	_draining = false
	_recording = false


func _submit_record(img: Image) -> void:
	var seq := _seq
	_seq += 1
	_mutex.lock()
	var can := _pending < MAX_PENDING
	if can:
		_pending += 1
	_mutex.unlock()
	if can:
		WorkerThreadPool.add_task(_encode_record.bind(img, seq), false)


func _encode_record(img: Image, seq: int) -> void:
	var blob: PackedByteArray = img.save_jpg_to_buffer(JPG_QUALITY)
	_mutex.lock()
	_results.append({"seq": seq, "blob": blob})
	_pending -= 1
	_mutex.unlock()


func _flush_record() -> void:
	_mutex.lock()
	if _results.is_empty():
		_mutex.unlock()
		return
	var batch := _results
	_results = []
	_mutex.unlock()
	batch.sort_custom(func(a, b): return int(a["seq"]) < int(b["seq"]))
	for item in batch:
		var seq := int(item["seq"])
		if seq <= _flushed_seq:
			continue
		if _writer != null:
			_writer.add_frame(item["blob"])
		_flushed_seq = seq


# ══════════════════════════ 死亡带（内存） ══════════════════════════

func _submit_tape(img: Image) -> void:
	_tape_mutex.lock()
	var can := _tape_pending < TAPE_MAX_PENDING
	if can:
		_tape_pending += 1
	_tape_mutex.unlock()
	if can:
		WorkerThreadPool.add_task(_encode_tape.bind(img, _run_t), false)


func _encode_tape(img: Image, t_run: float) -> void:
	var small := img.duplicate() as Image
	small.resize(TAPE_W, TAPE_H, Image.INTERPOLATE_BILINEAR)
	var blob: PackedByteArray = small.save_jpg_to_buffer(TAPE_QUALITY)
	_tape_mutex.lock()
	_tape_results.append({"t": t_run, "blob": blob})
	_tape_pending -= 1
	_tape_mutex.unlock()


func _flush_tape() -> void:
	_tape_mutex.lock()
	if _tape_results.is_empty():
		_tape_mutex.unlock()
		return
	var batch := _tape_results
	_tape_results = []
	_tape_mutex.unlock()
	batch.sort_custom(func(a, b): return float(a["t"]) < float(b["t"]))
	for item in batch:
		_tape.append(float(item["t"]), item["blob"])


# ══════════════════════════ 倒带回放 ══════════════════════════

func start_rewind() -> bool:
	if _replaying:
		return true
	var lvl := _active_level()
	if lvl == null or _player == null or not is_instance_valid(_player):
		return false
	if not _player.is_downed():
		return false
	var frozen := _tape.freeze(_run_t)
	var frames: Array = frozen["frames"]
	if frames.size() < 8:
		return false
	var sched := RewindTape.schedule(float(frozen["run_seconds"]))
	if sched.is_empty():
		return false
	if _recording:
		stop_recording()
	_replaying = true
	_replay_elapsed = 0.0
	_sched = sched
	_tape_frames = frames
	_tape_ages = frozen["ages"]
	_decoded.clear()
	_decoding.clear()
	_decode_results.clear()
	_frame_seed = 0.0
	_tape_time = 0.0
	_last_speed = 1.0
	_ensure_overlay()
	_overlay.visible = true
	_overlay_label.visible = true
	_tape_mat.set_shader_parameter("film", 0.0)
	if _cap != null:
		_cap.render_target_update_mode = SubViewport.UPDATE_DISABLED
	get_tree().paused = true
	# 首帧预解码（死亡帧 + 前两帧）
	for j in mini(3, _tape_frames.size()):
		_request_decode(_tape_frames.size() - 1 - j)
	return true


func _tick_replay(delta: float, lvl: Level0) -> void:
	_flush_decodes()
	_replay_elapsed += delta
	_tape_time += delta
	var total: float = float(_sched["total"])
	var tau := minf(_replay_elapsed, total - 0.0001)
	var av := RewindTape.age_at(tau, _sched)
	var target_age := av.x
	var speed := maxf(av.y, 0.001)
	_last_speed = speed
	var idx := RewindTape.pick_index(_tape_ages, target_age)
	if idx >= 0:
		_request_decode(idx)
		# 预取：按当前速度往后看 2~3 个显示帧
		for k in range(1, 4):
			var a2 := RewindTape.age_at(minf(_replay_elapsed + float(k) / 60.0, total - 0.0001), _sched)
			var i2 := RewindTape.pick_index(_tape_ages, a2.x)
			_request_decode(i2)
		var img = _decoded.get(idx, null)
		if img != null:
			if _tape_tex == null:
				_tape_tex = ImageTexture.create_from_image(img)
			else:
				_tape_tex.update(img)
			_tape_mat.set_shader_parameter("tape_tex", _tape_tex)
	# 强度：进度 0→1；慢放段底片渐入
	var progress := clampf(target_age / maxf(float(_sched["D"]), 0.001), 0.0, 1.0)
	var x := clampf(log(maxf(speed, 1.0)) / log(512.0), 0.0, 1.0)
	var film := lerpf(0.0, 0.85, clampf(tau / 0.5, 0.0, 1.0))
	film = maxf(film, 0.85 + 0.15 * x)
	var flash := 0.0
	if _replay_elapsed > total - 0.10:
		flash = clampf((_replay_elapsed - (total - 0.10)) / 0.10, 0.0, 0.9)
	_tape_mat.set_shader_parameter("tape_time", _tape_time)
	_tape_mat.set_shader_parameter("frame_seed", _frame_seed)
	_tape_mat.set_shader_parameter("speed", speed)
	_tape_mat.set_shader_parameter("speed_norm", x)
	_tape_mat.set_shader_parameter("film", film)
	_tape_mat.set_shader_parameter("desat", 0.15)
	_tape_mat.set_shader_parameter("contrast_lift", 0.06)
	_tape_mat.set_shader_parameter("chroma_px", 1.0 + 7.0 * x)
	_tape_mat.set_shader_parameter("scan_alpha", 0.10 + 0.22 * x)
	_tape_mat.set_shader_parameter("noise_amt", 0.02 + 0.10 * x)
	_tape_mat.set_shader_parameter("tracking", 0.25 + 0.75 * x)
	_tape_mat.set_shader_parameter("vignette", 0.30 + 0.30 * x)
	_tape_mat.set_shader_parameter("wobble_px", 1.2 + 2.0 * x)
	_tape_mat.set_shader_parameter("roll", 0.002 * sin(_tape_time * 1.7))
	_tape_mat.set_shader_parameter("flash", flash)
	_tape_mat.set_shader_parameter("tape_px", Vector2(TAPE_W, TAPE_H))
	_frame_seed += 1.0
	_overlay_label.text = "REWIND ×%.0f" % speed
	if _replay_elapsed >= total:
		_finish_replay(true)


func _finish_replay(do_restart: bool) -> void:
	if not _replaying:
		return
	_replaying = false
	if _overlay != null:
		_overlay.visible = false
	if _overlay_label != null:
		_overlay_label.visible = false
	get_tree().paused = false
	_tape.clear()
	_tape_ages.clear()
	_tape_frames.clear()
	_decoded.clear()
	_decoding.clear()
	_decode_results.clear()
	_last_tape_t = -1.0
	_run_t = 0.0
	if _cap != null:
		_cap.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	if do_restart:
		var scene := get_tree().current_scene
		if scene is Level0:
			(scene as Level0).restart_single.call_deferred()


func _ensure_overlay() -> void:
	if _overlay != null:
		return
	_overlay = CanvasLayer.new()
	_overlay.name = "RewindOverlay"
	_overlay.layer = 140
	_overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	_overlay_rect = ColorRect.new()
	_overlay_rect.name = "Tape"
	_overlay_rect.color = Color(1, 1, 1, 1)
	_overlay_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_tape_mat = ShaderMaterial.new()
	_tape_mat.shader = REWIND_SHADER
	_overlay_rect.material = _tape_mat
	_overlay.add_child(_overlay_rect)
	_overlay_label = Label.new()
	_overlay_label.text = "REWIND"
	UiFactory.style_control(_overlay_label, REWIND_FONT)
	_overlay_label.add_theme_color_override("font_color", UiFactory.C_TEXT)
	_overlay_label.add_theme_color_override("font_outline_color", Color8(10, 12, 16, 200))
	_overlay_label.add_theme_constant_override("outline_size", 8)
	# 与 HUD 时钟同款居中：左右锚点都在 0.5、对称定宽、框内居中、横向双向生长。
	_overlay_label.anchor_left = 0.5
	_overlay_label.anchor_right = 0.5
	_overlay_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_overlay_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_overlay_label.offset_left = -REWIND_HALF_W
	_overlay_label.offset_right = REWIND_HALF_W
	_overlay_label.offset_top = UI_MARGIN
	_overlay_label.offset_bottom = UI_MARGIN
	_overlay_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(_overlay_label)
	_overlay.visible = false
	add_child(_overlay)


func _request_decode(idx: int) -> void:
	if idx < 0 or idx >= _tape_frames.size():
		return
	if _decoded.has(idx) or _decoding.has(idx):
		return
	_decoding[idx] = true
	WorkerThreadPool.add_task(_decode_task.bind(idx, _tape_frames[idx]), false)


func _decode_task(idx: int, blob: PackedByteArray) -> void:
	var img := Image.new()
	var err := img.load_jpg_from_buffer(blob)
	_decode_mutex.lock()
	_decode_results.append({"idx": idx, "img": img if err == OK else null})
	_decode_mutex.unlock()


func _flush_decodes() -> void:
	_decode_mutex.lock()
	if _decode_results.is_empty():
		_decode_mutex.unlock()
		return
	var batch := _decode_results
	_decode_results = []
	_decode_mutex.unlock()
	for item in batch:
		var idx := int(item["idx"])
		_decoding.erase(idx)
		if item["img"] != null:
			_decoded[idx] = item["img"]


# ══════════════════════════ 抓帧视口 / UI ══════════════════════════

func _ensure_capture() -> void:
	if _cap != null:
		return
	_cap = SubViewport.new()
	_cap.name = "RecordCaptureViewport"
	_cap.size = Vector2i(CAP_W, CAP_H)
	_cap.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_cap.transparent_bg = false
	var spr := Sprite2D.new()
	spr.name = "ScreenCopy"
	spr.texture = get_viewport().get_texture()
	spr.centered = false
	spr.position = Vector2.ZERO
	var root_size := get_viewport().get_visible_rect().size
	spr.scale = Vector2(float(CAP_W), float(CAP_H)) / root_size
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_cap.add_child(spr)
	add_child(_cap)


func _stamp() -> String:
	var d := Time.get_datetime_dict_from_system()
	return "%04d%02d%02d_%02d%02d%02d" % [
		int(d["year"]), int(d["month"]), int(d["day"]),
		int(d["hour"]), int(d["minute"]), int(d["second"])]


func _show_indicator(on: bool) -> void:
	if _indicator == null:
		_indicator = CanvasLayer.new()
		_indicator.name = "RecordIndicator"
		_indicator.layer = 200
		_indicator.process_mode = Node.PROCESS_MODE_ALWAYS
		var label := Label.new()
		label.text = "● REC"
		UiFactory.style_control(label, REC_FONT)
		label.add_theme_color_override("font_color", UiFactory.C_DANGER)
		label.add_theme_color_override("font_outline_color", Color8(10, 12, 16, 200))
		label.add_theme_constant_override("outline_size", 4)
		# 右上角：右边缘与击杀计数器同一条 -32 线，排在它下方；文字在定宽框内右对齐。
		label.anchor_left = 1.0
		label.anchor_right = 1.0
		label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		label.offset_left = -REC_RIGHT - 160.0
		label.offset_right = -REC_RIGHT
		label.offset_top = REC_TOP
		label.offset_bottom = REC_TOP
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_indicator.add_child(label)
		_indicator_label = label
		add_child(_indicator)
	if _indicator_label != null:
		_indicator.visible = on
