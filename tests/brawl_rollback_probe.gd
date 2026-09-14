extends Node

# 贴身缠斗回滚探针(场景模式):量「N 人贴身缠斗时,C2 每秒回滚多少次」。
# 跑法:
#   "$GODOT" --headless --path . res://tests/brawl_rollback_probe.tscn
# 期望:末行 "BRAWL ROLLBACK PROBE: ALL-OK"。
#
# ═══ 为什么需要它(补一个从没量过的空白)═══
# `docs/superpowers/specs/2026-09-12-royale-c2-migration-design.md` §7 的 ★★★ 风险写得很清楚:
# C2 下客户端只预测自己的玩家,客户端世界里的对手只是「位置来自快照的幽灵体」,而服务器上是
# N 具真 CharacterBody2D 互相推挤 → 贴身即分歧 → 回滚。但**这个风险一直是定性的**:
#   · `replica_ghost_probe` 给的「0 回滚」是**固定场景**(预测端被一个**静止**幽灵体挡住);
#   · 真实缠斗里两边都在动,是完全不同的信息差;
#   · 于是「每具身体贡献多少回滚」这个**单价**一直未知 → N=4/6/8 的外推全是猜。
# 本探针就补这一格:让对手**真的动起来**,量回滚的**斜率**(次/秒)。
#
# ═══ 世界怎么搭(与 replica_ghost_probe 同一套分层技巧)═══
# 权威与预测必须活在同一棵树的**同一个物理空间**里(同 viewport 共享 space),靠碰撞层分开:
#   权威侧:A(预测对象的权威孪生) + O_1..O_{N-1}(对手真身)  → 层 LAYER_AUTH,互相碰撞
#   客户端侧:P(被预测玩家) + N-1 个 PlayerReplica 的幽灵体     → P 认 LAYER_GHOST
#   A 的 mask 含 AUTH 不含 GHOST → A 看不见幽灵体;P 的 mask 含 GHOST 不含 AUTH → P 看不见真身。
# 两条链路各自的几何都在场,唯一变量是「P 的世界里那具身体在哪」。
#
# ═══ 四个变体 ═══
#   STATIC  对手站着不动           —— 健全性对照:幽灵体零滞后 → 回滚应当恰好 0
#   NONE    幽灵体摘掉(层置 0)    —— 负向对照:回滚应当爆炸
#   PROD    幽灵体 = 最新已收快照的位置(= t-DELAY 那一帧)= **今天的行为**
#   EXTRAP  PROD + 对手速度 × 延迟  —— 本探针要量的杠杆
# ★ L1(幽灵体用最新位置)与 L3(幽灵体内缩)两个变体已被实测判定买不到目标,已删 ——
#   见 docs/superpowers/specs/2026-09-12-royale-c2-migration-design.md §2.1/§4.4/§8。
#
# ★★ 本探针的模拟必须**每帧一步**(在 _physics_process 里):刚体的位移只在**跨帧**时才对
#   物理空间可见。把整段模拟塞进一帧的写法会让幽灵体一次都动不了(实测:
#   rollback_fidelity_probe 的 B 组就是这个形状,PROD 与 EXTRAP 读数一字不差)。
#
# ⚠ 判据 grep 文本 "BRAWL ROLLBACK PROBE: ALL-OK"(不能只看退出码:探针中途报错时
#   `--quit-after` 仍可能 exit 0 且不打印 ALL-OK)。

# ★ 地图要**足够宽**:缠斗里双方会整体漂移,6s 能漂 ~2500px。地图太窄就会让玩家跨过环面接缝,
#   而跨接缝会让「A 与 P 的原始坐标差」瞬间等于一整幅地图宽 —— 那是**回绕伪影,不是分歧**。
#   第一版用 64 格宽(4096px),读数被这个伪影污染成 4000+px,整张表不可用。
const COLS := 200
const ROWS := 12
const TILE := 64
const DT := 1.0 / 60.0

const DELAY := 8          # 权威整态投递延迟(tick);与 pvp_reconcile_smoke / ghost_probe 同款
const RUN := 360          # 每趟 tick 数(6s)
const SPACING := 96.0     # 出生点间距(玩家碰撞箱 ≈80px 宽,留余量不初始重叠)
const REACH := 200.0      # A 面前留出的空场(让包能动起来,不是一开局就顶死)

const LAYER_AUTH := 32    # 层6:权威侧(真身之间互相碰撞)
const LAYER_GHOST := 2    # 层2:玩家层 —— P 认这一层,幽灵体就在这层

enum Variant { NONE, STATIC, PROD, TOL2, TOL4, TOL8, EXTRAP }

# 诊断开关:置 true 时每 60 tick 打一行位置/分歧/rb。只在排查探针本身时打开
# (正常跑要关,否则读数被刷屏;本仓判绿靠 grep 末行,不靠日志长度)。
const TRACE := false

const VARIANT_NAME := ["幽灵体摘除(对照)", "对手站着不动(健全性对照)",
		"容差 1px(历史基线)", "容差 2px(已采纳)", "容差 4px", "容差 8px", "幽灵体外推(已证伪)"]

# 各变体的位置容差(px)。**全部显式写**:控制器的默认值已采纳 2.0(见其 DEFAULT_POS_TOL),
# 不写死的话"历史基线"那一档会跟着默认值漂,表就不可比了。
const VARIANT_TOL := [1.0, 1.0, 1.0, 2.0, 4.0, 8.0, 1.0]

var _host: Node2D = null
var _spawn := Vector2.ZERO
var _failures: Array[String] = []
var _rows: Array = []   # 每项 {n:int, variant:int, rb:int, text:String}(要按 N+变体取数)

# ★ 假绿/挂死防线(本仓被抓过四次的那一类):Godot 的运行时错误只**中断当前函数**,调用它的
#   `_ready()` 会照常往下走 —— 「_run_pass 中途报错 → 一条 _check 都没跑到 → _failures 仍空
#   → 照样打印 ALL-OK」。而 _run_pass 是 async:若错误发生在 await **之后**,
#   `_pass_finished` 永不发射 → 本探针干脆挂死(所以跑它必须带 --quit-after 当安全网)。
#   两道都堵:每个 pass 在**最后一行**盖完成戳,`_ready` 收官时逐条核。
var _ran: Dictionary = {}

func _require_ran(name: String) -> void:
	if not _ran.has(name):
		_fail("%s 没跑到最后一行(中途报错或被跳过)→ 本趟读数不可信" % name)


func _pass_key(variant: int, n: int) -> String:
	return "pass_%d_%d" % [variant, n]

# 单趟状态
var _variant: int = Variant.PROD
var _n := 2
var _running := false
var _tick := 0
var _contact_ticks := 0
var _max_dev := 0.0
var _rb_devs: Array[float] = []   # 每次回滚发生时的修正量(px)
var _devs: Array[float] = []      # 接触期间的 |A-P|(px)= 容忍住的稳态偏差(软接触)

var A = null                      # 权威孪生
var _opps: Array = []             # 对手真身(权威侧)
var _opp_srcs: Array = []         # 对手输入源
var P = null                      # 被预测玩家
var ctrl := PredictionRollback.new()
var srcA: NetworkInputSource = NetworkInputSource.new()
var _a_hist: Array[Dictionary] = []
var _opp_hist: Array = []         # 每个对手的 capture_state 历史(tick -> state)
var _replicas: Array = []         # PlayerReplica
var _ghosts: Array = []           # 各自的 GhostBody(StaticBody2D)

signal _pass_finished


func _ready() -> void:
	# ★ 把 idle 帧率钉到 60:副本的插值时钟在 `_process`(idle)里按 delta 推进,而本探针的模拟
	#   在 `_physics_process`(60Hz)里走。headless 默认 idle 不限速 → 两者比速不可控。
	#   本探针已关掉副本的 `_process`(位置全部显式写),这一句是防万一。
	# ★★ 更重要的是:**模拟必须每帧一步**。刚体位移只在跨帧时对物理空间可见;把整段模拟塞进
	#   一帧的写法会让幽灵体一次都动不了(rollback_fidelity_probe 的 B 组就是这么废掉的)。
	Engine.max_fps = 60
	GameParameters.MAP_WIDTH = COLS * TILE
	GameParameters.MAP_HEIGHT = ROWS * TILE
	MazeGenerator.current_grid = _build_grid()
	TileDefs.load_defs()
	_host = Node2D.new()
	add_child(_host)
	WorldBuilder.build_sim(_host, MazeGenerator.current_grid)
	# 出生放在左三分之一(右侧留够漂移空间,整趟不跨接缝)
	_spawn = Vector2(60 * TILE + TILE * 0.5, (ROWS - 1) * TILE - 80.0)

	print("[brawl] 世界 %d×%d 格,出生 %s;每趟 %d tick(%.1fs),投递延迟 %d tick" % [
			COLS, ROWS, str(_spawn), RUN, float(RUN) / 60.0, DELAY])
	print("[brawl] 读法:回滚斜率 = 次/秒;**每接触秒**把它按接触时长归一,便于跨 N 比较")
	print("")

	# 跑批清单**声明一次**,循环与"完成戳核对"共用它 —— 免得日后加了个变体却忘了加断言。
	var passes: Array = []
	for n in [2, 8]:
		passes.append([Variant.NONE, n])        # 负向对照:证明摘掉幽灵体会爆炸
	# ★ 健全性对照(决定性实验):对手**站着不动**,其余一切不变。
	#   它收敛到 ~0 回滚,而"会动的对手"那一族稳定在 170~250,说明本探针量到的不是噪声,
	#   而是「回放时对手身体**没有被倒回**」这个结构性事实 —— 见文件末的 _summarize。
	for n in [2, 8]:
		passes.append([Variant.STATIC, n])
	for v in [Variant.PROD, Variant.TOL2, Variant.TOL4, Variant.TOL8, Variant.EXTRAP]:
		for n in [2, 4, 8]:
			passes.append([v, n])

	for p in passes:
		await _run_pass(int(p[0]), int(p[1]))
	for p in passes:
		_require_ran(_pass_key(int(p[0]), int(p[1])))

	# ★ 采纳值守卫(只查一次):控制器**默认**容差必须是采纳后的档位。改回 1.0 会让真机频率
	#   回到 ~37 次/秒,而那是**静默**的(不报错、探针也照绿)—— 故把"默认值"本身变成断言。
	#   注:消息里避开裸 % 号,否则 % 格式化会因非法转换而整个失效(实测踩过)。
	var tol: float = PredictionRollback.new().pos_tol
	_check(tol >= 2.0, "控制器默认容差已采纳(要求 >= 2px,实际 %.1f px)" % tol)

	_summarize()

	if _failures.is_empty():
		print("BRAWL ROLLBACK PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("BRAWL ROLLBACK PROBE: FAIL")
		for f in _failures:
			print("[brawl]   ✗ %s" % f)
		get_tree().quit(1)


# ── 单趟 ──
func _run_pass(variant: int, n: int) -> void:
	_variant = variant
	_n = n
	_tick = 0
	_contact_ticks = 0
	_max_dev = 0.0
	_rb_devs = []
	_devs = []
	_a_hist = []
	_opp_hist = []
	_opps = []
	_opp_srcs = []
	_replicas = []
	_ghosts = []
	ctrl = PredictionRollback.new()
	# ★ 容差是回滚频率的闸门(见 core/prediction_rollback.gd 的 pos_tol 注释)
	ctrl.pos_tol = VARIANT_TOL[variant]
	srcA = NetworkInputSource.new()

	var pack_x := _spawn.x + REACH

	# 权威孪生 A:层 AUTH,mask = 地形 + AUTH(与对手真身互相碰撞)
	A = _make_player("AuthA", _spawn)
	A.collision_layer = LAYER_AUTH
	A.collision_mask = 1 | LAYER_AUTH
	A.set_input_source(srcA)
	A.set_physics_process(false)

	# 对手真身 O_1..O_{N-1}:同层,彼此也碰撞
	for i in range(n - 1):
		var o = _make_player("Opp%d" % i, Vector2(pack_x + SPACING * float(i), _spawn.y))
		o.collision_layer = LAYER_AUTH
		o.collision_mask = 1 | LAYER_AUTH
		var s := NetworkInputSource.new()
		o.set_input_source(s)
		o.set_physics_process(false)
		_opps.append(o)
		_opp_srcs.append(s)
		_opp_hist.append([])

	# 被预测玩家 P:层 0(不被任何人看见),mask = 地形 + 幽灵层
	P = _make_player("PredP", _spawn)
	P.collision_layer = 0
	P.collision_mask = 1 | LAYER_GHOST
	P.set_physics_process(false)
	ctrl.bind(P)

	# 客户端侧副本:每具对手一个 PlayerReplica(带幽灵体)
	for i in range(n - 1):
		var r: Node2D = (preload("res://scenes/player/player_replica.tscn") as PackedScene).instantiate()
		_host.add_child(r)
		var g := r.get_node_or_null("GhostBody") as StaticBody2D
		if g == null:
			_fail("副本没有 GhostBody 节点(player_replica._build_ghost_body 没跑或被改名)")
			return
		if variant == Variant.NONE:
			g.collision_layer = 0
		_replicas.append(r)
		_ghosts.append(g)

	# ★ LATEST 两个变体:关掉副本自己的 _process(它会把副本插值回落后位置),
	#   改由本探针每 tick 把副本**整体**摆到「最新已收快照」的位置 → 幽灵体也在那里。
	#   视觉是否插值与物理无关:回滚只取决于幽灵体在哪。
	if variant != Variant.NONE:
		# 一律显式写位置:副本的 _process 插值时钟在探针里不可控(实测同配置两次跑出 98/240),
		# 而回滚只取决于幽灵体在哪,与副本视觉无关。
		for r in _replicas:
			(r as Node).set_process(false)

	await get_tree().process_frame
	await get_tree().physics_frame

	_running = true
	await _pass_finished

	var secs := float(RUN) / 60.0
	var contact_secs := maxf(float(_contact_ticks) / 60.0, 1.0 / 60.0)
	var rb := ctrl.rollback_count()
	var line := "N=%d %-18s 回滚×%-6d %6.1f 次/秒 | 修正 中位%5.1f p95%6.1f | 接触期偏差 中位%5.1f p95%6.1f px" % [
			n, VARIANT_NAME[variant], rb, float(rb) / secs,
			_pct(_rb_devs, 0.50), _pct(_rb_devs, 0.95),
			_pct(_devs, 0.50), _pct(_devs, 0.95)]
	_rows.append({"n": n, "variant": variant, "rb": rb, "med": _pct(_rb_devs, 0.50), "text": line})
	print("[brawl] %s" % line)

	# 负向对照必须爆炸,否则说明这探针量不到东西(空转断言)
	if variant == Variant.NONE:
		_check(rb > 0 and _max_dev > 1.0,
				"N=%d 摘掉幽灵体的对照确实产生分歧与回滚(rb=%d, 分歧=%.2fpx)" % [n, rb, _max_dev])

	# 每个正式变体都必须在同一量级上跑完,否则读数不可比
	if variant != Variant.NONE:
		_check(_contact_ticks > RUN / 10,
				"N=%d %s 确实处于贴身状态(接触占比 %.0f%%)" % [
						n, VARIANT_NAME[variant], 100.0 * float(_contact_ticks) / float(RUN)])

	for o in _opps:
		(o as Node).queue_free()
	A.queue_free()
	P.queue_free()
	for r in _replicas:
		(r as Node).queue_free()
	await get_tree().process_frame

	_ran[_pass_key(variant, n)] = true   # ★ 完成戳必须在最后一行(见顶部说明)


func _physics_process(_delta: float) -> void:
	if not _running:
		return
	if _tick >= RUN:
		_running = false
		_pass_finished.emit()
		return

	var t := _tick
	# 1) 权威侧:喂输入 + 手动步进(父类不跑,全手动 → 确定性)
	var recA := _packet(t, _input_a(t), t + 1)
	srcA.clear_edges()
	srcA.apply_packet(recA)
	A._physics_process(DT)
	_a_hist.append(A.capture_state())

	for i in range(_opps.size()):
		var rec := _packet(t, _input_opp(t, i), t + 1)
		var s: NetworkInputSource = _opp_srcs[i]
		s.clear_edges()
		s.apply_packet(rec)
		var o = _opps[i]
		o._physics_process(DT)
		(_opp_hist[i] as Array).append(o.capture_state())

	# 2) 到期投递:A 的权威整态 → 控制器(ack 是 t-DELAY+1)
	var ack_t := t - DELAY
	if ack_t >= 0:
		ctrl.on_authoritative(ack_t + 1, _a_hist[ack_t])

	# 3) 到期投递:每个对手的整态 → 各自副本(同一延迟)
	if ack_t >= 0:
		for i in range(_replicas.size()):
			var st: Dictionary = (_opp_hist[i] as Array)[ack_t]
			var gp: Vector2 = st["pos"]
			if _variant == Variant.EXTRAP:
				# 外推:用**那一帧快照里带的对手速度**,把它推到"现在应该在"的位置。
				# 速度是 DELAY tick 前的速度 —— 对手急停/变向时会过冲,这是本方案固有的代价。
				gp = gp + (st["vel"] as Vector2) * (float(DELAY) * DT)
			gp = MazeGenerator.anchor_to_nearest(
					gp, P.global_position, GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
			(_replicas[i] as Node2D).global_position = gp

	# 4) 预测侧步进。★ 回滚**次数**不等于**看得见**:次数高但每次只修 2px 就无所谓,修 50px 就会瞬移。
	#    故在 advance 前后夹一次:本 tick 发生了回滚就记下**当时的预测-权威分歧**(= 本次修正量)。
	var rb_before := ctrl.rollback_count()
	var dev_before := MazeGenerator.toroidal_delta_px(
			A.global_position, P.global_position, GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()
	ctrl.advance(recA)
	if ctrl.rollback_count() > rb_before:
		_rb_devs.append(dev_before)

	# 5) 读数:最大分歧 + 接触判定
	# 接触按**权威侧**判(A 与任一对手真身的中心距 < 玩家宽):那才是「两人真的在贴身推挤」
	# 的地面真值。按幽灵体判会把「幽灵体还没落到包上」也算成不接触,量到的是客户端视角,不是场景本身。
	# ★ 分歧必须走**环面最短向量**量:裸坐标相减在跨接缝那一帧会给出「一整幅地图宽」的假分歧。
	#   (顺带发现:`PredictionRollback._close_enough` 比 pos 用的正是裸 `distance_to` —— 见探针末尾的
	#    源码守卫断言与设计的「附带发现」。)
	var dev := MazeGenerator.toroidal_delta_px(A.global_position, P.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()
	_max_dev = maxf(_max_dev, dev)
	var touching := false
	for o in _opps:
		if absf((o as Node2D).global_position.x - A.global_position.x) < 90.0:
			touching = true
			break
	if touching:
		_contact_ticks += 1
		_devs.append(dev)

	if TRACE and t % 60 == 0:
		var g0: Node2D = _ghosts[0] if not _ghosts.is_empty() else null
		print("[trace] t=%3d A.x=%7.1f P.x=%7.1f O0.x=%7.1f ghost0.x=%7.1f 分歧=%6.1f rb=%d 接触=%s" % [
				t, A.global_position.x, P.global_position.x,
				(_opps[0] as Node2D).global_position.x if not _opps.is_empty() else -1.0,
				g0.global_position.x if g0 != null else -1.0,
				dev, ctrl.rollback_count(), "是" if touching else "否"])

	_tick += 1


# ── 输入脚本:制造**持续**贴身 + 不断变化的相对速度 ──
# ★ 踩过的坑(第一版):给 A 和对手用同周期反相,结果双方**同向跑**——A 朝右推时对手也朝右撤,
#   双方 92% 的时间在互相远离,整趟只贴上 ~29 tick,读数全是开局瞬态。判据是"接触占比",
#   它当场把这个问题报出来了(见 _check)。
# 现在:A 与每个对手都按 **120 tick 周期、96 tick 朝对方压 / 24 tick 撤**,但**相位逐对手错开**
# → 任何时刻都有人在压、有人在撤,包内相对速度持续变化(边界帧的来源),而 A 与最近那具
# 因为总有人朝它压过来,接触几乎不断。
func _input_a(t: int) -> float:
	return 1.0 if (t % 120) < 96 else -1.0


func _input_opp(t: int, i: int) -> float:
	if _variant == Variant.STATIC:
		return 0.0                       # 健全性对照:对手站着不动
	var ph := (t + i * 23) % 120
	return -1.0 if ph < 96 else 1.0     # 对手在 A 的右边:压过来 = 向左


func _packet(t: int, ax: float, seq: int) -> Dictionary:
	return {"seq": seq, "ax": ax, "held": 0, "pressed": 0, "released": 0,
			"weapon": 0, "aim": Vector2(1.0, 0.0)}


# ── 造物 ──
func _make_player(nm: String, pos: Vector2):
	var p = preload("res://scenes/player/Player.tscn").instantiate()
	p.name = nm
	_host.add_child(p)
	p.global_position = pos
	return p



func _build_grid() -> Array[Array]:
	var wall := 31
	var grid: Array[Array] = []
	for y in range(ROWS):
		var row: Array[int] = []
		for x in range(COLS):
			row.append(wall if y == ROWS - 1 else 0)
		grid.append(row)
	return grid


func _find_median(variant: int, n: int) -> float:
	for r in _rows:
		if int(r["variant"]) == variant and int(r["n"]) == n:
			return float(r["med"])
	return -1.0


func _find(variant: int, n: int) -> int:
	for r in _rows:
		if int(r["variant"]) == variant and int(r["n"]) == n:
			return int(r["rb"])
	return -1


# ── 收官:把读数整理成一张表,并给出「外推值多少」的跨变体对照 ──
func _summarize() -> void:
	print("")
	print("[brawl] ═══ 汇总(回滚 = PredictionRollback.rollback_count())═══")
	for r in _rows:
		print("[brawl] %s" % r["text"])
	print("[brawl] 说明:修正量的中位/p95 才是「看不看得见」的读数(碰撞箱 80px、瓦片 64px)。")
	# ★ EXTRAP 是**已实测证伪**的候选,不设通过判据 —— 留它在表里是为了让数字可复现,
	#   并防后人再把它当"显然的改进"加回来(实测:频率不降,N=8 反而涨 35%;修正量 p95
	#   13px → 65~77px,因为对手贴墙/急停时速度还在,外推把幽灵体推过头)。
	# ★ 真正值得守的是**幽灵体带来的那个性质**:它把修正量压在个位数 px。
	#   频率不随幽灵体准度变(摘除/准确/推歪 三档都是 ~220 次)—— 频度是"1px 容差 + 滞后对手"
	#   的固有属性,不是幽灵体没做好。所以这里守 magnitude,不守 count。
	for n in [2, 4, 8]:
		var prod := _find(Variant.PROD, n)
		if prod > 0:
			var med := _find_median(Variant.PROD, n)
			_check(med < 10.0, "N=%d 幽灵体把修正量中位压在 10px 内(实测 %.1f px)" % [n, med])


# 分位数(空数组返回 0)。修正量才是「看不看得见」的读数:32px 宽的身体,修正个位数 px 不可感。
func _pct(arr: Array[float], q: float) -> float:
	if arr.is_empty():
		return 0.0
	var a := arr.duplicate()
	a.sort()
	var i := clampi(int(floor(q * float(a.size() - 1))), 0, a.size() - 1)
	return a[i]


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("[brawl]   ✓ %s" % msg)
	else:
		_failures.append(msg)
		print("[brawl]   ✗ %s" % msg)


func _fail(msg: String) -> void:
	_failures.append(msg)
	print("[brawl]   ✗ %s" % msg)
