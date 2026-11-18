class_name Sfx
extends RefCounted

# 音效在首次播放时合成并缓存，格式为 22,050 Hz、8 位单声道 WAV。
# 每次播放创建一个节点，结束时释放。音频发往 SFX 总线，找不到该总线时改用 Master。

const RATE := 22050
const ACTION_SOUNDS := {"reload_started": "reload", "reload_finished": "switch",
		"equipped": "switch", "pickup_denied": "deny"}

static var _cache: Dictionary = {}
static var _rng := RandomNumberGenerator.new()

# 列表中的音效每次播放时随机调整音高，最多升高或降低 6%。
const PITCH_VARIATION := ["shoot", "shoot_heavy", "shotgun", "hit"]

## 与各音效的播放音高相乘。单人关卡用它随时间技能调整声音。
static var pitch_mult: float = 1.0


## pitch 是此次播放的音高倍率。volume_db 是以分贝表示的音量。
static func play(kind: String, pitch: float = 1.0, volume_db: float = 0.0) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return
	var stream := _stream(kind)
	if stream == null:
		return
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.bus = "SFX" if AudioServer.get_bus_index("SFX") >= 0 else "Master"
	p.process_mode = Node.PROCESS_MODE_ALWAYS   # 暂停场景树时，播放节点仍会处理音频。
	p.volume_db = volume_db
	p.pitch_scale = pitch * pitch_mult * (_rng.randf_range(0.94, 1.06) if kind in PITCH_VARIATION else 1.0)
	# 延迟添加播放节点和调用 play()，以便在场景节点的 _ready() 回调里播放音效。
	tree.root.add_child.call_deferred(p)
	p.call_deferred("play")
	p.finished.connect(p.queue_free)


static func _stream(kind: String) -> AudioStreamWAV:
	if _cache.has(kind):
		return _cache[kind]
	var samples := _build(kind)
	if samples.is_empty():
		return null
	var bytes := PackedByteArray()
	bytes.resize(samples.size())
	for i in samples.size():
		bytes[i] = int(clampf(samples[i], -1.0, 1.0) * 127.0) & 0xFF
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_8_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = bytes
	_cache[kind] = w
	return w


static func _build(kind: String) -> PackedFloat32Array:
	match kind:
		"shoot":        return _sweep_square(900.0, 240.0, 0.09, 0.5, 0.10)
		"shoot_heavy":  return _sweep_square(240.0, 45.0, 0.30, 0.3, 0.10)
		"shotgun":      return _noise_burst(0.20, 1400.0, 0.6, 0.35)
		"bow":          return _sweep_square(520.0, 140.0, 0.11, 0.25, 0.02)
		"hit":          return _sweep_square(210.0, 70.0, 0.07, 0.5, 0.12)
		"hurt":         return _sweep_square(430.0, 110.0, 0.18, 0.4, 0.10)
		"explosion":    return _noise_burst(0.55, 900.0, 1.0, 0.12)
		"kill":         return _arp([620.0, 440.0, 300.0], 0.07, 0.5)
		"switch":       return _arp([500.0, 820.0], 0.05, 0.5)
		"deny":         return _sweep_square(150.0, 110.0, 0.12, 0.25, 0.0)
		"heartbeat":    return _heartbeat()
		"reload":       return _arp([180.0, 320.0], 0.06, 0.4)
		"ui":           return _arp([700.0, 1050.0], 0.04, 0.5)
	push_warning("Sfx: 未知音效 \"%s\"" % kind)
	return PackedFloat32Array()


# 两段相接的低频方波模拟一次心跳。
static func _heartbeat() -> PackedFloat32Array:
	var out := _sweep_square(96.0, 52.0, 0.12, 0.5, 0.0)
	out.append_array(_sweep_square(82.0, 44.0, 0.10, 0.5, 0.0))
	return out


# 频率由 freq0 指数过渡到 freq1。duty 控制方波占空比，noise_mix 决定开头混入多少噪声。
# 噪声在总时长的前四分之一逐渐消失。
static func _sweep_square(freq0: float, freq1: float, dur: float, duty: float,
		noise_mix: float) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	var noise_state := 0.0
	for i in n:
		var t := float(i) / float(n)
		var freq := freq0 * pow(freq1 / freq0, t)
		phase = fmod(phase + freq / RATE, 1.0)
		var square := (1.0 if phase < duty else -1.0) * (1.0 - t) * (1.0 - t)
		if noise_mix > 0.0 and t < 0.25:
			noise_state = lerp(noise_state, _rng.randf_range(-1.0, 1.0), 0.6)
			square = lerp(square, noise_state, noise_mix * (1.0 - t * 4.0))
		out[i] = square * 0.7
	return out


# 将随机值与上一次的结果插值以平滑噪声，再让振幅按指数衰减。
# lp 决定每次采样保留多少上一次的结果，decay 决定衰减速度。
static func _noise_burst(dur: float, lp: float, amp0: float, decay: float) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var state := 0.0
	for i in n:
		var t := float(i) / float(n)
		state = lerp(state, _rng.randf_range(-1.0, 1.0), clampf(lp * (1.0 - t * 0.7), 0.05, 1.0))
		out[i] = state * amp0 * exp(-decay * t * 6.0)
	return out


# 依次生成列表中的音高。每段持续 note_dur 秒，振幅逐渐减小。
static func _arp(freqs: Array, note_dur: float, duty: float) -> PackedFloat32Array:
	var note_n := int(note_dur * RATE)
	var out := PackedFloat32Array()
	out.resize(note_n * freqs.size())
	var phase := 0.0
	for f in range(freqs.size()):
		for i in note_n:
			var t := float(i) / float(note_n)
			phase = fmod(phase + float(freqs[f]) / RATE, 1.0)
			out[f * note_n + i] = ((1.0 if phase < duty else -1.0) * (1.0 - t * t) * 0.6)
	return out
