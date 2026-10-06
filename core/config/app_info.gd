class_name AppInfo
extends RefCounted

# 版本号与提交历史(**两个页面都要读**:主菜单左下角的版本号行 + 「信 息」整页)。
#
# ★ 为什么单独一个文件而不是留在 `main_menu.gd`:信息页也要用,而让信息页去依赖主菜单
#   是反的。★ **也不能放进 `core/config/build_info.gd`** —— 那个文件由
#   `tools/build_release.py` 在导出前**覆盖写入**、导出后还原,扔进去会被构建流程盖掉。
#
# ★ 纯静态、零 autoload 依赖(与 `WeaponRegistry` 同形)⇒ 可 `-s` 测。


# 版本号:**发布版读 `core/config/build_info.gd`**(由 `tools/build_release.py` 在导出前写入
# 真实版本号与构建时间戳),开发版回落到 git(分支名 + 提交数)。
# ★ 发布版必须走前者:发布机往往没有 git,读 git 只会得到 "dev" 且拿不到构建时间。
# 传 `--nover` 时恒为 "dev"(菜单自动探针要确定性文本)。
#
# ★ `--nover` 的收口**在本函数内部**,不在调用方分叉 —— 保持原样,别搬出去。
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


# 读 git 输出为 UTF-8 文本。OS.execute 在中文 Windows 上按系统码页解码 → 中文乱码;
# execute_with_pipe 拿原始流,再用 get_buffer 累积字节 + get_string_from_utf8() 显式按 UTF-8 解。
# (本函数**不走** FileAccess.get_as_text —— 那条链读的是原始字节。)
# ★ 逐字从 `main_menu.gd` 搬来,别"顺手优化" —— 它踩过中文乱码那个坑。
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
