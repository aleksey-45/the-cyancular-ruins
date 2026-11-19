extends Node

# 录屏 / 死亡倒带服务（autoload: Recorder）。
# F5：读主视口纹理（1920×1440 原生 1:1）→ worker JPEG q0.95 → AVI 临时文件 + 同录 WAV → 停录后 worker 转 H.264/AAC MP4（无 ffmpeg 回退 AVI+WAV）。规格见 docs/录屏与死亡倒带设计.md。
# 录制用 30 fps 槽位时钟（Time.get_ticks_usec），缺帧重复同一帧补齐 ⇒ 视频时长恒等于真实时长，死亡重开不打断。
# 死亡倒带：内存 640×480 环形缓冲，倒地按 R 回放到本局起点后调 Level0.restart_single()，纯表现不改世界状态。
# headless / Web 直接禁用。

const AviMjpegWriter := preload("res://core/present/record/avi_writer.gd")
const FfmpegTranscode := preload("res://core/present/record/ffmpeg_transcode.gd")
const WavWriter := preload("res://core/present/record/wav_writer.gd")
const RecorderAudio := preload("res://core/present/record/recorder_audio.gd")
const RewindTape := preload("res://core/present/record/rewind_tape.gd")
const REWIND_SHADER := preload("res://core/present/record/rewind_tape.gdshader")

const CAP_FPS := 30
const JPG_QUALITY := 0.95
const MAX_PENDING := 4

const TAPE_CAP_W := 960
const TAPE_CAP_H := 720
const TAPE_W := 640
const TAPE_H := 480
const TAPE_HZ := 30.0
const TAPE_QUALITY := 0.75
const TAPE_MAX_PENDING := 2

# ── UI 版式：对齐 HUD 的 24/32 系（ui/hud/hud.gd）──
# REWIND：顶部居中，做法与 HUD 时钟同款（anchor 0.5 + 对称 offset + 居中对齐）；
const UI_MARGIN := 24.0
const REWIND_HALF_W := 240.0
const REWIND_FONT := 64          # 16 的倍数（UiFactory.style_control 会 assert）

var _enabled := true
var _cap: SubViewport = null
var _cap_spr: Sprite2D = null
var _dir_root := ""

# ── F5 录制 ──
var _recording := false
var _draining := false
var _writer = null
var _wav = null
var _path := ""
var _wav_path := ""
var _pending := 0
var _results: Array = []
var _mutex := Mutex.new()
var _last_path := ""
var _rec_start_usec := 0
var _rec_capture_slot := -1
var _rec_written_slots := 0
var _rec_final_slots := 0
var _rec_last_blob := PackedByteArray()
var _audio = null

# ── MP4 后编码（worker 线程；主线程每帧轮询完成） ──
var _ffmpeg := ""
var _rec_crf := 22
var _transcodes: Array = []
var _tc_mutex := Mutex.new()

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
	_audio = RecorderAudio.new(self)
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
	_ffmpeg = FfmpegTranscode.resolve(OS.get_environment(FfmpegTranscode.FFMPEG_ENV))
	_rec_crf = FfmpegTranscode.resolve_crf(OS.get_environment(FfmpegTranscode.CRF_ENV))
	if _ffmpeg == "":
		print("[Recorder] 未检测到 ffmpeg：F5 录屏保留 MJPEG AVI + WAV")
	else:
		print("[Recorder] ffmpeg: %s（录屏停止后后台转 H.264 CRF %d + AAC 的 MP4）" % [_ffmpeg, _rec_crf])
	set_process_input(true)


func _record_dir() -> String:
	if OS.has_feature("editor"):
		return ProjectSettings.globalize_path("res://").path_join("record")
	return OS.get_executable_path().get_base_dir().path_join("record")


func _input(event: InputEvent) -> void:
	if not _enabled:
		return
	var k := event as InputEventKey
	if _replaying:
		if k != null and k.pressed and not k.echo and k.physical_keycode == KEY_F5:
			if _recording:
				stop_recording()
			get_viewport().set_input_as_handled()
			return
		# 演出中任意“跳过”键：R / 空格 / Esc / 左键
		if event.is_action_pressed("R") or event.is_action_pressed("ui_accept") \
				or event.is_action_pressed("ui_cancel") \
				or (event is InputEventMouseButton and event.pressed
					and event.button_index == MOUSE_BUTTON_LEFT):
			_finish_replay(true)
			get_viewport().set_input_as_handled()
		return
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
	_poll_transcodes()
	var lvl := _active_level()
	if lvl == null:
		if _recording:
			stop_recording()
		_tick_capture(false)
		if _draining and _pending == 0:
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
		_tick_capture(false)
		if _draining and _pending == 0:
			_finish_drain()
		_tick_replay(delta, lvl)
		return

	_run_t += delta
	var tape_due := _last_tape_t < 0.0 or (_run_t - _last_tape_t) >= (1.0 / TAPE_HZ)
	_tick_capture(tape_due)
	_flush_tape()
	_flush_decodes()
	if _draining and _pending == 0:
		_finish_drain()


func _tick_capture(tape_due: bool) -> void:
	if _recording:
		var elapsed := float(Time.get_ticks_usec() - _rec_start_usec) / 1000000.0
		var slot := int(floor(elapsed * float(CAP_FPS)))
		if slot > _rec_capture_slot:
			var img: Image = get_viewport().get_texture().get_image()
			if img != null:
				_rec_capture_slot = slot
				_submit_record(img, slot)
				# ★ 录制期死亡带复用同一张整帧，在 worker 里 resize，不额外读回第二张图。
				if tape_due:
					_last_tape_t = _run_t
					_submit_tape(img)
	elif tape_due:
		_ensure_capture()
		var img: Image = _cap.get_texture().get_image()
		if img != null:
			_last_tape_t = _run_t
			_submit_tape(img)
	if _recording or _draining:
		_drain_audio()
		_flush_record()


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
	_wav_path = dir.path_join("clip.wav")
	var root_size := get_viewport().get_visible_rect().size
	_writer = AviMjpegWriter.new()
	var err: Error = _writer.open(_path, int(root_size.x), int(root_size.y), CAP_FPS)
	if err != OK:
		push_error("Recorder: 打开 AVI 失败 %s (err=%d)" % [_path, err])
		_writer = null
		return
	_wav = WavWriter.new()
	var aerr: Error = _wav.open(_wav_path, AudioServer.get_mix_rate())
	if aerr != OK:
		push_warning("Recorder: 打开 WAV 失败 %s (err=%d)，本次只录视频" % [_wav_path, aerr])
		_wav = null
	_attach_audio()
	_recording = true
	_draining = false
	_rec_start_usec = Time.get_ticks_usec()
	_rec_capture_slot = -1
	_rec_written_slots = 0
	_rec_final_slots = 0
	_rec_last_blob = PackedByteArray()
	_results.clear()
	_pending = 0
	_clear_audio_capture()
	_show_indicator(true)


func stop_recording() -> void:
	if not _recording:
		return
	var elapsed := float(Time.get_ticks_usec() - _rec_start_usec) / 1000000.0
	if _rec_capture_slot < 0:
		var img: Image = get_viewport().get_texture().get_image()
		if img != null:
			_rec_capture_slot = 0
			_submit_record(img, 0)
	_rec_final_slots = maxi(_rec_written_slots, int(round(elapsed * float(CAP_FPS))))
	_recording = false
	_draining = true
	_drain_audio()
	_show_indicator(false)


func is_recording() -> bool:
	return _recording or _draining


func is_transcoding() -> bool:
	return not _transcodes.is_empty()


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
	if _writer == null:
		if _wav != null:
			_wav.close()
			_wav = null
		_detach_audio()
		_draining = false
		return
	var total := maxi(_rec_final_slots, _rec_written_slots)
	if total <= 0:
		total = 1
	while _rec_written_slots < total and not _rec_last_blob.is_empty():
		_writer.add_frame(_rec_last_blob)
		_rec_written_slots += 1
	var frames: int = _writer.frame_count()
	_writer.close()
	_writer = null
	_drain_audio()
	var wav_frames := 0
	if _wav != null:
		wav_frames = _wav.frame_count()
		_wav.close()
		_wav = null
	_detach_audio()
	var avi := _path
	var wav := _wav_path
	_draining = false
	if _ffmpeg == "":
		_last_path = avi
		print("[Recorder] 录屏结束: %s (%d 帧, MJPEG AVI；未检测到 ffmpeg，保留 AVI+WAV)" % [avi, frames])
		return
	var mp4 := avi.get_base_dir().path_join(avi.get_file().get_basename() + ".mp4")
	var job := {"avi": avi, "wav": wav, "mp4": mp4, "frames": frames, "wav_frames": wav_frames,
			"done": false, "ok": false, "log": "", "audio": false}
	_tc_mutex.lock()
	_transcodes.append(job)
	_tc_mutex.unlock()
	print("[Recorder] 录屏写好: %s (%d 帧, %d 音频帧)，后台转码 MP4…" % [avi, frames, wav_frames])
	WorkerThreadPool.add_task(_transcode_task.bind(job), false)


func _transcode_task(job: Dictionary) -> void:
	var r: Dictionary = FfmpegTranscode.transcode(
			_ffmpeg, String(job["avi"]), String(job["wav"]), String(job["mp4"]), _rec_crf)
	_tc_mutex.lock()
	job["ok"] = bool(r.get("ok", false))
	job["log"] = String(r.get("log", ""))
	job["audio"] = bool(r.get("audio", false))
	job["done"] = true
	_tc_mutex.unlock()


func _poll_transcodes() -> void:
	if _transcodes.is_empty():
		return
	var finished: Array = []
	_tc_mutex.lock()
	for job in _transcodes:
		if bool(job["done"]):
			finished.append(job)
	for job in finished:
		_transcodes.erase(job)
	_tc_mutex.unlock()
	for job in finished:
		_finish_transcode(job)


func _finish_transcode(job: Dictionary) -> void:
	var avi := String(job["avi"])
	var wav := String(job["wav"])
	var mp4 := String(job["mp4"])
	var frames := int(job["frames"])
	if bool(job["ok"]):
		var del_avi := DirAccess.remove_absolute(avi)
		var del_wav := OK
		if FileAccess.file_exists(wav):
			del_wav = DirAccess.remove_absolute(wav)
		_last_path = mp4
		var extra := "" if (del_avi == OK and del_wav == OK) else "；AVI/WAV 删除失败，两版并存"
		var audio := "" if bool(job["audio"]) else "（无音频流）"
		print("[Recorder] 录屏结束: %s (%d 帧, H.264%s MP4%s)" % [mp4, frames, audio, extra])
		return
	_last_path = avi
	var log := String(job["log"]).replace("\n", " ").strip_edges()
	if log.length() > 300:
		log = log.substr(0, 300) + "…"
	print("[Recorder] 录屏结束: %s (%d 帧, MJPEG AVI；ffmpeg 转码失败: %s)" % [avi, frames, log])


func _attach_audio() -> void:
	_audio.attach_audio()


func _detach_audio() -> void:
	_audio.detach_audio()


func _drain_audio() -> void:
	_audio.drain_audio(_wav)


func _clear_audio_capture() -> void:
	_audio.clear_capture()


func _submit_record(img: Image, slot: int) -> void:
	_mutex.lock()
	var can := _pending < MAX_PENDING
	if can:
		_pending += 1
	_mutex.unlock()
	if can:
		WorkerThreadPool.add_task(_encode_record.bind(img, slot), false)


func _encode_record(img: Image, slot: int) -> void:
	var blob: PackedByteArray = img.save_jpg_to_buffer(JPG_QUALITY)
	_mutex.lock()
	_results.append({"slot": slot, "blob": blob})
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
	batch.sort_custom(func(a, b): return int(a["slot"]) < int(b["slot"]))
	for item in batch:
		var slot := int(item["slot"])
		var count := slot - _rec_written_slots + 1
		if count < 1 or _writer == null:
			continue
		var blob: PackedByteArray = item["blob"]
		for _i in count:
			_writer.add_frame(blob)
		_rec_written_slots += count
		_rec_last_blob = blob


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
	if _cap == null:
		_cap = SubViewport.new()
		_cap.name = "RecordCaptureViewport"
		_cap.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		_cap.transparent_bg = false
		_cap_spr = Sprite2D.new()
		_cap_spr.name = "ScreenCopy"
		_cap_spr.texture = get_viewport().get_texture()
		_cap_spr.centered = false
		_cap_spr.position = Vector2.ZERO
		_cap_spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		_cap.add_child(_cap_spr)
		add_child(_cap)
	var size := Vector2i(TAPE_CAP_W, TAPE_CAP_H)
	if _cap.size != size:
		_cap.size = size
	_cap_spr.scale = Vector2(TAPE_CAP_W, TAPE_CAP_H) / get_viewport().get_visible_rect().size


func _stamp() -> String:
	return _audio.stamp()


func _show_indicator(on: bool) -> void:
	_audio.show_indicator(on)
