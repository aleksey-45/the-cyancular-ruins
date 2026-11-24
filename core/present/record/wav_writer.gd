class_name WavWriter
extends RefCounted

# 最小 WAV 写入器：PCM s16 / 立体声 / 16bit，header 在 close() 时回填长度。
# 数据源 = AudioEffectCapture 的 PackedVector2Array（每项一帧 L/R，值域 [-1,1]）。

var _f: FileAccess = null
var _rate := 44100
var _data_bytes := 0
var _frames := 0


func open(path: String, mix_rate: int) -> Error:
	_rate = maxi(1, mix_rate)
	_data_bytes = 0
	_frames = 0
	_f = FileAccess.open(path, FileAccess.WRITE)
	if _f == null:
		return FileAccess.get_open_error()
	_f.store_buffer("RIFF".to_ascii_buffer())
	_f.store_32(0)
	_f.store_buffer("WAVEfmt ".to_ascii_buffer())
	_f.store_32(16)
	_f.store_16(1)
	_f.store_16(2)
	_f.store_32(_rate)
	_f.store_32(_rate * 4)
	_f.store_16(4)
	_f.store_16(16)
	_f.store_buffer("data".to_ascii_buffer())
	_f.store_32(0)
	return OK


func add_frames(buf: PackedVector2Array) -> void:
	if _f == null or buf.is_empty():
		return
	var bytes := PackedByteArray()
	bytes.resize(buf.size() * 4)
	var i := 0
	for v in buf:
		var l := int(clampf(v.x, -1.0, 1.0) * 32767.0)
		var r := int(clampf(v.y, -1.0, 1.0) * 32767.0)
		bytes[i] = l & 0xFF
		bytes[i + 1] = (l >> 8) & 0xFF
		bytes[i + 2] = r & 0xFF
		bytes[i + 3] = (r >> 8) & 0xFF
		i += 4
	_f.store_buffer(bytes)
	_data_bytes += bytes.size()
	_frames += buf.size()


func frame_count() -> int:
	return _frames


func close() -> void:
	if _f == null:
		return
	var end := _f.get_position()
	_f.seek(4)
	_f.store_32(end - 8)
	_f.seek(40)
	_f.store_32(_data_bytes)
	_f.seek(end)
	_f.flush()
	_f.close()
	_f = null
