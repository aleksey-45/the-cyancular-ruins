class_name TimeTimeline
extends RefCounted

# 时空地图的**时间层**(第三维度)——事件溯源模型(GDD v0.2 决议 4 / v0.3 §4.2、§4.3)。
#
# 时间线 = append-only 事件日志;每条 = {t, 正向操作, 逆向操作, origin}。
#   · origin = scheduled(地图编排) / player(玩家操作入史:拆墙/开门/拾取);
#   · **击杀不入史**——实体位置不回拨(§3 不变量),回拨撤"世界的伤"、不撤"战果";
#   · 回拨 = LIFO 倒放:t ∈ (w_now, target] 的事件按 t 降序执行逆操作;
#   · scheduled 事件回拨后自动**重新武装**(再次跨越可再触发),player 事件不重发;
#   · **逆操作完备性 = 铁律**:每个入史 kind 必须带正确逆操作并过探针,否则产生幽灵状态。
#
# ── .cyrm v4 时间层语法(空间层沿用 v3,原样保留)──
#   # cyrm-v4                                   ← 格式标记(v3 图无此标记照旧可用)
#   # tl-w0: <起始秒>                            ← 世界针起始(缺省 TimeParams.W0_DEFAULT)
#   # tl: <t> <action> <x> <y> <w> <h> [标签...]  ← 定时事件;t 支持小数秒(14.300)
#   例:# tl: 15 collapse 22 20 17 11 桥梁坍塌
#       # tl: 5 open 46 20 1 10 密室炸开
# 坐标为空间层格坐标。action 原型见 §4.2(首批 8 个);当前已实现 collapse/open,
# 其余原型(怪潮/强化/时间风暴/补给窗/地貌变化/剧情播报)只登记、不执行(逆向记 noop),
# 由后续里程碑逐个补齐——补齐时必须同时给出逆向操作。
#
# 本类只做**纯数据与调度**(不碰 Level0/MazeGenerator),因此 -s 探针可直接断言。

const ORIGIN_SCHEDULED: String = "scheduled"
const ORIGIN_PLAYER: String = "player"

# 区域型动作的正逆配对(自动逆向表)
const AUTO_INVERSE: Dictionary = {
	"collapse": "open",
	"open": "collapse",
}

var w0: float = TimeParams.W0_DEFAULT
var entries: Array = []          # 按 t 降序;同 t 按 id 降序(后记录者先回滚)
var _next_id: int = 0


# ── 解析 ────────────────────────────────────────────────────

static func parse_for(map_path: String) -> TimeTimeline:
	var tl := TimeTimeline.new()
	if map_path.is_empty():
		return tl
	var text := FileAccess.get_file_as_string(map_path)
	if text.is_empty():
		return tl
	return parse_lines(text.split("\n"))


## 从地图行解析时间层(与文件无关,便于探针直接喂文本)。
static func parse_lines(lines) -> TimeTimeline:
	var tl := TimeTimeline.new()
	for raw in lines:
		var line := String(raw).strip_edges()
		if line.begins_with("# tl-w0:"):
			tl.w0 = maxf(float(line.trim_prefix("# tl-w0:").strip_edges()), 0.0)
		elif line.begins_with("# tl:"):
			var parts := line.trim_prefix("# tl:").strip_edges().split(" ", false)
			if parts.size() < 6:
				continue
			var label := ""
			if parts.size() > 6:
				label = " ".join(PackedStringArray(parts.slice(6)))
			var rect := Rect2i(int(parts[2]), int(parts[3]), int(parts[4]), int(parts[5]))
			var action := str(parts[1])
			tl.entries.append({
				"id": tl._next_id,
				"t": maxf(float(parts[0]), 0.0),
				"fwd": make_region_op(action, rect),
				"inv": inverse_region_op(action, rect),
				"origin": ORIGIN_SCHEDULED,
				"label": label,
			})
			tl._next_id += 1
	tl._sort()
	# 地图作者易错点:阈值必须**严格小于**起始钟值才会被跨越触发(见 crossings 的边界语义)。
	# 写在 w0 上或更高的事件永不触发 → 这里显式告警,避免"编排了却没发生"的静默失配。
	for e in tl.entries:
		if str(e["origin"]) == ORIGIN_SCHEDULED and float(e["t"]) >= tl.w0:
			push_warning("TimeTimeline: 事件阈值 t=%s 不小于起始钟 w0=%s,永远不会触发(标签:%s)"
					% [str(e["t"]), str(tl.w0), str(e["label"])])
	return tl


# ── 操作构造(正/逆,供解析与玩家入史共用)────────────────────────

static func make_region_op(action: String, rect: Rect2i) -> Dictionary:
	return {"op": action, "rect": rect}


## 区域型动作的逆向操作。未配对的原型 → noop(回拨时不改世界,但**会被探针记为缺口**)。
static func inverse_region_op(action: String, rect: Rect2i) -> Dictionary:
	if AUTO_INVERSE.has(action):
		return {"op": str(AUTO_INVERSE[action]), "rect": rect}
	return {"op": "noop", "rect": rect, "why": "原型无逆向操作(待实现)"}


## 玩家操作入史(§12 决议 4)。t 一般传当前世界针值;inv 必须与 fwd 严格互逆。
func record_player_op(t: float, fwd: Dictionary, inv: Dictionary, label: String = "") -> int:
	entries.append({
		"id": _next_id,
		"t": maxf(t, 0.0),
		"fwd": fwd,
		"inv": inv,
		"origin": ORIGIN_PLAYER,
		"label": label,
	})
	_next_id += 1
	_sort()
	return _next_id - 1


# ── 查询 ────────────────────────────────────────────────────

func has_entries() -> bool:
	return not entries.is_empty()


func size() -> int:
	return entries.size()


## 事件是否"已发生":世界针已降到它的阈值之下(w < t)。纯函数 → 回拨天然可重放/可重新武装。
func is_applied(entry: Dictionary, w_now: float) -> bool:
	return w_now < float(entry["t"])


## 下一个尚未触发的定时事件阈值(秒;-1=无)。HUD 预告用:取"仍在 w 之下"的最大 t。
func next_pending_t(w_now: float) -> float:
	var best := -1.0
	for e in entries:
		if str(e["origin"]) != ORIGIN_SCHEDULED:
			continue
		var t := float(e["t"])
		if t < w_now and t > best:
			best = t
	return best


## 世界针从 w_old 扫到 w_new(必须下降)时正向跨越的**定时**事件,按 t 降序(= 钟扫过的顺序)。
## 只认 scheduled:玩家操作入史后不重放。回拨(上升)不触发 → 编排的戏剧事件不会被二次轰炸。
func crossings(w_old: float, w_new: float) -> Array:
	var out: Array = []
	if w_new >= w_old:
		return out
	for e in entries:
		if str(e["origin"]) != ORIGIN_SCHEDULED:
			continue
		var t := float(e["t"])
		if w_new <= t and t < w_old:
			out.append(e)
	out.sort_custom(_cmp_fire)
	return out


## 回拨到 target_w(必须 ≥ w_now):返回**按实际发生顺序的逆序(LIFO)**要执行的逆向操作列表。
##
## 顺序推导(别按 t 降序!):世界钟下降时按 t 降序越过阈值并逐个执行正向操作;
## 回拨 = 世界钟**上升**,依次从 w_now 升到 target,**先越过最小的 t** →
## 撤销顺序 = **t 升序**(同 t 时后入史者先撤 = id 降序)。
## 例:钟曾扫过 15 与 5,回拨撤销顺序是 5 → 15(不是 15 → 5);
##     玩家在钟值 20 拆的墙(t=20,chronologically 最早)在最后才被复原。
## 每项 = {id, t, op, origin, label};scheduled 事件因 is_applied 变 false 而自动重新武装。
func rewind_ops(target_w: float, w_now: float) -> Array:
	var out: Array = []
	if target_w <= w_now:
		return out
	var picked: Array = []
	for e in entries:
		var t := float(e["t"])
		if t > w_now and t <= target_w:
			picked.append(e)
	picked.sort_custom(_cmp_undo)
	for e in picked:
		out.append({
			"id": int(e["id"]),
			"t": float(e["t"]),
			"op": e["inv"],
			"origin": str(e["origin"]),
			"label": str(e["label"]),
		})
	return out


## 兼容视图:v0.1 的 events 数组([{w, action, rect, label}],按 t 降序)。
func legacy_events() -> Array:
	var out: Array = []
	for e in entries:
		if str(e["origin"]) != ORIGIN_SCHEDULED:
			continue
		var fwd: Dictionary = e["fwd"]
		out.append({
			"w": float(e["t"]),
			"action": str(fwd.get("op", "")),
			"rect": fwd.get("rect", Rect2i()),
			"label": str(e["label"]),
		})
	return out


## 逆向操作覆盖自检(逆操作完备性铁律):返回缺逆向的原型列表。空 = 全部完备。
func incomplete_inverses() -> Array:
	var out: Array = []
	for e in entries:
		var inv: Dictionary = e["inv"]
		if str(inv.get("op", "")) == "noop":
			out.append({
				"t": float(e["t"]),
				"action": str((e["fwd"] as Dictionary).get("op", "")),
				"label": str(e["label"]),
			})
	return out


# ── 内部 ────────────────────────────────────────────────────

# 跨越(钟下降)顺序:t 降序;同 t 按入史顺序(id 升序)。entries 常驻排序也用它。
static func _cmp_fire(a, b) -> bool:
	var ta := float(a["t"])
	var tb := float(b["t"])
	if is_equal_approx(ta, tb):
		return int(a["id"]) < int(b["id"])
	return ta > tb


# 回拨撤销(钟上升)顺序:t 升序;同 t 后入史者先撤(id 降序)。
static func _cmp_undo(a, b) -> bool:
	var ta := float(a["t"])
	var tb := float(b["t"])
	if is_equal_approx(ta, tb):
		return int(a["id"]) > int(b["id"])
	return ta < tb


func _sort() -> void:
	entries.sort_custom(_cmp_fire)
