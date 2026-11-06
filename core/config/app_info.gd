class_name AppInfo
extends RefCounted



static var _version_cache := ""
static var _log_cache: Array = []


static func version_string() -> String:
	if "--nover" in OS.get_cmdline_user_args():
		return "dev"
	if _version_cache != "":
		return _version_cache
	var bi := preload("res://core/config/build_info.gd")
	if str(bi.VERSION) != "" and str(bi.VERSION) != "dev":
		_version_cache = bi.display()
		return _version_cache
	var branch := _git_text(["rev-parse", "--abbrev-ref", "HEAD"]).strip_edges()
	var n := _git_text(["rev-list", "--count", "HEAD"]).strip_edges()
	_version_cache = ("%s #%s" % [branch, n]) if branch != "" else "dev"
	return _version_cache


static func commit_log() -> Array:
	if not _log_cache.is_empty():
		return _log_cache
	for line in _git_text(["-c", "i18n.logOutputEncoding=UTF-8",
			"log", "--pretty=%h|%cI|%s", "-20"]).split("\n"):
		var parts := line.strip_edges().split("|", true, 2)
		if parts.size() == 3:
			_log_cache.append({
				"hash": parts[0],
				"time": parts[1].replace("T", " ").substr(0, 16),
				"subject": parts[2],
			})
	return _log_cache


static func _git_text(args: Array) -> String:
	# ★ Web:浏览器里没有子进程/git(OS.execute_with_pipe 在 Web 上不可用)⇒ 直接返回空,走"读不到就显示 dev"的兜底。
	# 发布版本来就走 build_info.gd(导出时写入),不会落到这里;只有开发/手动导出才需要这条。
	if OS.has_feature("web"):
		return ""
	var res: Variant = OS.execute_with_pipe("git", args, true)
	if res is Dictionary and res.has("stdio"):
		var f: FileAccess = res["stdio"]
		if f != null:
			var bytes := PackedByteArray()
			var guard := 0
			while not f.eof_reached() and guard < 1000:
				guard += 1
				var chunk := f.get_buffer(4096)
				if chunk.size() == 0:
					break
				bytes.append_array(chunk)
			if bytes.size() > 0:
				return bytes.get_string_from_utf8()
	var out: Array = []
	OS.execute("git", args, out, true)
	return str(out[0]) if out.size() > 0 else ""
