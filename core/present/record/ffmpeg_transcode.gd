class_name FfmpegTranscode
extends RefCounted

# 录屏后编码辅助:按 PATH(或环境变量覆盖)找 ffmpeg,把 MJPEG AVI + WAV 合成为 H.264/AAC MP4。
# 有 ffmpeg 才走 MP4;没有就由调用方保留 AVI+WAV,绝不让它变成硬依赖。

const FFMPEG_ENV := "CYR_REC_FFMPEG"


# CYR_REC_FFMPEG:空/未设 = 按 PATH 查;"0" / "off" = 禁用转码;其它 = 直接当可执行文件路径。
static func resolve(env_override: String) -> String:
	var ov := env_override.strip_edges()
	if ov == "0" or ov.to_lower() == "off":
		return ""
	if ov != "":
		return ov if FileAccess.file_exists(ov) else ""
	var exe := "ffmpeg.exe" if OS.get_name() == "Windows" else "ffmpeg"
	var sep := ";" if OS.get_name() == "Windows" else ":"
	for dir in OS.get_environment("PATH").split(sep, false):
		var cand := dir.path_join(exe)
		if FileAccess.file_exists(cand):
			return cand
	return ""


# ★ 只在 worker 线程调用:OS.execute 阻塞的是该线程,主线程不碰它。
static func transcode(ffmpeg: String, avi: String, wav: String, output: String) -> Dictionary:
	if ffmpeg == "" or not FileAccess.file_exists(avi):
		return {"ok": false, "log": "ffmpeg 或输入文件不存在", "audio": false}
	var has_audio := FileAccess.file_exists(wav) and _file_bytes(wav) > 44
	var out: Array = []
	var args := PackedStringArray([
		"-hide_banner", "-loglevel", "error", "-nostdin", "-y",
		"-i", avi])
	if has_audio:
		args.append_array(["-i", wav])
	args.append_array([
		"-c:v", "libx264", "-preset", "medium", "-crf", "16",
		"-pix_fmt", "yuv420p", "-color_range", "tv"])
	if has_audio:
		args.append_array(["-c:a", "aac", "-b:a", "192k"])
	args.append_array(["-movflags", "+faststart", "-shortest", output])
	var code := OS.execute(ffmpeg, args, out, true)
	if code == 0 and _sane_size(output):
		return {"ok": true, "log": "", "audio": has_audio}
	DirAccess.remove_absolute(output)
	return {"ok": false, "log": "exit=%d %s" % [code, "\n".join(PackedStringArray(out)).strip_edges()],
			"audio": false}


static func _sane_size(path: String) -> bool:
	return _file_bytes(path) > 1024


static func _file_bytes(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	var n := f.get_length()
	f.close()
	return n
