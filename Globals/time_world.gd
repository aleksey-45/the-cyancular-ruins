class_name TimeWorld
extends RefCounted

# 时空地图(时间维度)的**门面**:level_0 / 表盘 HUD / 探针使用的稳定 API。
#
# v0.3 起内部改为「单钟账本 TimeClock + 事件溯源日志 TimeTimeline」两件套,本类只做编排与
# 兼容:v0.1 垂直切片的 API(parse_for / has_events / next_trigger / tick / w0 / w / events)
# **保持不变** → level_0.gd 与既有探针零改动即可升级到单钟模型。
#
# 分工:
#   TimeParams   → 参数总表(单位换算/阶段/回收表)
#   TimeClock    → 唯一改 W 的账本(衰减/回拨/消费/子弹时间/粒度)
#   TimeTimeline → 事件日志(正逆操作/LIFO 回拨/重新武装/玩家操作入史)
#   TimeWorld    → 门面,把"钟走了一格"翻译成"哪些事件到点了"

var clock: TimeClock = null
var timeline: TimeTimeline = null

# ── 兼容字段(level_0 读 w 做表盘;旧探针读 w0 / events)──
var w0: float = TimeParams.W0_DEFAULT
var w: float = TimeParams.W0_DEFAULT
var events: Array = []


## 解析地图文件的时间层(无 '# tl:' 行 = 普通图,事件为空)。
static func parse_for(map_path: String) -> TimeWorld:
	var tw := TimeWorld.new()
	tw.timeline = TimeTimeline.parse_for(map_path)
	tw.clock = TimeClock.new(tw.timeline.w0)
	tw._sync()
	return tw


## 直接由时间线构造(探针/联机复用同一时间线数据)。
static func from_timeline(tl: TimeTimeline) -> TimeWorld:
	var tw := TimeWorld.new()
	tw.timeline = tl
	tw.clock = TimeClock.new(tl.w0)
	tw._sync()
	return tw


func has_events() -> bool:
	return timeline != null and timeline.has_entries()


## 下一个未触发的定时事件阈值(秒;-1=无)。HUD 预告用。
func next_trigger() -> float:
	if timeline == null:
		return -1.0
	return timeline.next_pending_t(clock.w if clock != null else w)


## 推进 delta 秒 → 返回本轮到点(正向跨越阈值)的事件。顺序 = 世界针扫过的顺序(t 降序)。
## 载荷:{index, w, action, rect, fwd, rev, label}——action/rect 兼容 v0.1 消费方
## (圆形事件的 rect 为外接矩形,执行细节看 fwd.center/fwd.radius);re=0 的事件
## 发出即标记"已消耗"(一次性语义,回拨后也不重播)。
func tick(delta: float) -> Array:
	if timeline == null or clock == null:
		return []
	var before := clock.w
	clock.elapse(delta)
	w = clock.w
	var due: Array = []
	for e in timeline.crossings(before, clock.w):
		if not bool(e.get("re", true)):
			timeline.mark_consumed(int(e["id"]))
		var fwd: Dictionary = e["fwd"]
		due.append({
			"index": int(e["id"]),
			"w": float(e["t"]),
			"action": str(fwd.get("op", "")),
			"rect": fwd.get("rect", Rect2i()),
			"fwd": fwd,
			"rev": bool(e.get("rev", true)),
			"label": str(e["label"]),
		})
	return due


## 回拨世界针到 target(秒,须 ≥ 当前 w):把 W 抬回去并返回要执行的逆向操作,
## **顺序 = 世界钟上升方向(t 升序)**,即实际发生顺序的逆序(LIFO)——先撤最小阈值,最后撤玩家最早的改动。
## 由调用方(level_0)按序改写世界。scheduled 事件自动重新武装(可再次跨越触发)。
func rewind_to(target: float) -> Array:
	if timeline == null or clock == null:
		return []
	var ops := timeline.rewind_ops(target, clock.w)
	clock.recover(maxf(target - clock.w, 0.0), "rewind")
	w = clock.w
	return ops


## 玩家操作入史(§12 决议 4;击杀不入史)。fwd/inv 必须严格互逆。
func record_player_op(fwd: Dictionary, inv: Dictionary, label: String = "") -> int:
	if timeline == null or clock == null:
		return -1
	return timeline.record_player_op(clock.w, fwd, inv, label)


## 执行层回填精确逆操作(explode/wipe/gen 执行后把捕获的实际格变化写回条目)。
func set_inverse(id: int, inv: Dictionary) -> void:
	if timeline != null:
		timeline.set_inverse(id, inv)


func phase() -> int:
	return clock.phase() if clock != null else 0


func destruction() -> float:
	return clock.destruction() if clock != null else 0.0


func label() -> String:
	return clock.label() if clock != null else TimeParams.format_clock(w)


## 决策时停 / 慢放(§12 决议 3):交易·合成·地图 UI 打开时置 SCALE_PAUSE。
func set_scale(v: float) -> void:
	if clock != null:
		clock.set_scale(v)


## 区域流速场 F(§3):涨潮区 FLOW_RUSH / 时滞区 FLOW_LAG / 时间风暴 FLOW_STORM。
func set_flow(v: float) -> void:
	if clock != null:
		clock.set_flow(v)


## 逆操作完备性自检(探针用:任何入史 kind 缺逆向 = 幽灵状态风险)。
func incomplete_inverses() -> Array:
	return timeline.incomplete_inverses() if timeline != null else []


func _sync() -> void:
	w0 = timeline.w0
	w = clock.w
	events = timeline.legacy_events()
