class_name AppPaths
extends RefCounted


const EASYTIER_DIR := "easytier"


## 直接运行项目时，以 res:// 对应的磁盘目录作为基础路径。导出后改用游戏可执行文件所在的目录。
static func base_dir() -> String:
	if OS.has_feature("template"):
		return OS.get_executable_path().get_base_dir()
	return ProjectSettings.globalize_path("res://").rstrip("/")


## EasyTier 通常位于基础目录下的 easytier。macOS 导出版本从应用包的 Contents/Helpers 读取。
static func easytier_dir() -> String:
	if OS.has_feature("macos") and OS.has_feature("template"):
		return base_dir().get_base_dir().path_join("Helpers")
	return base_dir().path_join(EASYTIER_DIR)
