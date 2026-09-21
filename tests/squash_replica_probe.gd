extends Node
# 对手副本(`PlayerReplica`)的快照契约 + 位置平滑**行为守卫**。
# 判据:REPLICA PROBE: ALL-OK
# 跑法:"$GODOT" --headless --path . --quit-after 3600 res://tests/squash_replica_probe.tscn
#
# ★★ 文件名里的 `squash_replica` 是**历史名**,内容已经不是它了:2026-09-21 用户裁定
#   「形变只在单机模式生效」,副本上的补间形变连同 `_vel`/`_pose`/`_prev_vel_y`/`_in_water()`
#   一起整体删除(多人的落地挤压也一并取消,唯一保留的是**玩家本体**在本机落地那一下)。
#   本文件原先的四相(水中下沉中性 / 干地真落地挤压 / 落地判据两半 / 倒地中性)随之失去主体,
#   全部删除。**刻意不改路径**:改路径要连 `.tscn` 与 `.gd.uid` 一起搬,而本轮的收益为零。
#   ⇒ 若哪天要给它正名,记得 CLAUDE.md 有两处引用(搜文件名即可)。
#
# 留下的两相守的是**另外两件**仍然承重的事:
#   相⓪ **快照载荷的键集**:副本读 `pos`/`facing`/`aim`/`weapon`/`previewing`/`downed`/`pose`,
#      其中只有 `pos` 与 `pose` 是 `data["…"]` 直取(缺了会**响亮报错**),其余五个走
#      `data.get(…, 默认值)` —— 生产端**改名/删键**只会让副本静默退化成默认值(朝向恒右、
#      枪恒空手、倒地姿不变)。故这里把夹具字典的键集与 `server/match_snapshot.gd` 里那张
#      玩家载荷字段表**双向对账**:生产端少了 = 探针在喂不存在的字段(红);生产端多了 =
#      夹具漏喂(红 —— 说明"逐字一致"头注已不成立)。
#      ★ 这是**源码级**守卫(读生产文件本身,不是本探针自己的字面量)。读不到源文件/定位不到
#      那张表时**报红**而不是静默跳过 —— 源码级守卫最典型的失明方式就是"文件改了名 ⇒ 什么都
#      没读到 ⇒ 断言恒真"。
#   相①② **位置平滑**(2026-09-21 恢复的「自身差分指数追赶」)的两条不变量:
#      ① **跨接缝不得卡在远副本** —— 这是旧方案的**致命缺陷**,当年就是它把插值方案换上去的:
#         渲染位置与目标相隔整幅地图时最短向量为 0 ⇒ 副本一旦漂到远副本就**永远留在那儿**
#         (对手被渲染到屏幕外「看不见」)。现行解法是先把目标锚到本地玩家最近副本再追赶。
#         ★ 这一相是本文件存在的**主要理由**:平滑方案与插值方案来回换过一次,而"锚定"这
#         一步与"平滑 vs 插值"无关 —— 换回去时最容易顺手删掉的就是它,且删了不报错。
#      ② 收敛:静止目标下若干帧后必须落到目标上(指数 `1-exp(-INTERP_RATE·Δt)`)。
#
# ★ 逐帧显式调 `_process(DT)`、`set_process(false)` 关掉引擎那一份:引擎的 delta 是变帧率的
#   (headless 下能跑多快跑多快),而本文件的期望值全部从固定 `DT` 推出(同 `squash_host_water_probe`
#   的手法)。
# ★ 空载守卫:副本脚本解析不过时,tscn 根会退化成裸 Node2D —— 场景照样加载、判据一行不打印、
#   退出码还是 0。故 `_begin()` 里显式判 `has_method("apply_snapshot")` 并响亮报红。

const REPLICA_SCENE := preload("res://scenes/player/player_replica.tscn")

const DT: float = 1.0 / 60.0

# ── 合成网格:底行实心。本文件只关心位置数学,不需要水/梯(那些主体已随特性删除)──
const COLS := 60
const ROWS := 14
const TILE := 64
const FLOOR_TOP_Y := (ROWS - 1) * TILE        # 832
const DRY_X := 35 * TILE + 32
const REST_Y := FLOOR_TOP_Y - 57.0            # 775:站姿碰撞箱底边距原点 57px(实测)

const MAP_W := COLS * TILE                    # 3840
const MAP_H := ROWS * TILE                    # 896

# 收敛判据的容差:60 帧后残差 = exp(-INTERP_RATE) ≈ 6.1e-6 × 400px ≈ 0.0025px。
const CONVERGE_EPS := 0.5
const CONVERGE_FRAMES := 60

# 相① 的判据用**朴素**距离(不是环面最短向量):本相问的正是"渲染落在哪个副本上",
# 而环面距离会把"隔着一整幅地图"读成 60px(同一个相对位置在隔壁副本 = 环面上几乎重合)。
# 阈值:健康态 = 被锚回锚点所在副本(几 px);坏掉时 = 整幅地图宽(3840px)。
const ANCHOR_SLACK := 200.0

# ── 相⓪ 生产端字段表对账 ──
const SNAPSHOT_SRC := "res://server/match_snapshot.gd"
const SNAPSHOT_MARK := 'world["players"][str(role)] = {'

var _rep: Node2D = null
var _dead := false
var _stage := -1
var _f := 0
var _tick := 0

var _fails: Array[String] = []
var _last_err := 0.0


func _ready() -> void:
	GameParameters.MAP_WIDTH = MAP_W
	GameParameters.MAP_HEIGHT = MAP_H
	MazeGenerator.current_grid = _build_grid()
	TileDefs.load_defs()
	print("[replica] 合成世界 %dx%d 格(像素 %d×%d);干地列 x=%d" % [COLS, ROWS, int(MAP_W), int(MAP_H), DRY_X])
	_check_producer_keys()
	_begin(0)


# ── 相⓪:夹具键集 vs 生产端字段表(见文件头上半段)──
func _check_producer_keys() -> void:
	var fixture: Array = _snapshot_dict(Vector2.ZERO, 0, false, Vector2.ZERO).keys()
	fixture.sort()
	var producer := _producer_keys()
	if producer.is_empty():
		_record("相⓪ 前提:能从 %s 里定位到玩家载荷字典" % SNAPSHOT_SRC, false,
			"读到的字段表为空(文件改名?那张表被重写了?)—— 静默跳过会让本相退化成空转")
		return
	var missing: Array = []
	for k in fixture:
		if not producer.has(k):
			missing.append(k)
	var extra: Array = []
	for k in producer:
		if not fixture.has(k):
			extra.append(k)
	_record("相⓪ 夹具键集 == server/match_snapshot.gd 的玩家载荷字段表",
		missing.is_empty() and extra.is_empty(),
		"夹具 %d 键 / 生产端 %d 键;生产端缺 %s(探针在喂不存在的字段)、夹具漏喂 %s" % [
			fixture.size(), producer.size(), str(missing), str(extra)])


# 从生产端源码里取出那张字面量表的键(升序)。
# ★ 用 `code_only`(剥注释)而不是裸文本:一句提到字段名的**注释**会把被删掉的键重新喂绿。
func _producer_keys() -> Array:
	var code := ScanUtil.code_only(ScanUtil.read(SNAPSHOT_SRC))
	var at := code.find(SNAPSHOT_MARK)
	if at < 0:
		return []
	var open := at + SNAPSHOT_MARK.length() - 1        # 指向 '{'
	var close := _match_brace(code, open)
	if close < 0:
		return []
	var block := code.substr(open + 1, close - open - 1)
	# 该表的**值**全是表达式(没有字符串字面量),故 `"名":` 这个形状只会匹配到键。
	# 将来若真出现"值是字符串"的字段,这里要改成按顶层逗号切分。
	var re := RegEx.new()
	re.compile("\"([A-Za-z_][A-Za-z0-9_]*)\"\\s*:")
	var out: Array = []
	for m in re.search_all(block):
		out.append(m.get_string(1))
	out.sort()
	return out


# 与 open 处 '{' 配对的 '}' 下标(跳过字符串内的花括号;找不到返回 -1)。
# 形状照 ScanUtil.match_paren —— 那一支只认圆括号。
func _match_brace(src: String, open: int) -> int:
	var depth := 0
	var in_str := false
	var j := open
	while j < src.length():
		var ch := src[j]
		if in_str:
			if ch == "\\":
				j += 2                                  # 转义:连同下一字符一起跳过
				continue
			if ch == "\"":
				in_str = false
		elif ch == "\"":
			in_str = true
		elif ch == "{":
			depth += 1
		elif ch == "}":
			depth -= 1
			if depth == 0:
				return j
		j += 1
	return -1


func _build_grid() -> Array[Array]:
	var ts_wall := 31            # 纹理1 全砖(墙)
	var grid: Array[Array] = []
	for y in range(ROWS):
		var row: Array[int] = []
		for x in range(COLS):
			row.append(ts_wall if y == ROWS - 1 else 0)
		grid.append(row)
	return grid


# ── 每相换一个**全新**的副本 ──
func _begin(stage: int) -> void:
	_stage = stage
	_f = 0
	_tick = 0
	_last_err = 0.0
	if _rep != null and is_instance_valid(_rep):
		_rep.queue_free()
	_rep = REPLICA_SCENE.instantiate()
	if not _rep.has_method("apply_snapshot"):
		_dead = true
		print("REPLICA PROBE: FAIL | PlayerReplica 脚本没加载起来(解析错?根节点是 %s)" % _rep.get_class())
		get_tree().quit(1)
		return
	add_child(_rep)
	_rep.global_position = Vector2(DRY_X, REST_Y)
	_rep.set_process(false)     # 本探针逐帧显式调 `_process(DT)`,见文件头


# 喂一份**真快照字典**(键与 server/match_snapshot.gd 的 world["players"][role] 逐字一致)。
# 夹具字典的**唯一构造点**(相⓪ 拿它的键集与生产端对账 ⇒ 只有一份,不会两处各写一遍)。
func _snapshot_dict(vel: Vector2, pose: int, downed: bool, pos: Vector2) -> Dictionary:
	return {
		"pos": pos,
		"vel": vel,
		"facing": 1,
		"pose": pose,
		"weapon": 0,
		"hp": 100,
		"waterproof": 100.0,
		"downed": downed,
		"aim": Vector2(1.0, 0.0),
		"previewing": false,
	}


# 一步:喂快照 + 显式跑一帧 `_process`。
# ★ 位置用**副本当前渲染位置**回喂:本文件测的是"目标→渲染"的追赶数学,与权威轨迹无关。
func _step(canonical: Vector2, anchor: Vector2) -> void:
	_rep.apply_snapshot(_snapshot_dict(Vector2.ZERO, 0, false, canonical), anchor, _tick)
	_tick += 1
	_rep._process(DT)
	_f += 1
	# ★ **朴素**距离,不走环面最短向量 —— 见 ANCHOR_SLACK 的说明。
	_last_err = (anchor - _rep.global_position).length()


func _physics_process(_delta: float) -> void:
	if _dead or _rep == null or not is_instance_valid(_rep):
		return
	match _stage:
		0:
			_tick_anchor()
		1:
			_tick_recover()
		2:
			_tick_converge()


# ── 相① **跨接缝不得卡在远副本**(本文件存在的主要理由,见文件头)──
# 构造:本地锚点与 canonical 目标都在图的**左下角**,而副本的渲染位置被摆到
#   **「同一个相对位置、右边隔壁那个副本」**——即朴素坐标上正好差**一整幅地图宽**。
#   ★ 这个位置是精心挑的,不是随手取的:它正是旧方案失效的充要条件 ——
#     `toroidal_delta_px(渲染位置, 目标)` 在朴素差恰好等于一整幅地图宽时给出 **0**
#     (环面取模把整圈抹平),于是"沿最短向量追赶"得到零位移,副本**永远留在那儿**
#     (在玩家屏幕外「看不见」)。
#   健康态:`_process` 先把**目标**锚到本地最近副本、再把渲染结果锚一次 ⇒ 渲染被搬回可见副本。
# ★ 前提断言把上述机制**直接钉在构造上**:初始位置下那个"最短向量"必须真的是 0 ——
#   否则本相只是"在附近追赶",什么都没测(几何一漂就会静默退化成这种空转)。
func _tick_anchor() -> void:
	var anchor := Vector2(200.0, MAP_H - 200.0)
	var canonical := Vector2(260.0, MAP_H - 200.0)     # 锚点近旁的权威位置
	if _f == 0:
		# 摆到"右边隔壁那个副本":朴素坐标 = canonical + 一整幅地图宽。
		_rep.global_position = canonical + Vector2(MAP_W, 0.0)
		var raw := MazeGenerator.toroidal_delta_px(
				_rep.global_position, canonical, MAP_W, MAP_H)
		_record("相① 前提:该位置下「最短向量」确实是 0(旧方案的失效条件真的被构造出来了)",
			raw.length() < 1e-6,
			"toroidal_delta_px(渲染, 目标) = %s;朴素差 = %.1fpx = 一整幅地图宽(%.1f)" % [
				str(raw), _rep.global_position.x - canonical.x, MAP_W])
		var start_err := (anchor - _rep.global_position).length()
		_record("相① 前提:初始渲染位置离锚点有整幅地图量级(朴素距离)", start_err > MAP_W * 0.5,
			"初始朴素距离 %.1fpx(需 > %.1f)" % [start_err, MAP_W * 0.5])
		_step(canonical, anchor)
		_record("相① 首次定位**直落**(一帧内到位,不做指数追赶)",
			_last_err <= ANCHOR_SLACK,
			"首帧后与锚点的朴素距离 %.2fpx(需 <= %.1f);从创建位置开始追赶要十几帧才到,而" % [
				_last_err, ANCHOR_SLACK]
			+ "那十几帧里幽灵体停在错位置 ⇒ replica_ghost_probe ② 实测 rb=0→1")
		_begin(1)


# ── 相①b 稳态(已定位过)下的**跨接缝远副本**:这才是"锚定"承重的那条路径 ──
# 相① 走的是 `_placed` 那条直落支路,把锚定那两行删掉它**照样绿** ⇒ 必须另有一相在
# `_placed == true` 的前提下构造同一个"朴素差 = 一整幅地图宽"的位置。
# 变异(必做):删掉 `_process` 末尾那句"渲染位置归到本地锚点最近副本" ⇒ 本相必须红
#   (副本原地不动,朴素距离恒 ≈ 一整幅地图宽 = 屏幕外)。
func _tick_recover() -> void:
	var anchor := Vector2(200.0, MAP_H - 200.0)
	var canonical := Vector2(260.0, MAP_H - 200.0)
	if _f == 0:
		# 手工把副本标成"已定位过"(它代表稳态:进场那一帧早就过去了)。
		_rep._placed = true
		_rep.global_position = canonical + Vector2(MAP_W, 0.0)
		var raw := MazeGenerator.toroidal_delta_px(
				_rep.global_position, canonical, MAP_W, MAP_H)
		_record("相①b 前提:稳态下「最短向量」同样为 0(同样的失效条件)",
			raw.length() < 1e-6, "toroidal_delta_px(渲染, 目标) = %s" % str(raw))
		_step(canonical, anchor)
		return
	_step(canonical, anchor)
	if _f >= CONVERGE_FRAMES:
		_record("相①b 稳态跨接缝:渲染被搬回本地锚点所在副本",
			_last_err <= ANCHOR_SLACK,
			"%d 帧后与锚点的**朴素**距离 %.2fpx(需 <= %.1f;删掉锚定那一步时会停在约 %.0fpx = 屏幕外)" % [
				CONVERGE_FRAMES, _last_err, ANCHOR_SLACK, MAP_W - 60.0])
		_begin(2)


# ── 相② 收敛:静止目标下必须落到目标上(指数追赶的基本正确性)──
func _tick_converge() -> void:
	var anchor := Vector2(DRY_X, REST_Y)
	var canonical := anchor + Vector2(400.0, 0.0)      # 同副本内的静止目标
	_step(canonical, anchor)
	if _f >= CONVERGE_FRAMES:
		# 同副本内,直接用朴素距离(与相① 同口径)。
		var got := (canonical - _rep.global_position).length()
		var rate := _interp_rate()
		# ★ 详情串里**不能出现 `%e`** —— Godot 的 `String %` 不支持它(会打
		# "unsupported format character" 并把整串原样吐出来,判据看起来像"红"但其实是格式错)。
		_record("相② 静止目标下 %d 帧内收敛" % CONVERGE_FRAMES, got <= CONVERGE_EPS,
			"距目标 %.4fpx(需 <= %.3f;INTERP_RATE=%.1f 时 60 帧残差 = exp(-%.1f)×400 = %.4f)" % [
				got, CONVERGE_EPS, rate, rate, exp(-rate) * 400.0])
		_finish()


# 读生产端的 `INTERP_RATE`(`const`,走 get_script_constant_map —— 直接取不存在的属性会抛错,
# 而"常量被改名"正是这条守卫最该响亮报出来的场景)。
func _interp_rate() -> float:
	var scr = load("res://scenes/player/player_replica.gd")
	if scr == null:
		return 0.0
	var m: Dictionary = (scr as GDScript).get_script_constant_map()
	return float(m.get("INTERP_RATE", 0.0))


func _record(label: String, ok: bool, detail: String) -> void:
	print("[replica] %s %s —— %s" % ["OK  " if ok else "FAIL", label, detail])
	if not ok:
		_fails.append("%s(%s)" % [label, detail])


func _finish() -> void:
	if _rep != null and is_instance_valid(_rep):
		_rep.queue_free()
	if _fails.is_empty():
		print("REPLICA PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("REPLICA PROBE: FAIL | %d 条: %s" % [_fails.size(), "; ".join(_fails)])
		get_tree().quit(1)
