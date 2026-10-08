class_name AppPaths
extends RefCounted

# 游戏运行根目录与固定子目录路径管理。
# 统一发布版可执行文件目录与开发态工程根目录的寻址规范：
#   <游戏目录>/
#     The Cyancular Ruins.exe        客户端
#     Cyancular Ruins Server.exe     服务端
#     easytier/                      EasyTier 内核与公共节点配置
#     log/                           运行日志目录

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
	return base_dir().path_join(EASYTIER_DIR)


## 获取日志输出目录绝对路径。
static func log_dir() -> String:
	return base_dir().path_join(LOG_DIR)
