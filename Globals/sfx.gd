class_name Sfx
extends RefCounted

# 8-bit 程序合成音效(实验分支 KikuchiHeinr):零音频素材,全部运行时生成
# AudioStreamWAV(22050Hz 单声道 8bit)。方波 + 白噪声 + 频率/音量包络,
# 复古游戏机味道。静态类不引 autoload(-s 可测);播放节点挂树根,播完自毁。
# 音量走 Settings 的 SFX 总线(没有该总线时回落 Master)。

const RATE := 22050

static var _cache: Dictionary = {}

# 轻微随机音高的音效(开枪类,避免每次一模一样的机械感)
const PITCH_VARIATION := ["shoot", "shoot_heavy", "shotgun", "hit"]


## 播放一个音效。kind 见 _build;pitch 缩放音调;volume_db 附加增益(负值更轻)。
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
	p.process_mode = Node.PROCESS_MODE_ALWAYS   # 单机暂停树时 UI 音效仍可播
	p.volume_db = volume_db
	p.pitch_scale = pitch * (randf_range(0.94, 1.06) if kind in PITCH_VARIATION else 1.0)
	# 游戏启动链(_ready 里 equip→switch 音)树正在建子节点,直接 add_child 会被拒:
	# 延迟到帧末入树,再依序延迟播放(保证此时已进树)。
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


# ── 音效定义:每 kind 一段逐样本合成 ──
static func _build(kind: String) -> PackedFloat32Array:
	match kind:
		"shoot":        return _sweep_square(900.0, 240.0, 0.09, 0.5, 0.10)
		"shoot_heavy":  return _sweep_square(240.0, 45.0, 0.30, 0.3, 0.10)
		"shotgun":      return _noise_burst(0.20, 1400.0, 0.6, 0.35)
		"hit":          return _sweep_square(210.0, 70.0, 0.07, 0.5, 0.12)
		"hurt":         return _sweep_square(430.0, 110.0, 0.18, 0.4, 0.10)
		"jump":         return _sweep_square(260.0, 760.0, 0.13, 0.5, 0.0)
		"explosion":    return _noise_burst(0.55, 900.0, 1.0, 0.12)
		"kill":         return _arp([620.0, 440.0, 300.0], 0.07, 0.5)
		"switch":       return _arp([500.0, 820.0], 0.05, 0.5)
		"deny":         return _sweep_square(150.0, 110.0, 0.12, 0.25, 0.0)
		"reload":       return _arp([180.0, 320.0], 0.06, 0.4)   # 换弹:两段机械咔哒
		"ui":           return _arp([700.0, 1050.0], 0.04, 0.5)
		"teleport":     return _sweep_square(300.0, 1200.0, 0.20, 0.5, 0.0)
	push_warning("Sfx: 未知音效 \"%s\"" % kind)
	return PackedFloat32Array()


# 方波滑音:freq0→freq1 指数过渡,duty 占空比,noise_mix 开头混入的噪声比例。
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
			noise_state = lerp(noise_state, randf_range(-1.0, 1.0), 0.6)
			square = lerp(square, noise_state, noise_mix * (1.0 - t * 4.0))
		out[i] = square * 0.7
	return out


# 白噪声爆发:lp 低通系数(0-1,越小越闷),amp_decay 指数衰减率。
static func _noise_burst(dur: float, lp: float, amp0: float, decay: float) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var state := 0.0
	for i in n:
		var t := float(i) / float(n)
		state = lerp(state, randf_range(-1.0, 1.0), clampf(lp * (1.0 - t * 0.7), 0.05, 1.0))
		out[i] = state * amp0 * exp(-decay * t * 6.0)
	return out


# 短音阶:依次播放每个频率 note_dur 秒的方波,结尾快速衰减。
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
