extends Node

# tests/probe/replica_smoothness_probe.gd —— 「对手看起来卡/掉帧」的诊断 + 常驻守卫。
#
# 症状(用户 2026-09-21 原话):「位置一跳一跳,看起来敌方掉帧」。
#
# 机制:若副本位置**直接跟随快照到达**(渲染的就是最新包原值),对手的平滑度就等于网络的
#   到达平滑度 —— 抖动下会出现"这一帧没包(零位移)/ 下一帧来两个(走两步)"。
#
# ★ 本探针只量**结果**(渲染位置每帧有没有动),不关心走的是哪套实现 ——
#   故改前改后都能跑,且不会随实现被删而失效。
#
# ★★ 为什么跑三档抖动而不是一档:零位移占比**只取决于到达抖动**,不取决于实现。
#   跑三档能把"灵敏度"一起打出来,而不是拿一个调出来的数当结论。
#   JITTER_MS = 0 是下界(规律到达,任何实现都平滑);越大越像跨网络。
#
# 跑法:"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/replica_smoothness_probe.tscn
# 判据:输出文本里的 `REPLICA SMOOTHNESS PROBE: ALL-OK`(不看退出码)。
#
# 相 A:三档到达抖动下的零位移占比 / 单帧最大位移
# 相 B:跨接缝不卡远副本(旧方案那条致命缺陷的守卫)

const REPLICA_SCENE := preload("res://scenes/player/player_replica.tscn")

const DT: float = 1.0 / 60.0            # 渲染帧(项目固定 60fps)
const FRAMES := 300                     # 每档帧数(5 秒)
const STEP_PX := 5.0                    # 每包前进的世界像素(60Hz × 5px = 300px/s,普通移速)
const NOMINAL_GAP_MS := 1000.0 / 60.0   # 名义到达间隔 16.667ms(服务器恒定 60Hz)
# 均匀抖动半径(ms)。到达间隔 = 名义间隔 + U(-J, +J) ⇒ 均值恒为 60Hz。
# 8.0 是 `6e2ef6d` 引用的那档(它记的旧法读数 49.6% 零位移)。
const JITTER_CASES := [0.0, 8.0, 16.0]
const ASSERT_CASE := 1                  # 断言压在 8.0ms 那一档
const RNG_SEED := 20260922              # 固定种子:三次跑同一组到达序列,读数可比

const STILL_EPS := 0.05                 # 位移小于此值 = 这一帧画面上没动
const STILL_RATIO_MAX := 0.10           # 零位移帧占比上限(旧法在 8ms 档实测 ≈ 0.5)
const MAX_STEP_PX := 8.0                # 单帧最大位移上限(理想 5.0;旧法偶发双步 ≈ 10.0)

const CANON_X := 1000.0                 # 相 A 采样点:开阔处,只由快照驱动,与地形/物理无关
const CANON_Y0 := 1000.0
const SEAM_NEAR_PX := 200.0             # 相 B:渲染位置到锚点的**未回绕** |Δx| 上限
# 相 C:幽灵体到"未经平滑的权威位置"的偏差上限。幽灵体吃的是原始值,故必须 ≈ 0;
# 2.0 只是给浮点与"同帧刚体移动要等下一个物理步"留的余量,不是容许它滞后。
const GHOST_ERR_MAX := 2.0

# ── 相 D:大跳变阈值的**两侧**行为(2026-10-09 加)──
# 阈值(`player_replica.SNAP_DIST`)是"超过就不追赶、直接落位"的分界。判据**两侧都要**,
# 否则那个常数等于没被钉住:
#   D1 阈值**以下** ⇒ 一帧**不许**贴平(必须还在追)—— 阈值调低到常态滞后量级时这里红;
#   D2 阈值**以上** ⇒ 一帧**必须**落位 —— 去掉直落分支(或阈值调高到够不着)时这里红。
# ★ 探针**不抄**那个常量的值(抄了就是第二份真相源),改用 `_script_const("SNAP_DIST")` 直读;
#   读不到就响亮 FAIL。两侧各留 `SNAP_MARGIN` 的余量。
const SNAP_MARGIN := 20.0
const EXPECTED_CHECKS := 7               # 相C×3 + 相A(1) + 相B(1) + 相D(2)

var _checks := 0

var _rep: Node2D = null
var _canon := Vector2(CANON_X, CANON_Y0)
var _tick := 0
var _case := 0
var _f := 0
var _prev := Vector2.ZERO
var _still := 0
var _max_step := 0.0
var _acc_ms := 0.0
var _gap := 0.0
var _rng := RandomNumberGenerator.new()
var _results: Array = []                # [{jitter, ratio, max_step}]
var _phase := "A"
var _seam_f := 0
var _anchor := Vector2(CANON_X, CANON_Y0)
# 相 C 的解耦守卫(每档抖动都采):幽灵体距"未经平滑的权威位置"的最大偏差。
# 它必须 ≈ 0 —— 幽灵体要的是**最小陈旧**,跟平滑后的渲染位置是错的(理由见 player_replica)。
var _ghost_err_max := 0.0
var _render_err_max := 0.0              # 对照读数:渲染位置距同一目标的偏差(平滑 = 这个有值)


func _ready() -> void:
	_rng.seed = RNG_SEED
	print("[replica_smoothness] 渲染帧 %.2f ms | 名义到达 %.2f ms | 抖动档 %s | 每档 %d 帧 | 种子 %d"
			% [DT * 1000.0, NOMINAL_GAP_MS, str(JITTER_CASES), FRAMES, RNG_SEED])
	_start_case()


func _begin_case(jitter_ms: float) -> void:
	if _rep != null and is_instance_valid(_rep):
		_rep.queue_free()      # 它已 set_process(false),本探针不再驱动它
	_rep = REPLICA_SCENE.instantiate()
	# ★ 空载守卫(与 squash_replica_probe 同款):`player_replica.gd` 一旦解析不过,
	#   tscn 的根会退化成裸 Node2D —— 场景照样加载、一行判据都不打印、退出码还是 0,
	#   那正是 docs/eng/tests.md 记的"看着像功能坏了"的形态。这里把它变成一条响亮的 FAIL。
	if not _rep.has_method("apply_snapshot"):
		_fail("PlayerReplica 脚本没加载起来(解析错?根节点是 %s)" % _rep.get_class())
		return
	add_child(_rep)
	_canon = Vector2(CANON_X, CANON_Y0)
	_rep.global_position = _canon
	# 逐帧显式调 `_process(DT)`,不交给引擎(与 squash_replica_probe 同款)
	_rep.set_process(false)
	_anchor = _canon
	_rep.apply_snapshot(_snapshot_dict(_canon), _anchor, _tick)
	_tick += 1
	_prev = _rep.global_position
	_f = 0
	_still = 0
	_max_step = 0.0
	_acc_ms = 0.0
	_ghost_err_max = 0.0
	_render_err_max = 0.0
	_gap = _next_gap(jitter_ms)


func _start_case() -> void:
	_begin_case(float(JITTER_CASES[_case]))


# 下一次到达的间隔(ms):名义值 + U(-J, +J),均值恒为名义值 ⇒ 平均仍是 60Hz。
func _next_gap(jitter_ms: float) -> float:
	if jitter_ms <= 0.0:
		return NOMINAL_GAP_MS
	return NOMINAL_GAP_MS + _rng.randf_range(-jitter_ms, jitter_ms)


# 键与 server/match_snapshot.gd 的 world["players"][role] 逐字一致(内容取中性可过值)。
func _snapshot_dict(pos: Vector2) -> Dictionary:
	return {
		"pos": pos,
		"vel": Vector2.ZERO,
		"facing": 1,
		"pose": 1,
		"type_id": 0,
		"hp": 100,
		"waterproof": 100.0,
		"downed": false,
		"aim": Vector2(1.0, 0.0),
		"previewing": false,
	}


func _physics_process(_delta: float) -> void:
	if _rep == null or not is_instance_valid(_rep):
		return
	if _phase == "A":
		_phase_a()
	elif _phase == "B":
		_phase_b()
	# "D" 由 `_phase_b` 的收尾**同步**驱动(不逐帧推进),这里故意什么都不做。


func _phase_a() -> void:
	var jitter_ms := float(JITTER_CASES[_case])
	# 到达:按抖动计时(长间隔会跨帧,故用 while 补足)
	_acc_ms += DT * 1000.0
	while _acc_ms >= _gap:
		_acc_ms -= _gap
		_canon.y += STEP_PX
		_rep.apply_snapshot(_snapshot_dict(_canon), _anchor, _tick)
		_tick += 1
		_gap = _next_gap(jitter_ms)
	_rep._process(DT)
	var p: Vector2 = _rep.global_position
	var d := p.distance_to(_prev)
	if d < STILL_EPS:
		_still += 1
	_max_step = maxf(_max_step, d)
	_prev = p
	# 相 C 采样:同一帧里比较"幽灵体"与"渲染位置"各自距**未经平滑的权威位置**多远。
	var tgt := MazeGenerator.anchor_to_nearest(_canon, _anchor,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	var ghost := _rep.get_node_or_null("GhostBody") as Node2D
	if ghost != null:
		_ghost_err_max = maxf(_ghost_err_max, ghost.global_position.distance_to(tgt))
	_render_err_max = maxf(_render_err_max, p.distance_to(tgt))
	_f += 1
	if _f < FRAMES:
		return
	var ratio := float(_still) / float(_f)
	_results.append({"jitter": jitter_ms, "ratio": ratio, "max_step": _max_step})
	print("[replica_smoothness] 相A 抖动 ±%.1f ms:零位移帧 %d/%d = %.4f;单帧最大位移 %.3f px(理想 %.1f)"
			% [jitter_ms, _still, _f, ratio, _max_step, STEP_PX])
	print("[replica_smoothness] 相C 抖动 ±%.1f ms:幽灵体距权威位置最大 %.3f px(上限 %.1f);渲染位置距同一目标最大 %.1f px(平滑滞后)"
			% [jitter_ms, _ghost_err_max, GHOST_ERR_MAX, _render_err_max])
	if _ghost_err_max > GHOST_ERR_MAX:
		_fail("相C 幽灵体没有跟上未经平滑的权威位置(偏差 %.3f px,上限 %.1f)—— 它会变成一条低通滤波后的、更陈旧的碰撞代理"
				% [_ghost_err_max, GHOST_ERR_MAX])
		return
	_checks += 1
	_case += 1
	if _case < JITTER_CASES.size():
		_start_case()
		return
	_finish_a()


func _finish_a() -> void:
	var r: Dictionary = _results[ASSERT_CASE]
	if float(r["ratio"]) > STILL_RATIO_MAX or float(r["max_step"]) > MAX_STEP_PX:
		_fail("相A 抖动 ±%.0f ms 下零位移占比 %.4f / 最大位移 %.3f px(对手会看起来一跳一跳)"
				% [float(r["jitter"]), float(r["ratio"]), float(r["max_step"])])
		return
	_checks += 1
	# 进相 B —— 复现旧方案那条**致命缺陷**:把副本**强行摆到一个"远副本"**上(与锚点相隔
	# 整幅地图宽、但环面坐标相同),再看它能不能自己回到锚点所在的那一份。
	# ★ 为什么必须"强行摆"而不是"把锚点放到地图另一头":环面距离是**对称**的 —— 锚到最近副本
	#   与留在原地量出来**相同**,那种写法两边都会通过,是条空断言。缺陷只在"渲染位置与目标
	#   相隔整幅地图"时现形。
	var w := float(GameParameters.MAP_WIDTH)
	_begin_case(0.0)
	_rep.apply_snapshot(_snapshot_dict(_canon), _anchor, _tick)
	_tick += 1
	_rep.global_position = Vector2(CANON_X + w, CANON_Y0)   # 环面同一格,但差了整整一幅地图
	print("[replica_smoothness] 相B 远副本:把渲染位置摆到 %.1f(锚点 %.1f,地图宽 %.1f)"
			% [CANON_X + w, CANON_X, w])
	_phase = "B"


func _phase_b() -> void:
	# 锚点与 canonical 恒定,喂 10 帧看它是否自己回来
	_rep.apply_snapshot(_snapshot_dict(_canon), _anchor, _tick)
	_rep._process(DT)
	_seam_f += 1
	if _seam_f < 10:
		return
	# 判据用**未回绕**的绝对坐标:正确实现下渲染位置必须落回锚点那一份(CANON_X 附近);
	# 若"卡在远副本"它会是 CANON_X + w,差整整一幅地图。这里刻意**不做环面包裹**。
	var dx := absf(_rep.global_position.x - CANON_X)
	var tor := GridPathfinder.toroidal_delta_px(_canon, _rep.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()
	print("[replica_smoothness] 相B 渲染位置.x=%.1f 距锚点(未回绕)=%.1f px;环面距离=%.1f px(上限 %.1f)"
			% [_rep.global_position.x, dx, tor, SEAM_NEAR_PX])
	if dx > SEAM_NEAR_PX:
		_fail("相B 副本卡在远副本(|Δx| = %.1f px,地图宽 %.1f)—— 对手会被渲染到屏幕外「看不见」"
				% [dx, float(GameParameters.MAP_WIDTH)])
		return
	_checks += 1
	_phase = "D"
	_phase_d()


# ── 相 D:大跳变阈值(两侧)──
func _script_const(name: String) -> float:
	var m: Dictionary = (_rep.get_script() as GDScript).get_script_constant_map()
	return float(m.get(name, 0.0))


func _phase_d() -> void:
	_begin_case(0.0)
	_rep._process(DT)          # 先走一帧让 `_placed` 置位(否则第一帧无条件直落,量不出阈值)
	var snap_d := _script_const("SNAP_DIST")
	if snap_d <= 0.0:
		_fail("player_replica.gd 里读不到 `SNAP_DIST` 常量 —— 阈值判据无处可依")
		return

	# D1:误差 = 阈值 − 余量 ⇒ 一帧之后**必须还在追**(指数追赶一帧只走 1−e^(−k·dt) ≈ 18%)
	var near_d := snap_d - SNAP_MARGIN
	_rep.global_position = Vector2(CANON_X, CANON_Y0)
	_canon = Vector2(CANON_X + near_d, CANON_Y0)
	_rep.apply_snapshot(_snapshot_dict(_canon), _anchor, _tick)
	_tick += 1
	_rep._process(DT)
	var lag := near_d - (_rep.global_position.x - CANON_X)
	_checks += 1
	if lag < near_d * 0.5:
		_fail("相D1 误差 %.1f px(阈值 %.1f **以下**)一帧就被贴平了(仍差 %.1f px)—— 阈值太低,常态抖动会被硬跳"
				% [near_d, snap_d, lag])
		return

	# D2:误差 = 阈值 + 余量 ⇒ **一帧必须落位**(回溯/重生是设计好的瞬移,不许演成弹射)
	var far_d := snap_d + SNAP_MARGIN
	_rep.global_position = Vector2(CANON_X, CANON_Y0)
	_canon = Vector2(CANON_X + far_d, CANON_Y0)
	_rep.apply_snapshot(_snapshot_dict(_canon), _anchor, _tick)
	_tick += 1
	_rep._process(DT)
	var rest := absf(_rep.global_position.x - (CANON_X + far_d))
	_checks += 1
	if rest > 0.01:
		var k := _script_const("INTERP_RATE")
		_fail("相D2 误差 %.1f px(阈值 %.1f **以上**)没有一帧落位(残留 %.1f px)—— 大跳变会被演成弹射:指数追赶在这个误差上首帧速度 ≈ %.0f px/s(%.0f 倍于 300px/s 的移速)"
				% [far_d, snap_d, rest, far_d * (1.0 - exp(-k * DT)) * 60.0,
						far_d * (1.0 - exp(-k * DT)) * 60.0 / 300.0])
		return
	print("[replica_smoothness] 相D 阈值 %.0f px:以下(%.0f)一帧后仍差 %.1f px(在追);以上(%.0f)一帧落位,残留 %.3f px"
			% [snap_d, near_d, lag, far_d, rest])
	if _checks != EXPECTED_CHECKS:
		_fail("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)—— 判词 ALL-OK 只等于「没有失败输出」"
				% [_checks, EXPECTED_CHECKS])
		return
	print("REPLICA SMOOTHNESS PROBE: ALL-OK")
	get_tree().quit(0)


func _fail(msg: String) -> void:
	print("REPLICA SMOOTHNESS PROBE: FAIL | " + msg)
	get_tree().quit(1)
