extends Node

# KH 合并 L1 探针(场景模式:autoload 需已实例化,不能用 -s 跑)。
# 跑法: Godot_console --headless --path . res://tests/kh_l1_probe.tscn

const REQUIRED_AUTOLOADS := ["GameParameters", "NetBus", "NetBusExt", "Settings"]
const NETBUS_EXT_RPCS := [
	# 客户端→服务器请求
	"player_options", "suicide_request",
	"royale_create", "royale_join", "royale_leave", "royale_list", "royale_start",
	"ai_duel", "royale_start_ai",
	# 服务器→客户端
	"match_options", "peer_hues", "hit_confirm", "beam_fired",
	"royale_rooms", "royale_room_state",
]

# 注意:下面这些是**信号**不是方法(对应 RPC 见 NETBUS_EXT_RPCS)。
# 用 has_method 断言它们会假失败,必须用 has_signal。
const NETBUS_EXT_SIGNALS := [
	"local_match_options", "local_peer_hues", "local_hit_confirm", "player_options_received",
	"local_beam_fired", "suicide_requested",
	"royale_create_requested", "royale_join_requested", "royale_leave_requested",
	"royale_list_requested", "royale_start_requested",
	"ai_duel_requested", "royale_start_ai_requested",
	"local_royale_rooms", "local_royale_room_state",
]


func _ready() -> void:
	var failures: Array[String] = []

	# 1) 四个 autoload 就位
	for n in REQUIRED_AUTOLOADS:
		if get_tree().root.get_node_or_null(NodePath(n)) == null:
			failures.append("autoload 缺失: %s" % n)

	# 2) Settings 保留项都在、已删项都不在(不断言默认值:本机 user://settings.cfg 会覆盖)
	for prop in ["master_volume", "sfx_volume", "wheel_switch", "reload_enabled",
			"sp_disabled_weapons", "pvp_show_trajectories", "pvp_round_full_heal",
			"pvp_show_enemy_hp", "pvp_disabled_weapons", "pvp_color_hue",
			"royale_match_min", "pvp_show_minimap", "pvp_minimap_show_enemy"]:
		if not _has_prop(Settings, prop):
			failures.append("Settings 缺属性: %s" % prop)
	if _has_prop(Settings, "old_ui"):
		failures.append("Settings.old_ui 未删除")
	if _has_prop(Settings, "sp_difficulty"):
		failures.append("Settings.sp_difficulty 未删除")
	if Settings.REMAPPABLE_ACTIONS.is_empty():
		failures.append("Settings.REMAPPABLE_ACTIONS 为空")
	Settings.save()             # 存写不崩
	Settings.load_settings()    # 读回不崩

	# 3) 源码级:难度/老版 UI 不得残留
	var ro_src := _read_res("res://core/run_options.gd")
	if ro_src == "":
		failures.append("core/run_options.gd 读不到")
	else:
		if "difficulty" in ro_src:
			failures.append("core/run_options.gd 仍含 difficulty")
		if "disabled_weapons" not in ro_src:
			failures.append("core/run_options.gd 缺 disabled_weapons")
	var st_src := _read_res("res://core/settings.gd")
	if "old_ui" in st_src:
		failures.append("core/settings.gd 仍含 old_ui")
	if "sp_difficulty" in st_src:
		failures.append("core/settings.gd 仍含 sp_difficulty")

	# 4) NetBusExt 扩展 RPC 与信号齐
	for m in NETBUS_EXT_RPCS:
		if not NetBusExt.has_method(m):
			failures.append("NetBusExt 缺 RPC: %s" % m)
	for s in NETBUS_EXT_SIGNALS:
		if not NetBusExt.has_signal(s):
			failures.append("NetBusExt 缺信号: %s" % s)

	# 5) pvp_session 两个新字段 + reset 清得掉
	if PvpSession.royale:
		failures.append("PvpSession.royale 重置后应为 false")
	if PvpSession.disabled_weapons.size() != 0:
		failures.append("PvpSession.disabled_weapons 重置后应为空")
	PvpSession.royale = true
	PvpSession.disabled_weapons.append(3)
	PvpSession.reset()
	if PvpSession.royale or PvpSession.disabled_weapons.size() != 0:
		failures.append("PvpSession.reset() 未清 royale/disabled_weapons")

	# 6) Sfx 程序合成流可生成(不依赖音频设备)
	if Sfx._stream("kill") == null or Sfx._stream("hit") == null:
		failures.append("Sfx 音效流生成失败")

	# 7) LocalServer 类可解析
	if LocalServer == null:
		failures.append("LocalServer 未解析")

	if failures.is_empty():
		print("KH L1 PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("KH L1 PROBE: FAIL | " + "; ".join(failures))
		get_tree().quit(1)


func _has_prop(o: Object, prop: String) -> bool:
	for p in o.get_property_list():
		if str(p["name"]) == prop:
			return true
	return false


func _read_res(path: String) -> String:
	if not ResourceLoader.exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_as_text() if f != null else ""
