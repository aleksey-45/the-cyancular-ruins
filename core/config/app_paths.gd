class_name AppPaths
extends RefCounted

# 游戏目录,以及它下面那几个固定子目录的**唯一来源**。
#
#   <游戏目录>/                      发布版 = 游戏 exe 所在目录;开发态 = 仓库根
#     The Cyancular Ruins.exe        客户端
#     Cyancular Ruins Server.exe     服务端
#     easytier/                      EasyTier 内核与它的公共节点列表
#     log/                           客户端、服务端、EasyTier 三方的日志
#
# - 为什么要有这一份:这三处路径原先各写各的(`OS.get_executable_path()`、
#   `res://tools/easytier`、`user://easytier-relay.txt`…),而它们必须指向**同一个**目录树 ——
#   漂了不会报错,只会"文件明明在,游戏却说找不到"。
#
# 注意： 「游戏目录」在开发态**不能**取 `OS.get_executable_path()`:那是 Godot 编辑器自己的
#   安装目录(在 D:\Softwares 或 Program Files 下),往那里找 EasyTier、往那里写日志都是错的。
#   判据用 `template` 特性:导出产物为真(此时 exe 目录就是游戏目录),编辑器与 `-s` 探针为假
#   (此时仓库根才是游戏目录)。

const EASYTIER_DIR := "easytier"   # EasyTier 内核四件套 + 公共节点列表
const LOG_DIR := "log"             # 三方日志


## 游戏目录(绝对路径,**不带结尾斜杠**)。见文件头:导出产物取 exe 目录,开发态取工程目录。
## - 结尾斜杠要去掉:`globalize_path("res://")` 在开发态给的是 `D:/…/the-cyancular-ruins/`,
##   而 `OS.get_executable_path().get_base_dir()` 没有那一撇 —— 两种形态并存时,
##   "拿它俩判等"的调用方(探针、日志提示文案)会得到莫名其妙的结果。
static func base_dir() -> String:
	if OS.has_feature("template"):
		return OS.get_executable_path().get_base_dir()
	return ProjectSettings.globalize_path("res://").rstrip("/")


## EasyTier 的存放目录(绝对路径)。
static func easytier_dir() -> String:
	return base_dir().path_join(EASYTIER_DIR)


## 日志目录(绝对路径)。
static func log_dir() -> String:
	return base_dir().path_join(LOG_DIR)
