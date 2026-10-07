class_name AppInfo
extends RefCounted

# 版本号与提交历史提供类。
# 供主菜单版本号标识及信息展示界面读取。
# 无外部 Autoload 单例依赖，支持独立静态调用。


# 获取版本号字符串：
# 1. 导出发布版读取 build_info.gd 中的构建元数据；
# 2. 本地开发版回退读取 Git 分支与提交序号；
# 3. 传入 --nover 启动参数时固定返回 "dev" 以满足自动化测试断言。
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


# 提交历史(新→旧,最多 20 条):[{hash,time,subject}]
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


# 执行 Git 命令并读取输出。
# 使用管道流式读取原始字节流并按 UTF-8 解码，避免 Windows 平台因默认代码页导致中文乱码。
static func _git_text(args: Array) -> String:
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
