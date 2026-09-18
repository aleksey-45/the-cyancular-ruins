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
# ── 时间层语法(.cyrt 时空地图为正式载体;v4 注释行继续兼容)──
#   # cyrt-v1                                    ← .cyrt 首行标记(空间层=v3 网格,原样)
#   # tl-w0: <起始秒>                             ← 世界针起始(缺省 TimeParams.W0_DEFAULT)
#   # tl: <t> <kind> <位置参数…> [k=v 标志…] [标签…]
#   例:# tl: 15 collapse 22 20 17 11 rev=1 桥梁坍塌
#       # tl: 12 explode 30 18 4 dmg=45 燃气爆炸
#       # tl: 11 wipe 40 10 3 rev=0 强制塌方
#       # tl: 10 gen 40 30 6 3 tex=19 增生岩壁
#       # tl: 8 spawn_enemy 50 20 type=fly_bird count=2 空降鸟群
# kind 与位置参数(坐标=空间层格坐标;t 支持小数秒):
#   collapse/open x y w h            区域变实心/变空气(经典两件套)
#   gen x y w h [tex=N]              生成实体砖块(默认纹理 1)
#   explode cx cy radius [dmg=] [kb=] 战斗规则爆炸:可破坏瓦片按衰减扣血/永久墙免疫,
#                                    实体伤害走 Explosion(LOS 掩护/内圈满伤/击退)
#   wipe cx cy radius [dmg=]         强制清除:范围内一切砖无条件变空气(含永久墙),
#                                    实体吃固定伤害(不衰减/无 LOS)
#   spawn_enemy cx cy [type=] [count=] 实体生成(注册表 editor/enemies.json)
# 标志(所有 kind 通用):
#   rev=0/1  可逆性(默认 1):0=回拨不撤销本事件(逆操作 noop);1=回拨按逆操作撤销
#   re=0/1   重播(默认 1):仅对 rev=0 有意义——回拨后再次扫过阈值是否重播;
#            re=0 的事件首次触发即"已消耗",永不重播。rev=1 的事件回拨后天然重新武装。
# 逆操作来源:collapse/open 静态互换;gen/explode/wipe 解析时预置 restore_pristine,
# **执行时由 Level0 捕获实际变化回填 restore_cells**(精确逆;探针可断言升级路径);
# spawn_enemy 逆 = despawn_spawn(spawn_id)——只 despawn 仍存活者,已死者不复活(不撤战果)。
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
			var entry: Variant = parse_tl_line(line.trim_prefix("# tl:").strip_edges())
			if entry == null:
				continue
			entry["id"] = tl._next_id
			# spawn_enemy 的逆操作需要条目 id(despawn_spawn 按id找活体)→ 分配后回填
			if str((entry["inv"] as Dictionary).get("op", "")) == "despawn_spawn":
				(entry["inv"] as Dictionary)["spawn_id"] = tl._next_id
			tl.entries.append(entry)
			tl._next_id += 1
	tl._sort()
	# 地图作者易错点:阈值必须**严格小于**起始钟值才会被跨越触发(见 crossings 的边界语义)。
	# 写在 w0 上或更高的事件永不触发 → 这里显式告警,避免"编排了却没发生"的静默失配。
	for e in tl.entries:
		if str(e["origin"]) == ORIGIN_SCHEDULED and float(e["t"]) >= tl.w0:
			push_warning("TimeTimeline: 事件阈值 t=%s 不小于起始钟 w0=%s,永远不会触发(标签:%s)"
					% [str(e["t"]), str(tl.w0), str(e["label"])])
	return tl


# 各 kind 的位置参数个数(解析与编辑器共用校验);未登记的 kind 整行忽略。
const KIND_ARITY: Dictionary = {
	"collapse": 4, "open": 4, "gen": 4,
	"explode": 3, "wipe": 3, "spawn_enemy": 2,
}


## 解析单条 `# tl:` 内容(纯函数,探针/编辑器共用):
## `<t> <kind> <位置参数…> [k=v 标志…] [标签…]`;格式不合 → null(调用方跳过该行)。
static func parse_tl_line(body: String) -> Variant:
	var toks := body.split(" ", false)
	if toks.size() < 2:
		return null
	var kind := str(toks[1])
	if not KIND_ARITY.has(kind):
		return null
	var arity: int = KIND_ARITY[kind]
	if toks.size() < 2 + arity:
		return null
	var nums: Array[int] = []
	for i in arity:
		nums.append(int(toks[2 + i]))
	var flags := {}
	var label_toks: PackedStringArray = []
	for tok in toks.slice(2 + arity):
		var s := str(tok)
		if s.length() > 1 and s.contains("=") and not s.begins_with("="):
			var kv := s.split("=", true, 1)
			flags[kv[0].to_lower()] = kv[1]
		else:
			label_toks.append(s)
	var rev := not _flag_off(flags, "rev")
	var re_play := not _flag_off(flags, "re")
	return make_entry(maxf(float(toks[0]), 0.0), kind, nums, flags, rev, re_play,
			" ".join(label_toks))


static func _flag_off(flags: Dictionary, key: String) -> bool:
	var v := str(flags.get(key, "1")).to_lower()
	return v == "0" or v == "false" or v == "no" or v == "off"


## 按构造条目(kind → fwd/inv)。inv 规则见文件头注释;rev=0 一律 noop。
static func make_entry(t: float, kind: String, nums: Array[int], flags: Dictionary,
		rev: bool, re_play: bool, label: String) -> Dictionary:
	var fwd := {}
	var inv := {}
	match kind:
		"collapse", "open":
			var rect := Rect2i(nums[0], nums[1], nums[2], nums[3])
			fwd = {"op": kind, "rect": rect}
			inv = {"op": str(AUTO_INVERSE[kind]), "rect": rect}
		"gen":
			var rect := Rect2i(nums[0], nums[1], nums[2], nums[3])
			var tex := clampi(int(str(flags.get("tex", "1"))), 1, 22)
			fwd = {"op": "gen", "rect": rect, "tex": tex}
			inv = {"op": "restore_pristine", "rect": rect}
		"explode", "wipe":
			var c := Vector2i(nums[0], nums[1])
			var r := maxi(nums[2], 0)
			var rect := Rect2i(c.x - r, c.y - r, r * 2 + 1, r * 2 + 1)
			if kind == "explode":
				fwd = {"op": "explode", "center": c, "radius": r, "rect": rect,
						"dmg": int(str(flags.get("dmg", str(int(TimeParams.EVT_EXPLODE_DMG))))) ,
						"kb": float(str(flags.get("kb", str(TimeParams.EVT_EXPLODE_KB))))}
			else:
				fwd = {"op": "wipe", "center": c, "radius": r, "rect": rect,
						"dmg": int(str(flags.get("dmg", str(int(TimeParams.EVT_WIPE_DMG)))))}
			inv = {"op": "restore_pristine", "rect": rect}
		"spawn_enemy":
			var c := Vector2i(nums[0], nums[1])
			fwd = {"op": "spawn_enemy", "center": c,
					"etype": str(flags.get("type", "fly_bird")),
					"count": clampi(int(str(flags.get("count", "1"))), 1, 12)}
			inv = {"op": "despawn_spawn", "spawn_id": -1}   # id 在 parse_lines 分配后回填
	if not rev:
		inv = {"op": "noop", "why": "rev=0 不可逆(作者标注)"}
	return {
		"t": t, "fwd": fwd, "inv": inv,
		"origin": ORIGIN_SCHEDULED, "label": label,
		"rev": rev, "re": re_play, "consumed": false,
	}


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
		"rev": true, "re": false, "consumed": false,
	})
	_next_id += 1
	_sort()
	return _next_id - 1


## 执行层回填精确逆操作:Level0 执行 explode/wipe/gen 后,把**实际捕获的格变化**
## (restore_cells)写回条目,替代解析期预置的 restore_pristine(后者会把区域里
## 别的历史变化一并还原,只作未执行时的兜底)。
func set_inverse(id: int, inv: Dictionary) -> void:
	for e in entries:
		if int(e["id"]) == id:
			e["inv"] = inv
			return


## 标记事件"已消耗"(re=0 的一次性语义):触发后不再重播(跨过也不再生效)。
## 由 TimeWorld.tick 在发出到点事件时对 re=0 者调用;crossings/next_pending_t 跳过已消耗。
func mark_consumed(id: int) -> void:
	for e in entries:
		if int(e["id"]) == id:
			e["consumed"] = true
			return


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
		if str(e["origin"]) != ORIGIN_SCHEDULED or bool(e.get("consumed", false)):
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
		if str(e["origin"]) != ORIGIN_SCHEDULED or bool(e.get("consumed", false)):
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
## rev=0 的 noop 是**作者标注的不可逆**,不算缺口;玩家入史条目缺逆才算。
func incomplete_inverses() -> Array:
	var out: Array = []
	for e in entries:
		if not bool(e.get("rev", true)):
			continue
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
