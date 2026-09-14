extends Node

# 幽灵碰撞体探针(场景模式:autoload 必须已实例化,不能用 -s 跑)。
# 跑法:
#   "$GODOT" --headless --path . res://tests/replica_ghost_probe.tscn
# 期望:每条 [ghost] … 通过,末行 "REPLICA GHOST PROBE: ALL-OK",退出码 0。
#
# 存在理由:玩家互相碰撞**服务器侧早就有**(server/match_host.gd 给每个玩家 mask |= 2),
# 缺的是客户端 —— 客户端世界里只有一具 PlayerReplica,而它此前是 `extends Node2D`、**零碰撞体**。
# 偏偏 C2 客户端预测**只步进自己的玩家**(PredictionRollback._step 只调 _p._physics_process),
# 于是「对手挡住我」这条信息在预测侧根本不存在:本地预测直接穿过去、服务器却把你挡住 →
# 每帧分歧、每帧 restore+重放、重放又没有障碍 → 下一帧接着分歧。**这是无限回滚循环,
# 不是调参能缓解的**(见 docs/superpowers/specs/2026-09-12-...-design.md §A3)。
#
# 本探针钉三件事:
#   ① 几何:本地玩家推进到副本处会被挡住,不穿过去;
#   ② C2 判据:权威被障碍挡住时,预测端只要也有等价的障碍,rollback_count() 就该停在 0
#      —— ① 只说明"有个东西挡着",② 才是"贴身回滚治好了"的证据;
#   ③ 源码守卫:两端客户端都给本地玩家设了 mask |= 2(幽灵体做好了但本地玩家不认它,
#      等于没做,而且不会有任何报错)。
#
# 反证(必须成立,否则本探针没有鉴别力):把幽灵体的 collision_layer 置 0(即摘掉它),
# ① 必须变成"穿过去了"、② 必须变成"分歧 + 回滚"。本探针把这一趟**当作正式断言跑**
# (负向对照组),不是靠人记得手动试。
#
# ⚠ 判据必须是 grep 文本 "REPLICA GHOST PROBE: ALL-OK",不能只看退出码:
#    探针中途脚本报错时可能仍以 exit 0 退出且不打印 ALL-OK(见 CLAUDE.md 测试段)。

const COLS := 48
const ROWS := 12
const TILE := 64
const DT := 1.0 / 60.0

const DELAY := 8        # 权威整态投递给控制器的延迟(tick);与 pvp_reconcile_smoke 同款
const RUN := 300        # 每趟的 tick 数(≈5s:够走到障碍前并持续顶住)
const REACH := 200.0    # 障碍/副本距出生点的 x 距离(玩家 700px/s,约 30 tick 走到)

# 备用层(层5 = 位值 16):只让权威 A 撞到。预测 P 的 mask 不含它。
# 为什么要备用层而不是直接复用"另一具玩家身体":真机上挡 A 的确实是另一具真 Player(层2),
# 但那样 P 也会被同一具挡住 → 摘掉幽灵体后 P 依然被挡 → 对照组失去鉴别力。
# 故给 A 一具**等几何的替身**(与幽灵体同抄 Player.tscn 的 stand 多边形、同坐标),
# 让两条链路的几何逐点一致,唯一变量就是「P 的世界里有没有这具身体」。
const LAYER_A_OBSTACLE := 16
const LAYER_PLAYER := 2        # 层2:玩家真实层,幽灵体也在这层

var _host: Node2D = null
var _spawn := Vector2.ZERO
var _results: Array[String] = []

# 单趟状态
var _running := false
var _ghost_on := true
var _tick := 0
var _max_dev := 0.0
var _max_px := -INF      # P 整趟走到过的最右位置(终帧位置受回滚相位影响,不作判据)
var _ghost_on_max_px := 0.0   # 正向那趟的读数,负向对照组直接拿它当参照
var A = null                                    # 权威(服务器侧模拟,手动步进)
var P = null                                    # 被预测(客户端侧模拟,控制器驱动)
var ctrl := PredictionRollback.new()
var srcA: NetworkInputSource = NetworkInputSource.new()
var _a_hist: Array[Dictionary] = []             # tick -> A 步进后整态(投递用)
var _replica: Node2D = null
var _ghost: StaticBody2D = null

signal _pass_finished


func _ready() -> void:
	GameParameters.MAP_WIDTH = COLS * TILE
	GameParameters.MAP_HEIGHT = ROWS * TILE
	MazeGenerator.current_grid = _build_grid()
	TileDefs.load_defs()
	_host = Node2D.new()
	add_child(_host)
	WorldBuilder.build_sim(_host, MazeGenerator.current_grid)
	# 站在地板上:脚底 ≈ 原点 + 80px(站姿碰撞多边形 ×2.5 缩放),地板顶边 = (ROWS-1)*TILE
	_spawn = Vector2(2 * TILE + TILE * 0.5, (ROWS - 1) * TILE - 80.0)
	print("[ghost] 世界 %d×%d 格,出生 %s,障碍在 x+%.0f" % [COLS, ROWS, str(_spawn), REACH])

	await _run_pass(true)    # 正向:幽灵体在位
	_require_ran("pass_on")
	await _run_pass(false)   # 负向对照:摘掉幽灵体
	_require_ran("pass_off")
	await _test_downed_ghost_rotation()
	_require_ran("downed")
	_check_source_guard()

	if _results.is_empty():
		print("REPLICA GHOST PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("REPLICA GHOST PROBE: FAIL")
		get_tree().quit(1)


# ── 单趟:搭一具权威 A + 一具预测 P + 一具"对手身体"(A 侧替身 / P 侧幽灵体)──
func _run_pass(ghost_on: bool) -> void:
	_ghost_on = ghost_on
	_tick = 0
	_max_dev = 0.0
	_max_px = -INF
	_a_hist = []
	ctrl = PredictionRollback.new()
	srcA = NetworkInputSource.new()
	var obstacle_x := _spawn.x + REACH

	# 权威 A:被备用层上的等几何替身挡住
	A = _make_player("AuthA", _spawn)
	A.collision_layer = 0            # A/P 互不碰撞(否则各自的层会让对方看见,对照就没了)
	A.collision_mask |= LAYER_A_OBSTACLE
	A.set_input_source(srcA)
	A.set_physics_process(false)
	# 预测 P:mask 补层2 —— 与客户端 pvp_client/royale_game 对本地玩家做的是同一件事
	P = _make_player("PredP", _spawn)
	P.collision_layer = 0
	P.collision_mask |= LAYER_PLAYER
	P.set_physics_process(false)
	ctrl.bind(P)

	_make_stand_in(LAYER_A_OBSTACLE, Vector2(obstacle_x, _spawn.y))
	# P 侧的"对手身体" = 真 PlayerReplica(带幽灵碰撞体),与 pvp_client 里的用法完全一致
	_replica = (preload("res://scenes/player/player_replica.tscn") as PackedScene).instantiate()
	_host.add_child(_replica)
	_replica.apply_snapshot({"pos": Vector2(obstacle_x, _spawn.y), "facing": -1,
			"aim": Vector2.LEFT, "weapon": 0, "previewing": false, "hp": 50, "pose": 0,
			"downed": false}, _spawn, 1)
	_ghost = _replica.get_node_or_null("GhostBody") as StaticBody2D
	if _ghost == null:
		_fail("副本没有 GhostBody 节点 —— player_replica._build_ghost_body 没跑或被改名")
		return
	if not ghost_on:
		_ghost.collision_layer = 0   # 反证:把幽灵体从碰撞世界摘掉

	# 让引擎跑一帧:副本的 _process 才会按 apply_snapshot 定位自己(GhostBody 是它的子节点,
	# 跟着一起落到 obstacle_x);同时把 deferred 队列清空。
	await get_tree().process_frame
	await get_tree().physics_frame

	_running = true
	await _pass_finished

	var tag := "幽灵体在位" if ghost_on else "幽灵体已摘除(负向对照)"
	var ax: float = A.global_position.x
	var px: float = P.global_position.x
	var dx := absf(ax - px)
	var rb := ctrl.rollback_count()
	print("[ghost] %s:A.x=%.2f P.x=%.2f(最远 %.2f) 障碍x=%.2f 回滚×%d 最大分歧=%.2f px" % [
			tag, ax, px, _max_px, obstacle_x, rb, _max_dev])

	if ghost_on:
		_ghost_on_max_px = _max_px
		# ① 用"整趟走到过的最远位置"而不是终帧位置:P 终帧位置受回滚相位影响,不是稳定读数
		_check(_max_px < obstacle_x, "① 幽灵体挡住了预测端玩家(最远只到 %.2f,未越过副本 %.2f)" % [
				_max_px, obstacle_x])
		_check(rb == 0 and dx < 0.5, "② 权威与预测轨迹一致、零回滚(rb=%d, Δx=%.3f)" % [rb, dx])
	else:
		# 负向对照:两条都必须反过来,否则说明①/② 是"无论有没有幽灵体都成立"的空转断言。
		# ③ 与**正向那趟的读数**比,不跟障碍坐标比 —— 回滚会把 P 反复拉回 A 的权威位置,
		#    终帧落在哪取决于回滚相位(实测同一场景两次跑出 383 / 356 两个终值)。
		_check(_max_px > _ghost_on_max_px + 20.0,
				"③ 摘掉幽灵体后不再被挡(最远 %.2f,幽灵体在位时只有 %.2f)" % [_max_px, _ghost_on_max_px])
		_check(rb > 0 and _max_dev > 1.0, "④ 摘掉幽灵体后出现分歧与回滚(rb=%d, 分歧=%.2f px)" % [
				rb, _max_dev])

	# 清场等下一趟(deferred 队列在 process_frame 后清空,WaterFx 那种 _ready 里 call_deferred
	# 的挂载不会砸在已释放节点上)
	A.queue_free()
	P.queue_free()
	_replica.queue_free()
	await get_tree().process_frame
	_ran[("pass_on" if ghost_on else "pass_off")] = true   # ★ 完成戳:必须在最后一行


func _physics_process(_delta: float) -> void:
	if not _running:
		return
	if _tick >= RUN:
		_running = false
		_pass_finished.emit()
		return
	var rec := _record(_tick)
	# 1) 权威步进(消费本输入)
	srcA.clear_edges()
	srcA.apply_packet(rec)
	A._physics_process(DT)
	_a_hist.append(A.capture_state())
	# 2) 到期投递整态 → 控制器(reconcile 在 advance 内先处理)
	var ack_t := _tick - DELAY
	if ack_t >= 0 and ack_t < _a_hist.size():
		ctrl.on_authoritative(ack_t + 1, _a_hist[ack_t])
	# 3) 预测步进(advance = reconcile + 换 scratch 喂同一输入 + 步 + 记 capture)
	ctrl.advance(rec)
	var pa := Vector2(A.global_position)
	var pp := Vector2(P.global_position)
	_max_dev = maxf(_max_dev, (pa - pp).length())
	_max_px = maxf(_max_px, pp.x)
	_tick += 1


# 全程按住"右":双方各自一路走到障碍前顶住。seq 从 1 起(on_authoritative 丢弃 ack <= _acked,
# 而 _acked 初值 0 → seq 从 0 起的话第一包 ack 会被吃掉)。
func _record(t: int) -> Dictionary:
	return {"seq": t + 1, "ax": 1.0, "held": 0, "pressed": 0, "released": 0,
			"weapon": 0, "aim": Vector2(1.0, 0.0)}


# ── 造物 ──
func _make_player(nm: String, pos: Vector2):
	var p = preload("res://scenes/player/Player.tscn").instantiate()
	p.name = nm
	_host.add_child(p)
	p.global_position = pos
	return p


# 等几何替身:多边形从 Player.tscn 的 stand 姿态现抄 —— 与 PlayerReplica 幽灵体的来源同一份,
# 故两侧碰撞箱逐点一致。
# ★ scale 也必须一起抄(Player.tscn 根节点是 2.5):节点缩放会作用到碰撞多边形上,
#   漏掉它替身就只有幽灵体的 1/2.5 大 —— A 会被挡在更靠右的位置,P 与 A 停不到同一点,
#   ② 那条"轨迹一致"就永远红(实测踩过:Δx=27px,A 比 P 多走了一段)。
func _make_stand_in(layer: int, pos: Vector2) -> StaticBody2D:
	var tmp := preload("res://scenes/player/Player.tscn").instantiate()
	var src := tmp.get_node_or_null("CollisionShape2D_stand") as CollisionPolygon2D
	var b := StaticBody2D.new()
	b.collision_layer = layer
	b.collision_mask = 0
	b.scale = (tmp as Node2D).scale
	var poly := CollisionPolygon2D.new()
	if src != null:
		poly.polygon = src.polygon
		poly.position = src.position
	b.add_child(poly)
	_host.add_child(b)
	b.global_position = pos
	tmp.free()
	return b


func _build_grid() -> Array[Array]:
	var wall := 31   # 纹理1 全砖(与 pvp_reconcile_smoke 同款)
	var grid: Array[Array] = []
	for y in range(ROWS):
		var row: Array[int] = []
		for x in range(COLS):
			row.append(wall if y == ROWS - 1 else 0)
		grid.append(row)
	return grid


# ── 源码守卫 ──
# 这条不是实现细节:幽灵体做好了但本地玩家 mask 不含层2,等于没做 —— 而且静默无报错。
# 若改法换了入口(例如搬进 player.gd 按 pvp_mode 设),请把这里的匹配改成新入口,**别删掉这条断言**。
func _check_source_guard() -> void:
	for f in ["res://scenes/pvp_client.gd", "res://scenes/royale_game.gd"]:
		var txt := FileAccess.get_file_as_string(f)
		var found := false
		for line in txt.split("\n"):
			if line.contains("collision_mask |= 2") and not line.strip_edges().begins_with("#"):
				found = true
				break
		_check(found, "③ %s 给本地玩家设了 collision_mask |= 2" % f)


# ★ 假绿防线(本仓被抓过四次的那一类):Godot 的运行时错误只**中断当前函数**,调用它的
#   `_ready()` 照常往下走 —— 测试函数中途报错 → 一条 _check 都没跑到 → _results 仍空
#   → 照样打印 ALL-OK。故每个测试函数在**最后一行**盖完成戳,`_ready` 逐条核。
var _ran: Dictionary = {}

func _require_ran(name: String) -> void:
	if not _ran.has(name):
		_fail("%s 没跑到最后一行(中途报错或被跳过)→ 本趟读数不可信" % name)


# 倒地时幽灵体**不得**跟着副本根节点转体:服务器侧 player.gd 的倒地分支不旋转(全文件零
# rotation),尸体停在最后姿态的箱子上。副本根节点转 -90°(视觉转体)会把子节点一起转 →
# 「倒地的对手还挡不挡路」两端不一致。大乱斗 2s 一复活,倒地是常态。
func _test_downed_ghost_rotation() -> void:
	var rep: Node2D = (preload("res://scenes/player/player_replica.tscn") as PackedScene).instantiate()
	_host.add_child(rep)
	await get_tree().process_frame
	rep.apply_snapshot({"pos": _spawn, "facing": 1, "aim": Vector2.RIGHT, "weapon": 0,
			"previewing": false, "hp": 0, "pose": 0, "downed": true}, _spawn, 1)
	await get_tree().process_frame
	var g := rep.get_node_or_null("GhostBody") as Node2D
	if g == null:
		_fail("副本没有 GhostBody 节点 —— player_replica._build_ghost_body 没跑或被改名")
		return
	var deg := rad_to_deg(absf(g.global_rotation))
	_check(deg < 1.0, "倒地时幽灵体不旋转(实测 %.1f°;>1° = 碰撞箱跟着副本转了)" % deg)
	rep.queue_free()
	await get_tree().process_frame
	_ran["downed"] = true   # ★ 完成戳必须在最后一行(见顶部说明)


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("[ghost]   ✓ %s" % msg)
	else:
		_results.append(msg)
		print("[ghost]   ✗ %s" % msg)


func _fail(msg: String) -> void:
	_results.append(msg)
	print("[ghost]   ✗ %s" % msg)
