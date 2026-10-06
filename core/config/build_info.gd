extends RefCounted

# 发布版本信息(**单一来源**)。主菜单那行版本号读这里。
#
# 为什么单独一个文件、而不是读 project.godot 的 config/version:
#   发布版要在**没有 git 的机器**上也能显示出准确的版本号与构建时间 —— 而主菜单原先那行是从
#   git 现读的(分支名 + 提交数),在那种机器上只能退化成 "dev" 且**完全没有构建时间**。
#
# ★ 本文件是**入库的 dev 占位**。发布时由 `tools/build_release.py` 在导出前临时覆盖成
#   VERSION="RoF_vx.y.z" + BUILD_STAMP="<YYYYMMDDHHMM>"(版本号取自 project.godot 的
#   `application/config/version`,时间戳用归档那套格式),导出后**自动还原**成下面这份 ——
#   所以日常开发的工作区永远是干净的,`git status` 不会因为这个文件而脏。
const VERSION := "dev"
const BUILD_STAMP := ""


# 展示串:发布版 = "RoF_v0.5.0_202610040204",开发版 = "dev"(调用方据此决定是否回落到 git)。
# ★ 2026-10-04:连接符由 `VERSION (stamp)` 改成 `VERSION_stamp` —— 发布标识整体写成
#   `<前缀>_v<版本>_<时间戳>`(策划案版本写法 `KH_V0.5.0_260925`;**v 后不带点**;前缀 `RoF`
#    来自 project.godot 的 application/config/release_prefix,拼法收在 tools/archive_build.py)。
static func display() -> String:
	if VERSION.is_empty() or VERSION == "dev":
		return "dev"
	return VERSION if BUILD_STAMP.is_empty() else "%s_%s" % [VERSION, BUILD_STAMP]
