extends SceneTree
# SquashStretch 纯逻辑冒烟(不建场景、不渲染)。
# 判据:SQUASH SMOKE: ALL-OK
# 跑法:"$GODOT" --headless --path . -s res://tests/smoke/squash_stretch_smoke.gd
#
# ★ 组件只静态引用 PlayerParams / EnemyParams / MathUtil(三者都是 RefCounted、非 autoload),
#   故 `-s` 阶段(autoload 尚未实例化)可以安全静态引用本类。

const DT: float = 1.0 / 60.0

# 两侧**刻意重复**的同名 squash_* 常量(见 player_params.gd / enemy_params.gd 的互相指引注释)。
# 同名同值是约定,不是巧合 —— 漂移会让"同一套手感"在两个宿主上分叉,而四处测试的阈值
# **全是相对 `squash_amount` 表达的**,抬一侧的值不会让任何一条变红。
const MIRRORED_CONSTS := [
	"squash_amount", "squash_recover", "squash_land_min_vy", "squash_land_ref_vy",
	"squash_land", "squash_hurt", "squash_air", "squash_air_ref_vy",
]
# 用户裁定的幅度上限。**写死**是刻意的:这里是唯一钉住"这个数本身"的地方。
# ★ 2026-09-21 用户实测后从 0.10 收到 0.06(原话「玩家有点太果冻了」)—— 同批把
#   `squash_recover` 9→16、`squash_air` 0.30→0.10(三项一起收,事件强度不动)。
#   两侧参数文件必须同改:本文件上方逐名钉死这 8 个同名常量。
const RULED_AMOUNT := 0.06

var _fail: int = 0
# 本冒烟建的所有节点(`_mk()` 与 ⑨ 的手搭实例)。不入树 ⇒ 不 free 就是 ObjectDB 泄漏,
# 退出时刷一屏 `leaked` 警告把真正的失败淹掉(另两个场景探针都 free 了,这里对齐)。
var _owned: Array[Node] = []


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
	# 两者都记进 `_owned`,退出前统一 free(见该字段的注释)。
	var spr := AnimatedSprite2D.new()
	var s := SquashStretch.new()
	s.setup(spr, SquashStretch.Profile.PLAYER)
	_owned.append(s)
	_owned.append(spr)
	return [s, spr]


func _free_owned() -> void:
	for n in _owned:
		if is_instance_valid(n):
			n.free()
	_owned.clear()


func _initialize() -> void:
	print("== SquashStretch 纯逻辑冒烟 ==")

	# ⓪ 参数镜像:两侧那 8 个同名 `squash_*` 常量必须同值 + 幅度必须还是用户裁定的那个数。
	#    ★ 为什么必须有:四处测试的阈值**全部**相对 `PlayerParams.squash_amount` 表达,
	#    把 0.10 抬到 0.20(单侧或双侧)**一条都不会红** —— 而"不要太夸张"是用户裁定。
	#    ★ 用 `get_script_constant_map()` 而不是直接取属性:后者在名字被改名时会抛错,
	#    而改名恰恰是这条守卫最该产出"响亮的红"的场景(取不到 = 少一个常量,必须报出来)。
	var pp_script = load("res://core/config/player_params.gd")
	var ep_script = load("res://core/config/enemy_params.gd")
	if pp_script == null or ep_script == null:
		print("SQUASH SMOKE: FAIL | 参数脚本加载失败(player_params / enemy_params)")
		quit(1)
		return
	var p_map: Dictionary = pp_script.get_script_constant_map()
	var e_map: Dictionary = ep_script.get_script_constant_map()
	if not e_map.has("shared"):
		print("SQUASH SMOKE: FAIL | EnemyParams 里找不到嵌套类 `shared`(守卫已失明,拒绝静默跳过)")
		quit(1)
		return
	var es_map: Dictionary = (e_map["shared"] as GDScript).get_script_constant_map()

	for cname in MIRRORED_CONSTS:
		var in_p := p_map.has(cname)
		var in_e := es_map.has(cname)
		_ok(in_p and in_e and is_equal_approx(p_map[cname], es_map[cname]),
				"参数镜像 %s:PlayerParams %s / EnemyParams.shared %s" % [
					cname,
					("%.4f" % p_map[cname]) if in_p else "<缺>",
					("%.4f" % es_map[cname]) if in_e else "<缺>"])
	_ok(is_equal_approx(p_map.get("squash_amount", -1.0), RULED_AMOUNT)
			and is_equal_approx(es_map.get("squash_amount", -1.0), RULED_AMOUNT),
			"幅度 == 用户裁定值 %.2f(两侧实测 %s / %s)" % [
				RULED_AMOUNT, str(p_map.get("squash_amount")), str(es_map.get("squash_amount"))])

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
	#    按 squash_recover=16.0 + squash_amount=0.06 推(2026-09-21 更新):
	#    exp(-8)*0.06≈2.0e-5、exp(-16)*0.06≈6.8e-9 —— 两条阈值都远宽于实测,故本相不受
	#    recover 上调的影响(它只会让回归更快)。
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
	#    ★★ `delta = 0.0` 是**承重的**(与 ⑦c 同款、理由同):本相的过冲余量**只等于
	#    `squash_air`**,而指数恢复每帧要吃 `1-exp(-recover/60)`。2026-09-21 把 `squash_air`
	#    0.30→0.10、`squash_recover` 9→16 之后,恢复吃的(0.234)压过了空中项给的(0.10)
	#    ⇒ **过冲消失**,本相读到的成了 0.9480 而不是边界值 0.94 —— 断言失败,而组件是对的。
	#    冻掉恢复项后过冲恒为 `squash_air`,与 `squash_recover` 解耦。
	var g: Array = _mk()
	(g[0] as SquashStretch).impulse(SquashStretch.Impulse.JUMP)   # +0.75
	(g[0] as SquashStretch).impulse(SquashStretch.Impulse.DASH)   # +0.80 → 饱和到 +1.0
	(g[0] as SquashStretch).tick(0.0, -700.0, false, false)       # 空中项再叠 squash_air(未钳位时 v = 1 + air)
	#    ★★ 前提断言:本相的判别力 == `amount × squash_air`。把"余量被调到看不见"变成**红**,
	#    而不是让本相静默退化成一个恒真断言(`squash_air` 降到 0.02 时余量只剩 0.0012,
	#    与下面的 0.001 epsilon 同量级 ⇒ 会悄悄失去判别力)。这是本文件反复用到的同一手法。
	_ok(PlayerParams.squash_amount * PlayerParams.squash_air > 0.002,
			"本相过冲余量足够(== amount × squash_air = %.4f);不够就调回 squash_air 或改本相构造"
			% (PlayerParams.squash_amount * PlayerParams.squash_air))
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

	# ⑦c 下行饱和的**边界**守卫(⑦ 的镜像):⑦ 钉住 v == +1.0,这条钉住 v == -1.0。
	#     构造:三次 HURT(-0.50 ×3)把 `_impulse` 压到下行钳位(-1.0),再用一次满力落地
	#     (`-1.0`,与 ⑦ 里那个 `+0.30` 的空中项同款"反向的满幅项")让它稳稳停在钳位处。
	#     ★ `delta = 0.0` 是**刻意的**:指数恢复每帧要吃掉 14%,拿 `DT` 读到的会是
	#     `-0.8607`(scale.x 1.0861)而不是**边界值本身**。本相要钉的正是"v 到底钳在哪",
	#     故把恢复项冻掉(`approach(x, 0, r, 0) == x`,浮点精确);帧内其余部分照常。
	#     ★ 它**不**鉴别 `impulse()` 的下钳位(那里无论钳不钳都被 `_apply` 收进 -1.0),
	#     鉴别的是 `_apply()` 的下钳位 —— 去掉它 → v = -2.5 → scale.x = 1.25,红。
	var n: Array = _mk()
	(n[0] as SquashStretch).impulse(SquashStretch.Impulse.HURT)
	(n[0] as SquashStretch).impulse(SquashStretch.Impulse.HURT)
	(n[0] as SquashStretch).impulse(SquashStretch.Impulse.HURT)
	(n[0] as SquashStretch).tick(0.0, 2000.0, true, false)
	var ns: Vector2 = (n[1] as AnimatedSprite2D).scale
	_ok(absf(ns.x - 1.0) <= PlayerParams.squash_amount + 0.0001
			and absf(ns.y - 1.0) <= PlayerParams.squash_amount + 0.0001,
			"下行叠加不越下限,实测 %s" % str(ns))
	# 且必须"顶在下限上"而不是收缩回中性:v == -1.0 是**挤压** ⇒ x 顶在 1.0 + amount
	_ok(_near(ns.x, 1.0 + PlayerParams.squash_amount, 0.0005),
			"下行叠加停在钳位处(v=-1.0,宽矮),实测 %.4f(需 %.4f)" % [
				ns.x, 1.0 + PlayerParams.squash_amount])
	# ⑦d 下行饱和的**语义**守卫(⑦b 的镜像):叠的组数翻倍,结果必须完全相同 ——
	#     `impulse()` 的下钳位让第二组落在同一个饱和点。
	#     ★ 这里**不能**照抄 ⑦b 的"再叠一次满力落地":落地项会把两组一起压到 `_apply` 的
	#       钳位上(都是 -1.0),分叉被抹平、判据变成空转。去掉那个附加项才看得见
	#       "未钳位时四组是 -2.0(−1.72 被 `_apply` 收成 -1.0)vs 两组 -0.8607"。
	var n1: Array = _mk()
	for i in 2:
		(n1[0] as SquashStretch).impulse(SquashStretch.Impulse.HURT)
	(n1[0] as SquashStretch).tick(DT, 0.0, true, false)
	var n2: Array = _mk()
	for i in 4:
		(n2[0] as SquashStretch).impulse(SquashStretch.Impulse.HURT)
	(n2[0] as SquashStretch).tick(DT, 0.0, true, false)
	var sn1: Vector2 = (n1[1] as AnimatedSprite2D).scale
	var sn2: Vector2 = (n2[1] as AnimatedSprite2D).scale
	_ok(_near(sn1.x, sn2.x, 0.0005),
			"下行饱和:叠四组与叠两组同值,实测 %s" % (str(sn1) + " vs " + str(sn2)))

	# ⑦e 减法之后的**写入口钳位**(§3 末那条补记的唯一守卫)。它**只在违约宿主连喂两帧**时
	#     才显形,单帧是看不出来的 —— 单帧下 `_impulse` 只到 -1,`_apply()` 的钳位就把画面
	#     兜住了;第二帧再减一次才会掉到 -1 以下(无钳位时 -1.86 → 恢复后 -1.60)。
	#     ★ 判据:第二帧必须仍停在**钳位处那一条指数尾巴**上(`-1.0` 经一帧恢复 = -0.8607),
	#       而不是 -1.60 被 `_apply()` 兜成 -1 ⇒ 两者读出来分别是 **1.0861** 与 **1.1000**。
	#     ★ 违约宿主不是假想:`ClimbComponent` 在梯底按住 S 时**每帧**喂 720(见 spec §2.4)。
	var p: Array = _mk()
	(p[0] as SquashStretch).tick(DT, 2000.0, true, false)   # 第一帧满幅落地
	(p[0] as SquashStretch).tick(DT, 2000.0, true, false)   # 第二帧照喂:减法会被重来一次
	var ps: Vector2 = (p[1] as AnimatedSprite2D).scale
	var want_clamped: float = 1.0 + PlayerParams.squash_amount * exp(-PlayerParams.squash_recover * DT)
	_ok(_near(ps.x, want_clamped, 0.001),
			"减法后有写入口钳位:连喂两帧满幅落速仍停在 -1,实测 %.6f(需 %.6f;无钳位时是 1.1000)" % [
				ps.x, want_clamped])

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
	_owned.append(es)
	_owned.append(espr)
	es.setup(espr, SquashStretch.Profile.ENEMY)
	es.impulse(SquashStretch.Impulse.JUMP)     # 敌人侧没有 JUMP
	es.tick(DT, 0.0, true, false)
	_ok(_near(espr.scale.x, 1.0, 0.0005),
			"敌人 profile 对 JUMP 无响应,实测 %s" % str(espr.scale))
	es.impulse(SquashStretch.Impulse.TAKE_OFF)  # 敌人侧有 TAKE_OFF
	es.tick(DT, 0.0, true, false)
	_ok(espr.scale.x < 1.0, "敌人 profile 响应 TAKE_OFF(拉伸,窄高),实测 %s" % str(espr.scale))

	_free_owned()

	if _fail == 0:
		print("SQUASH SMOKE: ALL-OK")
	else:
		print("SQUASH SMOKE: FAIL | %d 条" % _fail)
	quit(1 if _fail > 0 else 0)
