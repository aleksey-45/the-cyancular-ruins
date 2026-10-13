extends ProbeBase

# KH 合并 L1 探针(场景模式:autoload 需已实例化,不能用 -s 跑)。
# 运行方式： Godot_console --headless --path . --quit-after 300 res://tests/probe/kh_l1_probe.tscn
# (--quit-after 是超时保护上限:本脚本引用 Settings/NetBus 等 autoload 标识符,若某个 autoload
#  被从 project.godot 删掉,脚本会编译失败 -> 场景加载成无脚本根节点 -> 命令无输出挂死。
#  有了它最坏只是超时退出。)

const REQUIRED_AUTOLOADS := ["GameParameters", "NetBus", "Settings"]
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
	_check(not _has_prop(Settings, "reload_enabled"), "Settings.reload_enabled 未删除(换弹不再有开关)")
	_check(not _has_prop(Settings, "sp_difficulty"), "Settings.sp_difficulty 未删除")
	_check(not Settings.REMAPPABLE_ACTIONS.is_empty(), "Settings.REMAPPABLE_ACTIONS 为空")
	Settings.save()             # 存写不崩
	Settings.load_settings()
	var ro_src := _code_only(_read("res://core/config/run_options.gd"))
	if ro_src == "":
		_failures.append("core/run_options.gd 读不到")
	else:
		_check("difficulty" not in ro_src, "core/run_options.gd 仍含 difficulty")
		_check("disabled_weapons" in ro_src, "core/run_options.gd 缺 disabled_weapons")
	var st_src := _code_only(_read("res://core/config/settings.gd"))
	if st_src == "":
		_failures.append("core/settings.gd 读不到")
	else:
		_check("old_ui" not in st_src, "core/settings.gd 仍含 old_ui")
		_check("sp_difficulty" not in st_src, "core/settings.gd 仍含 sp_difficulty")

	# 4) 当前传输入口可用；网络包行为由 transport_probe 验证。
	for method in ["send_input", "send_state", "send_event"]:
		_check(NetBus.has_method(method), "缺少数据流入口: %s" % method)
	for signal_name in ["input_received", "state_received", "event_received"]:
		_check(NetBus.has_signal(signal_name), "缺少数据流接收信号: %s" % signal_name)

	PvpSession.map_path = "res://maps/newfactory.cyrm"
	PvpSession.loading_match = true
	PvpSession.terrain_events.append({})
	PvpSession.reset()
	_check(PvpSession.map_path == "", "PvpSession.reset() 未清 map_path(换局会漏上一局的地图)")
	_check(not PvpSession.loading_match and PvpSession.terrain_events.is_empty(), "PvpSession.reset() 未清加载阶段和地形队列")

	# 6) Sfx 程序合成流可生成(不依赖音频设备)
	_check(Sfx._stream("kill") != null and Sfx._stream("hit") != null, "Sfx 音效流生成失败")

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
