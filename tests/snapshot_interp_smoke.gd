extends SceneTree

# SnapshotInterp 行为冒烟(纯算法:`extends SceneTree` → `-s` 可跑,不引 autoload)。
#
# ═══ 为什么需要它 ═══
# 这段插值原先**在 `player_replica` / `enemy_replica` 里各有一份**(逐字同款),从没有任何测试 ——
# 而它恰恰是 CLAUDE.md 专门记过教训的热点(旧实现用"自身差分追赶",渲染位置与目标相隔整幅地图时
# 最短向量=0,副本落到远副本就永远留在那儿 → 对手被渲染到屏幕外)。2026-09-14 收成
# `core/snapshot_interp.gd` 时把它做成不引 autoload,就是为了能在这里真跑它。
#
# ★ 最有价值的是第 ⑦ 条(跨接缝):写成朴素 `lerp(pa, pb, alpha)` 会得到地图**正中**而不是
#   最短路径上的点 —— 而那种写法在"快照不跨接缝"的日常场景下**看起来完全正常**,只在接缝处
#   把副本甩到对面去。这条是唯一能拦住它的断言。
#
# 跑法: "$GODOT" --headless --path . -s res://tests/snapshot_interp_smoke.gd
# 通过 = `SNAPSHOT_INTERP OK` 退出 0。

const W := 8000.0
const H := 4800.0
const HALF_TICK := 0.5 / SnapshotInterp.SNAPSHOT_HZ   # 把渲染时钟推进半个 tick

var _fail := 0


func _initialize() -> void:
	# ① 只有一个快照:不能插值(调用方要直落最新权威位置)
	var si := SnapshotInterp.new(8, W, H)
	si.push(10, Vector2(100, 0))
	_check(not si.ready(), "只有 1 个快照时 ready() 为 false")
	_check(si.tick_count() == 1, "1 个快照 → tick_count()==1")

	# ② 第二个快照到达 → ready;时钟被重置到「最新 - 1」= 较早那个 → 落在 pa 上
	si.push(11, Vector2(200, 0))
	_check(si.ready(), "2 个快照后 ready() 为 true")
	_close(si.sample(), Vector2(100, 0), "时钟初值落在「最新-1」(= 较早那个快照)")

	# ③ 推进半个 tick → 两个快照的中点(线性插值)
	si.advance(HALF_TICK)
	_close(si.sample(), Vector2(150, 0), "半 tick 处取到中点")

	# ④ 推进远远越过最新 → 冻结在**最新已收位置**(不外推、不回退)
	si.advance(10.0)
	_close(si.sample(), Vector2(200, 0), "越过最新后冻结在最新(不外推)")

	# ⑤ 乱序/重复 tick 丢弃,且**不移动**时钟(否则会倒退)
	var so := SnapshotInterp.new(8, W, H)
	so.push(5, Vector2(50, 0))
	so.push(3, Vector2(30, 0))
	so.push(5, Vector2(51, 0))
	_check(so.tick_count() == 1, "乱序/重复 tick 被丢弃(仍是 1 个)")
	_check(not so.ready(), "乱序 push 不该让缓冲就绪")
	so.push(6, Vector2(60, 0))
	_check(so.ready(), "补上递增 tick 后就绪")
	_close(so.sample(), Vector2(50, 0), "乱序 push 没把时钟搞乱(仍在「最新-1」= tick 5)")
	_close(so._pos_hist[5], Vector2(50, 0), "重复 tick 5 没有覆盖掉原值(仍是首次那条)")

	# ⑥ 窗口裁剪:保留「最新前 keep_ticks 个 tick」**外加最新本身** → 共 keep_ticks+1 条。
	#    (`drop_below = latest - keep_ticks`,所以含两端;写这条时我一开始按「N 条」断言,
	#     被本冒烟当场拦下 —— 这类 off-by-one 正是当初该有测试的原因。)
	var sw := SnapshotInterp.new(2, W, H)
	for t in [1, 2, 3, 4]:
		sw.push(t, Vector2(t * 10, 0))
	_check(sw.tick_count() == 3, "keep_ticks=2:push 1..4 后留 tick 2/3/4 三条(实际 %d)" % sw.tick_count())
	_check(not sw._pos_hist.has(1), "最老的 tick 1 已被裁掉")
	_check(sw._pos_hist.has(2) and sw._pos_hist.has(4), "窗口两端(tick 2 与 4)都还在")

	# ⑦ ★ 跨接缝:两个快照分处地图两端,中点必须走**最短向量**(朴素 lerp 会落在正中 (4000,0))
	var sx := SnapshotInterp.new(8, W, H)
	sx.push(1, Vector2(7900, 0))
	sx.push(2, Vector2(100, 0))
	sx.advance(HALF_TICK)
	var mid := sx.sample()
	_close(mid, Vector2(0, 0), "★ 跨接缝中点走最短向量(7900 →100 经 8000/0,落点 0)")
	_check(mid.distance_to(Vector2(4000, 0)) > 1000.0,
			"★ 且**不是**朴素 lerp 的地图正中(那是跨接缝把副本甩到对面的写法)")

	# ⑧ 纵向同理(避免只处理了 x 轴)
	var sy := SnapshotInterp.new(8, W, H)
	sy.push(1, Vector2(0, 4700))
	sy.push(2, Vector2(0, 100))
	sy.advance(HALF_TICK)
	_close(sy.sample(), Vector2(0, 0), "跨上下接缝同样走最短向量")

	if _fail == 0:
		print("SNAPSHOT_INTERP OK")
		quit(0)
	else:
		print("SNAPSHOT_INTERP FAIL(%d 条)" % _fail)
		quit(1)


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  ok  " + what)
	else:
		_fail += 1
		print("  FAIL " + what)


# 用容差比较:advance() 的 delta 除以 SNAPSHOT_HZ 再乘回来会有浮点误差(0.5 未必精确回得来),
# 精确相等会把正确的实现判红。
func _close(got: Vector2, want: Vector2, what: String) -> void:
	_check(got.distance_to(want) < 0.01, "%s(got %s,want %s)" % [what, str(got), str(want)])
