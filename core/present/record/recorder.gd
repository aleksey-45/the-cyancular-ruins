extends Node

# siri P3 录像 / 死亡倒带服务：挂在 scenes/match_view.tscn 的 Recorder 节点上（每个对局一份）。
# F5：读 root viewport 窗口纹理（1920×1440，含 HUD/后处理）→ worker JPEG q0.95 → MJPEG AVI +
#     Master 音频 WAV；停录后后台转 H.264/AAC MP4（无 ffmpeg 保留 AVI+WAV）。文件写 user://recordings/。
# 30fps 槽位时钟（Time.get_ticks_usec）：缺帧重复同一帧补齐 ⇒ 视频时长恒等于真实时长。
# 死亡倒带：solo 内存 640×480 环形缓冲，倒地 R 键回放（纯表现，不改模拟），播完调 SoloLevel.restart_single()。
# headless / Web 直接禁用；服务器模式没有 MatchView，天然不录。
# 相对 main 的适配：采集源从 main 的 Level0 换成 siri MatchView 的窗口纹理；REC/REWIND 走 UiDesign v2；
# 重开调 siri 现有 SoloLevel.restart_single()；落盘目录改 user://recordings/。
# ★ P3b 接线（未接，等 P1 完成/Lead 确认）：siri 本地的死亡 R 目前由 scenes/solo_level.gd 自己接管
#   （模拟回溯）。实测 _input 派发顺序是 SoloLevel 先于 Recorder 子节点，Recorder 抢不到这个键，
#   所以这里只提供 start_rewind() / is_replaying() 公开入口；接线只需在 SoloLevel._input 里先调
#   `$View/Recorder.start_rewind()`（成功就 set_input_as_handled 并 return），见任务报告。

const AviMjpegWriter := preload("res://core/present/record/avi_writer.gd")
const WavWriter := preload("res://core/present/record/wav_writer.gd")
const RecorderAudio := preload("res://core/present/record/recorder_audio.gd")
const RewindTape := preload("res://core/present/record/rewind_tape.gd")
const FfmpegTranscode := preload("res://core/present/record/ffmpeg_transcode.gd")
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

const RECORD_DIR := "user://recordings"
# REWIND 巨字：main 用 64，这里同样落在像素字体 16 的倍数上（T_HUGE=128 的一半）。
const REWIND_FONT := UiDesign.T_HUGE / 2


# ── worker 任务：都是自持 RefCounted，线程只碰自己，宿主节点先被释放也不崩 ──
class RecordJob extends RefCounted:
	var mutex := Mutex.new()
	var done := false
	var slot := 0
	var blob := PackedByteArray()

	func encode(img: Image, quality: float) -> void:
		var bytes: PackedByteArray = img.save_jpg_to_buffer(quality)
		mutex.lock()
		blob = bytes
		done = true
		mutex.unlock()


class TapeJob extends RefCounted:
	var mutex := Mutex.new()
	var done := false
	var t := 0.0
	var blob := PackedByteArray()

	func encode(img: Image, quality: float, width: int, height: int) -> void:
		var small := img.duplicate() as Image
		small.resize(width, height, Image.INTERPOLATE_BILINEAR)
		var bytes: PackedByteArray = small.save_jpg_to_buffer(quality)
		mutex.lock()
		blob = bytes
		done = true
		mutex.unlock()


class DecodeJob extends RefCounted:
	var mutex := Mutex.new()
	var done := false
	var idx := 0
	var img: Image = null

	func decode(blob: PackedByteArray) -> void:
		var image := Image.new()
		var err := image.load_jpg_from_buffer(blob)
		mutex.lock()
		img = image if err == OK else null
		done = true
		mutex.unlock()


class TranscodeJob extends RefCounted:
	const FfmpegTranscode := preload("res://core/present/record/ffmpeg_transcode.gd")
	var mutex := Mutex.new()
	var done := false
	var ok := false
	var log_text := ""
	var has_audio := false

	func encode(ffmpeg: String, avi: String, wav: String, mp4: String, crf: int) -> void:
		var r: Dictionary = FfmpegTranscode.transcode(ffmpeg, avi, wav, mp4, crf)
		mutex.lock()
		ok = bool(r.get("ok", false))
		log_text = String(r.get("log", ""))
		has_audio = bool(r.get("audio", false))
		done = true
		mutex.unlock()


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
var _record_jobs: Array = []
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

# ── 死亡倒带 ──
var _tape = RewindTape.new()
var _run_t := 0.0
var _last_tape_t := -1.0
var _match_id := 0
var _solo = null
var _player = null
var _tape_jobs: Array = []
var _tape_pending := 0

var _replaying := false
var _replay_elapsed := 0.0
var _sched: Dictionary = {}
var _tape_frames: Array = []
var _tape_ages: Array = []
var _decoded: Dictionary = {}
var _decoding: Dictionary = {}
var _decode_jobs: Array = []
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
	_audio = RecorderAudio.new(self)
	_dir_root = ProjectSettings.globalize_path(RECORD_DIR)
	var err := DirAccess.make_dir_recursive_absolute(_dir_root)
	if err != OK and err != ERR_ALREADY_EXISTS:
		push_warning("Recorder: 无法创建录屏目录 %s (err=%d)" % [_dir_root, err])
	_ffmpeg = FfmpegTranscode.resolve(OS.get_environment(FfmpegTranscode.FFMPEG_ENV))
	_rec_crf = FfmpegTranscode.resolve_crf(OS.get_environment(FfmpegTranscode.CRF_ENV))
	if _ffmpeg == "":
		print("[Recorder] 未检测到 ffmpeg：F5 录屏保留 MJPEG AVI + WAV（%s）" % _dir_root)
	else:
		print("[Recorder] ffmpeg: %s（录屏停止后后台转 H.264 CRF %d + AAC 的 MP4）" % [_ffmpeg, _rec_crf])
	set_process_input(true)


# 场景切换会连同 MatchView 一起释放 Recorder：收尾尚未关闭的文件，避免半截 AVI。
func _exit_tree() -> void:
	if not _enabled:
		return
	if _replaying:
		_finish_replay(false)
	if _recording:
		stop_recording()
	if _draining:
		_drain_workers_sync()
		_finish_drain(false)


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
		if _active_match() != null:
			if _recording:
				stop_recording()
			else:
				start_recording()
			get_viewport().set_input_as_handled()
		return


func _process(delta: float) -> void:
	if not _enabled:
		return
	_poll_transcodes()
	var match := _active_match()
	if match == null:
		if _recording:
			stop_recording()
		_tick_capture(false)
		if _draining and _record_pending() == 0:
			_finish_drain()
		if _replaying:
			_finish_replay(false)
		_reset_run()
		return
	var solo = match as SoloLevel
	if match.get_instance_id() != _match_id:
		_match_id = match.get_instance_id()
		_reset_run()
	_solo = solo
	_player = match.player
	if _replaying:
		_tick_capture(false)
		if _draining and _record_pending() == 0:
			_finish_drain()
		_tick_replay(delta)
		return

	_run_t += delta
	var tape_due := solo != null \
			and (_last_tape_t < 0.0 or (_run_t - _last_tape_t) >= (1.0 / TAPE_HZ))
	_tick_capture(tape_due)
	_flush_tape()
	_flush_decodes()
	if _draining and _record_pending() == 0:
		_finish_drain()


func _active_match() -> MatchController:
	var scene := get_tree().current_scene
	if scene is MatchController:
		return scene as MatchController
	return null


func _reset_run() -> void:
	_run_t = 0.0
	_last_tape_t = -1.0
	_tape.clear()
	_tape_pending = 0
	_tape_jobs.clear()
	_player = null
	_solo = null


# ══════════════════════════ F5 普通录屏 ══════════════════════════

func start_recording() -> void:
	if not _enabled or _recording or _draining:
		return
	if _active_match() == null:
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
	_audio.attach_audio()
	_recording = true
	_draining = false
	_rec_start_usec = Time.get_ticks_usec()
	_rec_capture_slot = -1
	_rec_written_slots = 0
	_rec_final_slots = 0
	_rec_last_blob = PackedByteArray()
	_record_jobs.clear()
	_audio.clear_capture()
	_audio.show_indicator(true)
	print("[Recorder] 开始录屏: %s (%dx%d @%dfps)" % [_path, int(root_size.x), int(root_size.y), CAP_FPS])


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
	_audio.drain_audio(_wav)
	_audio.show_indicator(false)


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


func record_dir() -> String:
	return _dir_root


func _record_pending() -> int:
	var n := 0
	for job in _record_jobs:
		job.mutex.lock()
		var done: bool = job.done
		job.mutex.unlock()
		if not done:
			n += 1
	return n


func _drain_workers_sync() -> void:
	var deadline := Time.get_ticks_msec() + 2000
	while _record_pending() > 0 and Time.get_ticks_msec() < deadline:
		OS.delay_msec(2)
		_flush_record()


func _finish_drain(allow_transcode := true) -> void:
	_flush_record()
	if _record_pending() > 0 or not _record_jobs.is_empty():
		return
	if _writer == null:
		if _wav != null:
			_wav.close()
			_wav = null
		_audio.detach_audio()
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
	_audio.drain_audio(_wav)
	var wav_frames := 0
	if _wav != null:
		wav_frames = _wav.frame_count()
		_wav.close()
		_wav = null
	_audio.detach_audio()
	var avi := _path
	var wav := _wav_path
	_draining = false
	if _ffmpeg == "" or not allow_transcode:
		_last_path = avi
		var why := "未检测到 ffmpeg，保留 AVI+WAV" if _ffmpeg == "" else "退出对局，跳过 MP4 转码（保留 AVI+WAV）"
		print("[Recorder] 录屏结束: %s (%d 帧, MJPEG AVI；%s)" % [avi, frames, why])
		return
	var mp4 := avi.get_base_dir().path_join(avi.get_file().get_basename() + ".mp4")
	var job := TranscodeJob.new()
	_transcodes.append({"job": job, "avi": avi, "wav": wav, "mp4": mp4, "frames": frames,
			"wav_frames": wav_frames})
	WorkerThreadPool.add_task(job.encode.bind(_ffmpeg, avi, wav, mp4, _rec_crf), false)
	print("[Recorder] 录屏写好: %s (%d 帧, %d 音频帧)，后台转码 MP4…" % [avi, frames, wav_frames])


func _poll_transcodes() -> void:
	if _transcodes.is_empty():
		return
	var finished: Array = []
	var rest: Array = []
	for entry in _transcodes:
		var job: TranscodeJob = entry["job"]
		job.mutex.lock()
		var done: bool = job.done
		job.mutex.unlock()
		if done:
			finished.append(entry)
		else:
			rest.append(entry)
	_transcodes = rest
	for entry in finished:
		_finish_transcode(entry)


func _finish_transcode(entry: Dictionary) -> void:
	var job: TranscodeJob = entry["job"]
	job.mutex.lock()
	var ok: bool = job.ok
	var log := job.log_text
	var has_audio: bool = job.has_audio
	job.mutex.unlock()
	var avi := String(entry["avi"])
	var wav := String(entry["wav"])
	var mp4 := String(entry["mp4"])
	var frames := int(entry["frames"])
	if ok:
		var del_avi := DirAccess.remove_absolute(avi)
		var del_wav := OK
		if FileAccess.file_exists(wav):
			del_wav = DirAccess.remove_absolute(wav)
		_last_path = mp4
		var extra := "" if (del_avi == OK and del_wav == OK) else "；AVI/WAV 删除失败，两版并存"
		var audio := "" if has_audio else "（无音频流）"
		print("[Recorder] 录屏结束: %s (%d 帧, H.264%s MP4%s)" % [mp4, frames, audio, extra])
		return
	_last_path = avi
	log = log.replace("\n", " ").strip_edges()
	if log.length() > 300:
		log = log.substr(0, 300) + "…"
	print("[Recorder] 录屏结束: %s (%d 帧, MJPEG AVI；ffmpeg 转码失败: %s)" % [avi, frames, log])


func _submit_record(img: Image, slot: int) -> void:
	if _record_jobs.size() >= MAX_PENDING:
		return
	var job := RecordJob.new()
	job.slot = slot
	_record_jobs.append(job)
	WorkerThreadPool.add_task(job.encode.bind(img, JPG_QUALITY), false)


func _flush_record() -> void:
	if _record_jobs.is_empty():
		return
	var batch: Array = []
	var rest := []
	for job in _record_jobs:
		job.mutex.lock()
		var done: bool = job.done
		job.mutex.unlock()
		if done:
			batch.append(job)
		else:
			rest.append(job)
	_record_jobs = rest
	if batch.is_empty():
		return
	batch.sort_custom(func(a, b): return int(a.slot) < int(b.slot))
	for job in batch:
		var slot: int = job.slot
		var count := slot - _rec_written_slots + 1
		if count < 1 or _writer == null:
			continue
		job.mutex.lock()
		var blob: PackedByteArray = job.blob
		job.mutex.unlock()
		for _i in count:
			_writer.add_frame(blob)
		_rec_written_slots += count
		_rec_last_blob = blob


# ══════════════════════════ 死亡带（solo 内存缓冲） ══════════════════════════

func _submit_tape(img: Image) -> void:
	if _tape_jobs.size() >= TAPE_MAX_PENDING:
		return
	var job := TapeJob.new()
	job.t = _run_t
	_tape_jobs.append(job)
	WorkerThreadPool.add_task(job.encode.bind(img, TAPE_QUALITY, TAPE_W, TAPE_H), false)


func _flush_tape() -> void:
	if _tape_jobs.is_empty():
		return
	var batch: Array = []
	var rest := []
	for job in _tape_jobs:
		job.mutex.lock()
		var done: bool = job.done
		job.mutex.unlock()
		if done:
			batch.append(job)
		else:
			rest.append(job)
	_tape_jobs = rest
	if batch.is_empty():
		return
	batch.sort_custom(func(a, b): return float(a.t) < float(b.t))
	for job in batch:
		job.mutex.lock()
		var t: float = job.t
		var blob: PackedByteArray = job.blob
		job.mutex.unlock()
		_tape.append(t, blob)


# ══════════════════════════ 倒带回放（纯表现，不改模拟） ══════════════════════════

## P3b 入口：solo 倒地时回放内存带，播完 restart_single()。返回 false = 带太短/不在单人。
func start_rewind() -> bool:
	if _replaying:
		return true
	if _solo == null or _player == null or not is_instance_valid(_player):
		return false
	if not _player.sim_downed:
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
	_decode_jobs.clear()
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


func _tick_replay(delta: float) -> void:
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
	_decode_jobs.clear()
	_last_tape_t = -1.0
	_run_t = 0.0
	if _cap != null:
		_cap.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	if do_restart and _solo != null and is_instance_valid(_solo):
		_solo.restart_single.call_deferred()


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
	# 与 HUD 时钟同款居中：左右锚点 0/1（整幅宽度）、框内居中、只给上边距。
	_overlay_label = UiDesign.label("REWIND", REWIND_FONT, UiDesign.C_TEXT)
	_overlay_label.anchor_left = 0.0
	_overlay_label.anchor_right = 1.0
	_overlay_label.anchor_top = 0.0
	_overlay_label.anchor_bottom = 0.0
	_overlay_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_overlay_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_overlay_label.offset_top = UiDesign.MARGIN
	_overlay_label.offset_bottom = UiDesign.MARGIN
	_overlay_label.add_theme_color_override("font_outline_color", Color8(10, 12, 16, 200))
	_overlay_label.add_theme_constant_override("outline_size", 8)
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
	var job := DecodeJob.new()
	job.idx = idx
	_decode_jobs.append(job)
	WorkerThreadPool.add_task(job.decode.bind(_tape_frames[idx]), false)


func _flush_decodes() -> void:
	if _decode_jobs.is_empty():
		return
	var batch: Array = []
	var rest := []
	for job in _decode_jobs:
		job.mutex.lock()
		var done: bool = job.done
		job.mutex.unlock()
		if done:
			batch.append(job)
		else:
			rest.append(job)
	_decode_jobs = rest
	for job in batch:
		var idx: int = job.idx
		_decoding.erase(idx)
		job.mutex.lock()
		var img = job.img
		job.mutex.unlock()
		if img != null:
			_decoded[idx] = img


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
		_audio.drain_audio(_wav)
		_flush_record()


func _stamp() -> String:
	return _audio.stamp()
