class_name AviWriter
extends RefCounted

# 最小 AVI (RIFF) / MJPEG muxer：每帧 = 一段 JPEG（"00dc" chunk）。
# 只写视频流（无音频）；帧率固定；用 idx1 索引，兼容常见播放器。
# 依赖 Image.save_jpg_to_buffer（当前发行模板含 jpg；裁剪掉 jpg 的模板不可用）。
# 调用顺序：open() → add_frame() * N → close()。
# 所有 chunk 大小按 RIFF 规则补齐到偶数（JPEG 通常是偶数长度，仍统一处理）。

var _f: FileAccess = null
var _width := 0
var _height := 0
var _fps := 60
var _frames := 0
var _max_frame := 0

var _riff_size_pos := 0
var _movi_size_pos := 0
var _movi_data_pos := 0
var _avih_total_pos := 0
var _avih_suggested_pos := 0
var _strh_len_pos := 0
var _strh_suggested_pos := 0
var _idx: Array[Vector2i] = []   # (offset relative to movi data start, data size)


func open(path: String, width: int, height: int, fps: int) -> Error:
	_width = width
	_height = height
	_fps = maxi(1, fps)
	_frames = 0
	_max_frame = 0
	_idx.clear()
	_f = FileAccess.open(path, FileAccess.WRITE)
	if _f == null:
		return FileAccess.get_open_error()

	_f.store_buffer("RIFF".to_ascii_buffer())
	_riff_size_pos = _f.get_position()
	_f.store_32(0)
	_f.store_buffer("AVI ".to_ascii_buffer())

	# ── LIST hdrl ──
	_f.store_buffer("LIST".to_ascii_buffer())
	var hdrl_size_pos := _f.get_position()
	_f.store_32(0)
	var hdrl_data_start := _f.get_position()
	_f.store_buffer("hdrl".to_ascii_buffer())

	# avih (56 B)
	_f.store_buffer("avih".to_ascii_buffer())
	_f.store_32(56)
	_f.store_32(int(1000000.0 / float(_fps)))   # dwMicroSecPerFrame
	_f.store_32(0)                             # dwMaxBytesPerSec
	_f.store_32(0)                             # dwPaddingGranularity
	_f.store_32(0x10)                          # AVIF_HASINDEX
	_avih_total_pos = _f.get_position()
	_f.store_32(0)                             # dwTotalFrames
	_f.store_32(0)                             # dwInitialFrames
	_f.store_32(1)                             # dwStreams
	_avih_suggested_pos = _f.get_position()
	_f.store_32(0)                             # dwSuggestedBufferSize
	_f.store_32(_width)
	_f.store_32(_height)
	for _i in 4:
		_f.store_32(0)

	# ── LIST strl ──
	_f.store_buffer("LIST".to_ascii_buffer())
	var strl_size_pos := _f.get_position()
	_f.store_32(0)
	var strl_data_start := _f.get_position()
	_f.store_buffer("strl".to_ascii_buffer())

	# strh (56 B)
	_f.store_buffer("strh".to_ascii_buffer())
	_f.store_32(56)
	_f.store_buffer("vids".to_ascii_buffer())
	_f.store_buffer("MJPG".to_ascii_buffer())
	_f.store_32(0)        # dwFlags
	_f.store_16(0)        # wPriority
	_f.store_16(0)        # wLanguage
	_f.store_32(0)        # dwInitialFrames
	_f.store_32(1)        # dwScale
	_f.store_32(_fps)     # dwRate
	_f.store_32(0)        # dwStart
	_strh_len_pos = _f.get_position()
	_f.store_32(0)        # dwLength
	_strh_suggested_pos = _f.get_position()
	_f.store_32(0)        # dwSuggestedBufferSize
	_f.store_32(0xFFFFFFFF)  # dwQuality
	_f.store_32(0)           # dwSampleSize
	_f.store_16(0)
	_f.store_16(0)
	_f.store_16(_width)
	_f.store_16(_height)

	# strf (BITMAPINFOHEADER, 40 B)
	_f.store_buffer("strf".to_ascii_buffer())
	_f.store_32(40)
	_f.store_32(40)
	_f.store_32(_width)
	_f.store_32(_height)
	_f.store_16(1)
	_f.store_16(24)
	_f.store_buffer("MJPG".to_ascii_buffer())
	_f.store_32(_width * _height * 3)
	_f.store_32(0)
	_f.store_32(0)
	_f.store_32(0)
	_f.store_32(0)

	var strl_end := _f.get_position()
	_f.seek(strl_size_pos)
	_f.store_32(strl_end - strl_data_start)   # 含 "strl" 四字符
	var hdrl_end := strl_end
	_f.seek(hdrl_size_pos)
	_f.store_32(hdrl_end - hdrl_data_start)   # 含 "hdrl" 四字符
	_f.seek(hdrl_end)

	# ── LIST movi ──
	_f.store_buffer("LIST".to_ascii_buffer())
	_movi_size_pos = _f.get_position()
	_f.store_32(0)
	_f.store_buffer("movi".to_ascii_buffer())
	_movi_data_pos = _f.get_position()
	return OK


func add_frame(jpeg: PackedByteArray) -> void:
	if _f == null or jpeg.is_empty():
		return
	var off := _f.get_position() - _movi_data_pos
	_f.store_buffer("00dc".to_ascii_buffer())
	_f.store_32(jpeg.size())
	_f.store_buffer(jpeg)
	if jpeg.size() % 2 == 1:
		_f.store_8(0)
	_idx.append(Vector2i(off, jpeg.size()))
	_frames += 1
	_max_frame = maxi(_max_frame, jpeg.size())


func frame_count() -> int:
	return _frames


func close() -> void:
	if _f == null:
		return
	var movi_end := _f.get_position()
	_f.seek(_movi_size_pos)
	_f.store_32(movi_end - (_movi_data_pos - 4))   # 含 "movi" 四字符
	_f.seek(movi_end)

	# idx1
	_f.store_buffer("idx1".to_ascii_buffer())
	_f.store_32(_idx.size() * 16)
	for e in _idx:
		_f.store_buffer("00dc".to_ascii_buffer())
		_f.store_32(0x10)                    # AVIIF_KEYFRAME
		_f.store_32(int(e.x))
		_f.store_32(int(e.y))

	var file_end := _f.get_position()
	_f.seek(_riff_size_pos)
	_f.store_32(file_end - 8)
	_f.seek(_avih_total_pos)
	_f.store_32(_frames)
	_f.seek(_avih_suggested_pos)
	_f.store_32(_max_frame)
	_f.seek(_strh_len_pos)
	_f.store_32(_frames)
	_f.seek(_strh_suggested_pos)
	_f.store_32(_max_frame)
	_f.seek(file_end)
	_f.flush()
	_f.close()
	_f = null
