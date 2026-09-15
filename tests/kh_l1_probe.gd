extends ProbeBase

# KH 合并 L1 探针(场景模式:autoload 需已实例化,不能用 -s 跑)。
# 跑法: Godot_console --headless --path . --quit-after 300 res://tests/kh_l1_probe.tscn
# (--quit-after 是安全网:本脚本引用 Settings/NetBusExt 等 autoload 标识符,若某个 autoload
#  被从 project.godot 删掉,脚本会编译失败 → 场景加载成无脚本根节点 → 命令无输出挂死。
#  有了它最坏只是超时退出。)

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



# 探针短名:拼 ALL-OK / FAIL / 汇总行的方括号前缀用(ProbeBase 的必需覆写项)。
func probe_id() -> String:
	return "L1"


func _ready() -> void:
	# 1) 四个 autoload 就位
	for n in REQUIRED_AUTOLOADS:
		_check(get_tree().root.get_node_or_null(NodePath(n)) != null, "autoload 缺失: %s" % n)

	# 2) Settings 保留项都在、已删项都不在(不断言默认值:本机 user://settings.cfg 会覆盖)
	for prop in ["master_volume", "sfx_volume", "wheel_switch",
			"sp_disabled_weapons", "pvp_show_trajectories", "pvp_round_full_heal",
			"pvp_show_enemy_hp", "pvp_disabled_weapons", "pvp_color_hue",
			"royale_match_min", "pvp_show_minimap", "pvp_minimap_show_enemy"]:
		_check(_has_prop(Settings, prop), "Settings 缺属性: %s" % prop)
	_check(not _has_prop(Settings, "old_ui"), "Settings.old_ui 未删除")
	# 换弹恒开:不换弹开关已整个删除(反向断言,防被"顺手恢复成可选项")
	_check(not _has_prop(Settings, "reload_enabled"), "Settings.reload_enabled 未删除(换弹不再有开关)")
	_check(not _has_prop(Settings, "sp_difficulty"), "Settings.sp_difficulty 未删除")
	_check(not Settings.REMAPPABLE_ACTIONS.is_empty(), "Settings.REMAPPABLE_ACTIONS 为空")
	Settings.save()             # 存写不崩
	Settings.load_settings()    # 读回不崩

	# 3) 源码级:难度/老版 UI 不得残留
	var ro_src := _read("res://core/config/run_options.gd")
	if ro_src == "":
		_failures.append("core/run_options.gd 读不到")
	else:
		_check("difficulty" not in ro_src, "core/run_options.gd 仍含 difficulty")
		_check("disabled_weapons" in ro_src, "core/run_options.gd 缺 disabled_weapons")
	var st_src := _read("res://core/config/settings.gd")
	if st_src == "":
		_failures.append("core/settings.gd 读不到")
	else:
		_check("old_ui" not in st_src, "core/settings.gd 仍含 old_ui")
		_check("sp_difficulty" not in st_src, "core/settings.gd 仍含 sp_difficulty")

	# 4) NetBusExt 扩展 RPC 与信号齐
	for m in NETBUS_EXT_RPCS:
		_check(NetBusExt.has_method(m), "NetBusExt 缺 RPC: %s" % m)
	for s in NETBUS_EXT_SIGNALS:
		_check(NetBusExt.has_signal(s), "NetBusExt 缺信号: %s" % s)

	# 5) pvp_session 的 reset 清得掉(2026-09-14:原断言的两个字段 royale/disabled_weapons
	#    已作为"只写不读"删除;改钉仍在的 map_path/spawn —— 换局时它们必须回到初值,
	#    否则上一局的地图/出生点会漏进下一局)
	PvpSession.map_path = "res://maps/factory1v1.cyrm"
	PvpSession.spawn = Vector2i(9, 9)
	PvpSession.reset()
	_check(PvpSession.map_path == "", "PvpSession.reset() 未清 map_path(换局会漏上一局的地图)")
	_check(PvpSession.spawn == Vector2i(-1, -1), "PvpSession.reset() 未清 spawn(换局会漏上一局的出生点)")

	# 6) Sfx 程序合成流可生成(不依赖音频设备)
	_check(Sfx._stream("kill") != null and Sfx._stream("hit") != null, "Sfx 音效流生成失败")

	# 7) LocalServer 是 class_name(非 autoload):查全局类缓存,验它真的注册成功了
	# (原先写 `if LocalServer == null` 是编译期恒假的死断言,永远不触发)
	var found_local_server := false
	for entry in ProjectSettings.get_global_class_list():
		if str(entry.get("class", "")) == "LocalServer":
			found_local_server = true
			break
	_check(found_local_server, "LocalServer 未注册进全局类缓存(应来自 res://core/net/local_server.gd)")

	_finish()


func _has_prop(o: Object, prop: String) -> bool:
	for p in o.get_property_list():
		if str(p["name"]) == prop:
			return true
	return false

