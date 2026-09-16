class_name TimeWorld
extends RefCounted

# 时空地图的时间线(第三维度):解析 .cyrm 的 "# tl:" 事件行,世界钟倒计时,
# 跨越阈值时产出待执行事件(坍塌/崩开等)。地图格式向后兼容(v3 加载器把 # 行当注释)。
#
# 方向约定:事件只在 w **正向倒计时跨越**阈值时触发一次(回拨重放留给二期的"时间回溯区")。
# 事件行格式:
#   # tl-w0: <起始秒>                      —— 世界钟起始(缺省 60)
#   # tl: <触发秒> <action> <x> <y> <w> <h> [标签...]
#     action: collapse(区域变实心,封路) / open(区域变空气,炸开)
# 坐标为空间层格坐标(与 .cyrm 空间网格同系)。

var w0 := 60.0        # 世界钟起始秒
var w := 60.0         # 当前剩余秒(倒计时)
var events: Array = []   # [{w, action, rect: Rect2i, label}] 按 w 降序
var _fired: Array[bool] = []


static func parse_for(map_path: String) -> TimeWorld:
	var tw := TimeWorld.new()
	if map_path.is_empty():
		return tw
	var text := FileAccess.get_file_as_string(map_path)
	if text.is_empty():
		return tw
	for line in text.split("\n"):
		var t := line.strip_edges()
		if t.begins_with("# tl-w0:"):
			tw.w0 = maxf(float(t.trim_prefix("# tl-w0:").strip_edges()), 0.0)
		elif t.begins_with("# tl:"):
			# # tl: <触发秒> <action> <x> <y> <w> <h> [标签...]
			var parts := t.trim_prefix("# tl:").strip_edges().split(" ", false)
			if parts.size() < 6:
				continue
			var label := ""
			if parts.size() > 6:
				label = " ".join(PackedStringArray(parts.slice(6)))
			tw.events.append({
				"w": float(parts[0]),
				"action": parts[1],
				"rect": Rect2i(int(parts[2]), int(parts[3]), int(parts[4]), int(parts[5])),
				"label": label,
			})
	tw.events.sort_custom(func(a, b): return float(a["w"]) > float(b["w"]))
	tw.w = tw.w0
	tw._fired.resize(tw.events.size())
	tw._fired.fill(false)
	return tw


func has_events() -> bool:
	return not events.is_empty()


## 下一个未触发阈值(秒;-1=无)。HUD 预警用。
func next_trigger() -> float:
	for i in events.size():
		if not _fired[i]:
			return float(events[i]["w"])
	return -1.0


## 推进世界钟 delta 秒,返回本轮到点(跨越阈值)的事件数组
func tick(delta: float) -> Array:
	if events.is_empty():
		return []
	w = maxf(w - delta, 0.0)
	var due: Array = []
	for i in events.size():
		if _fired[i]:
			continue
		var ev: Dictionary = events[i]
		if w <= float(ev["w"]):
			_fired[i] = true
			var out := {"index": i, "w": float(ev["w"]), "action": str(ev["action"]),
					"rect": ev["rect"], "label": str(ev.get("label", ""))}
			due.append(out)
	return due
