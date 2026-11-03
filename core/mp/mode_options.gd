class_name ModeOptions
extends RefCounted

# 选项下发(按模式取键)。消费方:`scenes/mp_lobby.gd` 的 `_player_options()`。
static func build(mode: String, snapshot: Dictionary) -> Dictionary:
	var keys := ModeDefs.option_keys(mode)
	if keys.is_empty():
		push_warning("ModeOptions.build: 未知模式 %s —— 只发最小键 map" % mode)
		keys = ["map"]
	var out: Dictionary = {}
	for k in keys:
		if snapshot.has(k):
			out[k] = snapshot[k]
	# Beta 时间规则:仅"非 1v1"且 beta 开启时带(与旧实现同名同条件;1v1 的房没有 beta 标记,
	# 带上会让普通玩家混进带时间经济的 1v1 —— 旧注释点名过这条)。
	if bool(snapshot.get("beta", false)) and mode != ModeDefs.MODE_PVP:
		out["time"] = snapshot.get("time", {})
	return out
