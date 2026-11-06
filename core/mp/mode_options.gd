class_name ModeOptions
extends RefCounted

static func build(mode: String, snapshot: Dictionary) -> Dictionary:
	var keys := ModeDefs.option_keys(mode)
	if keys.is_empty():
		push_warning("ModeOptions.build: 未知模式 %s —— 只发最小键 map" % mode)
		keys = ["map"]
	var out: Dictionary = {}
	for k in keys:
		if snapshot.has(k):
			out[k] = snapshot[k]
	if bool(snapshot.get("beta", false)) and mode != ModeDefs.MODE_PVP:
		out["time"] = snapshot.get("time", {})
	return out
