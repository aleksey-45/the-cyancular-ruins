extends SceneTree
# SquashStretch 纯逻辑冒烟(不建场景、不渲染)。
# 判据:SQUASH SMOKE: ALL-OK
# 跑法:"$GODOT" --headless --path . -s res://tests/squash_stretch_smoke.gd
#
# ★ 组件只静态引用 PlayerParams / EnemyParams / MathUtil(三者都是 RefCounted、非 autoload),
#   故 `-s` 阶段(autoload 尚未实例化)可以安全静态引用本类。

const DT: float = 1.0 / 60.0

var _fail: int = 0


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		_fail += 1
		print("  FAIL ", msg)


func _near(a: float, b: float, eps: float) -> bool:
	return absf(a - b) <= eps


func _mk() -> Array:
	# 返回 [组件, 精灵]。精灵不入树 —— scale 是 Node2D 属性,不入树也能读写。
	var spr := AnimatedSprite2D.new()
	var s := SquashStretch.new()
	s.setup(spr, SquashStretch.Profile.PLAYER)
	return [s, spr]


func _initialize() -> void:
	print("== SquashStretch 纯逻辑冒烟 ==")

	# ① 静止:(vel_y=0, on_floor) 多帧后必须是单位缩放
	var a: Array = _mk()
	for i in 30:
		(a[0] as SquashStretch).tick(DT, 0.0, true, false)
	_ok(_near((a[1] as AnimatedSprite2D).scale.x, 1.0, 0.001)
			and _near((a[1] as AnimatedSprite2D).scale.y, 1.0, 0.001),
			"静止 → scale == (1,1),实测 %s" % str((a[1] as AnimatedSprite2D).scale))

	# ② 落地冲击 → 挤压(宽矮:x>1, y<1)
	var b: Array = _mk()
	(b[0] as SquashStretch).tick(DT, 1200.0, true, false)
	var bs: Vector2 = (b[1] as AnimatedSprite2D).scale
	_ok(bs.x > 1.0 and bs.y < 1.0, "落地冲击 → 挤压方向(宽矮),实测 %s" % str(bs))
	# 且不得越过 amount 上限
	_ok(absf(bs.x - 1.0) <= PlayerParams.squash_amount + 0.0001,
			"落地挤压不越上限(%.3f)" % PlayerParams.squash_amount)

	# ③ 低落速不触发:100 < squash_land_min_vy(220)
	var c: Array = _mk()
	(c[0] as SquashStretch).tick(DT, 100.0, true, false)
	_ok(_near((c[1] as AnimatedSprite2D).scale.x, 1.0, 0.0005),
			"落速 100(< 下限 220)不触发挤压,实测 %s" % str((c[1] as AnimatedSprite2D).scale))

	# ④ 起跳冲击 → 拉伸(窄高:x<1, y>1)
	var d: Array = _mk()
	(d[0] as SquashStretch).impulse(SquashStretch.Impulse.JUMP)
	(d[0] as SquashStretch).tick(DT, 0.0, true, false)
	var ds: Vector2 = (d[1] as AnimatedSprite2D).scale
	_ok(ds.x < 1.0 and ds.y > 1.0, "起跳冲击 → 拉伸方向(窄高),实测 %s" % str(ds))

	# ⑤ 空中连续项:在空中且 |vel_y| 大 → 拉伸(窄高:x<1)
	var e: Array = _mk()
	(e[0] as SquashStretch).tick(DT, -700.0, false, false)
	_ok((e[1] as AnimatedSprite2D).scale.x < 1.0,
			"空中(vel_y=-700)→ 拉伸(窄高),实测 %s" % str((e[1] as AnimatedSprite2D).scale))

	# ⑥ 指数回归:30 帧后 < 0.01,60 帧后 < 0.001
	#    按 squash_recover=9.0 + squash_amount=0.10 推:exp(-4.5)*0.10≈0.0011、exp(-9)*0.10≈1.2e-5
	var f: Array = _mk()
	(f[0] as SquashStretch).tick(DT, 1200.0, true, false)   # 先制造一个大冲击
	for i in 30:
		(f[0] as SquashStretch).tick(DT, 0.0, true, false)
	_ok(absf((f[1] as AnimatedSprite2D).scale.x - 1.0) < 0.01,
			"30 帧后回归到 <0.01,实测 %.5f" % absf((f[1] as AnimatedSprite2D).scale.x - 1.0))
	for i in 30:
		(f[0] as SquashStretch).tick(DT, 0.0, true, false)
	_ok(absf((f[1] as AnimatedSprite2D).scale.x - 1.0) < 0.001,
			"60 帧后回归到 <0.001,实测 %.6f" % absf((f[1] as AnimatedSprite2D).scale.x - 1.0))

	# ⑦ 多事件叠加不爆:同时起跳 + 冲刺,再叠空中项 —— 三条正项叠加必须被**钳在 +1.0 上限**
	#    ★ 这里刻意**不走满力落地那一拍**(on_floor=false):落地项是 `-1.0`,会把饱和的
	#    `+1.0` 原样抵消 → v 落到 0,断言就退化成"读一个 0",删掉组件里两处 clampf 也照样绿。
	#    改成"停在钳位处"之后,删 clampf 才会真红(下面两条互补)。
	var g: Array = _mk()
	(g[0] as SquashStretch).impulse(SquashStretch.Impulse.JUMP)   # +0.75
	(g[0] as SquashStretch).impulse(SquashStretch.Impulse.DASH)   # +0.80 → 饱和到 +1.0
	(g[0] as SquashStretch).tick(DT, -700.0, false, false)        # 空中项再叠 +0.30:未钳位时 v≈1.16
	var gs: Vector2 = (g[1] as AnimatedSprite2D).scale
	_ok(absf(gs.x - 1.0) <= PlayerParams.squash_amount + 0.0001
			and absf(gs.y - 1.0) <= PlayerParams.squash_amount + 0.0001,
			"多事件叠加不越上限,实测 %s" % str(gs))
	# 且必须是"顶在上限上"而不是"被抵消回中性" —— 上一条若退化回抵消,这里立刻红
	# (v=+1.0 是**拉伸** ⇒ x 顶在 1.0 - amount)
	_ok(_near(gs.x, 1.0 - PlayerParams.squash_amount, 0.001),
			"叠加确实停在钳位处(v=+1.0,窄高),实测 %.4f" % gs.x)

	# ⑦b 饱和的**语义**守卫:同一组事件叠两次,结果必须与叠一次完全相同
	#     (impulse() 的钳位让第二组落在同一个饱和点)。只删 impulse() 里那个 clampf 时,
	#     两组各自累积到 1.55 / 3.10,再被同一次落地冲击减掉同一个值 → 两者分叉 = 红。
	var g1: Array = _mk()
	(g1[0] as SquashStretch).impulse(SquashStretch.Impulse.JUMP)
	(g1[0] as SquashStretch).impulse(SquashStretch.Impulse.DASH)
	(g1[0] as SquashStretch).tick(DT, 2000.0, true, false)
	var g2: Array = _mk()
	for i in 2:
		(g2[0] as SquashStretch).impulse(SquashStretch.Impulse.JUMP)
		(g2[0] as SquashStretch).impulse(SquashStretch.Impulse.DASH)
	(g2[0] as SquashStretch).tick(DT, 2000.0, true, false)
	var s1: Vector2 = (g1[1] as AnimatedSprite2D).scale
	var s2: Vector2 = (g2[1] as AnimatedSprite2D).scale
	_ok(_near(s1.x, s2.x, 0.0005),
			"叠加饱和:叠两次与叠一次同值,实测 %s" % (str(s1) + " vs " + str(s2)))

	# ⑧ suppressed → 立刻中性(倒地)
	var h: Array = _mk()
	(h[0] as SquashStretch).tick(DT, 1200.0, true, false)   # 先挤压
	(h[0] as SquashStretch).tick(DT, 1200.0, true, true)    # 再抑制
	_ok(_near((h[1] as AnimatedSprite2D).scale.x, 1.0, 0.0005)
			and _near((h[1] as AnimatedSprite2D).scale.y, 1.0, 0.0005),
			"suppressed → 立刻回中性,实测 %s" % str((h[1] as AnimatedSprite2D).scale))

	# ⑨ 敌人 profile 不得认玩家的 Impulse(增益表里没有 → no-op)
	var espr := AnimatedSprite2D.new()
	var es := SquashStretch.new()
	es.setup(espr, SquashStretch.Profile.ENEMY)
	es.impulse(SquashStretch.Impulse.JUMP)     # 敌人侧没有 JUMP
	es.tick(DT, 0.0, true, false)
	_ok(_near(espr.scale.x, 1.0, 0.0005),
			"敌人 profile 对 JUMP 无响应,实测 %s" % str(espr.scale))
	es.impulse(SquashStretch.Impulse.TAKE_OFF)  # 敌人侧有 TAKE_OFF
	es.tick(DT, 0.0, true, false)
	_ok(espr.scale.x < 1.0, "敌人 profile 响应 TAKE_OFF(拉伸,窄高),实测 %s" % str(espr.scale))

	if _fail == 0:
		print("SQUASH SMOKE: ALL-OK")
	else:
		print("SQUASH SMOKE: FAIL | %d 条" % _fail)
	quit(1 if _fail > 0 else 0)
