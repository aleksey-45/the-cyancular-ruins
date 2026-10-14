class_name AppPaths
extends RefCounted

# macOS 的组件位于应用包内，可写文件位于用户数据目录。

const EASYTIER_DIR := "easytier"   # EasyTier 相关文件目录名
const LOG_DIR := "log"             # 日志目录名


## 获取游戏根目录绝对路径（末尾不包含斜杠）。
## 导出运行环境下取可执行文件所在目录，编辑器或独立测试环境下取工程根目录。
static func base_dir() -> String:
	if OS.has_feature("template"):
		return OS.get_executable_path().get_base_dir()
	return ProjectSettings.globalize_path("res://").rstrip("/")


## 获取 EasyTier 组件存放目录绝对路径。
static func easytier_dir() -> String:
	if OS.has_feature("macos") and OS.has_feature("template"):
		return base_dir().get_base_dir().path_join("Helpers")
	return base_dir().path_join(EASYTIER_DIR)


## 获取日志输出目录绝对路径。
static func log_dir() -> String:
	if OS.has_feature("macos"):
		return OS.get_user_data_dir().path_join(LOG_DIR)
	return base_dir().path_join(LOG_DIR)
