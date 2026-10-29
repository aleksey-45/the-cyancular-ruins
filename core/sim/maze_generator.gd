class_name MazeGenerator
extends RefCounted

# 会话地图选择与出生点元数据；地形由 NativeTerrain 持有。

const MAP_DIR: String = "res://maps"

# 优先读取可执行文件同级目录的 .cyrm 自定义地图，若无则从 res://maps/ 随机选取。
# 选中的地图在会话内保持，保证各处查询一致。
static var _picked_map: String = ""
static var current_spawns: Dictionary = {}

static func map_file_path() -> String:
	if _picked_map != "":
		return _picked_map
	var ext := _random_cyrm(OS.get_executable_path().get_base_dir())
	_picked_map = ext if ext != "" else _random_cyrm(MAP_DIR)
	return _picked_map

# 显式指定地图文件路径（PvP 联机由服务端指定地图，客户端同步加载同名文件）。
static func set_map_file(path: String) -> void:
	_picked_map = path
	current_spawns = {}

# 在 dir 目录下随机挑一个 .cyrm 地图;没有则返回 ""。
static func _random_cyrm(dir: String) -> String:
	var da := DirAccess.open(dir)
	if da == null:
		return ""
	var maps: Array[String] = []
	da.list_dir_begin()
	var f := da.get_next()
	while f != "":
		if not da.current_is_dir() and f.to_lower().ends_with(".cyrm"):
			maps.append(dir.path_join(f))
		f = da.get_next()
	da.list_dir_end()
	if maps.is_empty():
		return ""
	return maps[randi() % maps.size()]
