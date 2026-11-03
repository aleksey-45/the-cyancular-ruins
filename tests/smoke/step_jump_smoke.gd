extends SceneTree
# 自动跳跃判据守卫(2026-11-01 用户要求「小于等于一格会自动跳跃」)。

const EXPECTED_CHECKS := 12

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


# 用字典当"实体子格集合"造一个 solid_at 回调(测试替身)。
func _solid_set(cells: Array) -> Callable:
	var m := {}
	for c in cells:
		m[c] = true
	return func(c: Vector2i) -> bool: return m.has(c)


func _initialize() -> void:
	# ★ 空载守卫(仓规):load() 失败还往下走会在 null 上抛错,而 `-s` 抛错走不到 quit() ⇒ 进程永久挂起。
	if load("res://core/sim/step_jump.gd") == null:
		print("STEP JUMP FAILED: load(step_jump.gd) 返回 null(-s 空载守卫:不 quit 会挂死)")
		quit(1)
		return

	var feet := Vector2i(10, 20)   # 脚底所在子格

	# ① 前方完全没挡路 ⇒ 0(不能把"没台阶"当成台阶)
	_chk(StepJump.low_step_height(feet, 1, _solid_set([])) == 0,
			"前方无实体必须是 0(实得 %d)" % StepJump.low_step_height(feet, 1, _solid_set([])))

	# ② 前方 1 个子格(16px 矮台阶)⇒ 1
	var one := _solid_set([Vector2i(11, 20)])
	_chk(StepJump.low_step_height(feet, 1, one) == 1,
			"16px 台阶必须是高度 1(实得 %d)" % StepJump.low_step_height(feet, 1, one))

	# ③ 承重:正好 1 格 = 4 个子格(64px)⇒ 4(仍是"≤1 格",必须允许自动跳)
	var four := _solid_set([Vector2i(11, 20), Vector2i(11, 19), Vector2i(11, 18), Vector2i(11, 17)])
	_chk(StepJump.low_step_height(feet, 1, four) == 4,
			"★ 正好 1 格(4 子格)必须允许自动跳、高度 4(实得 %d)" % StepJump.low_step_height(feet, 1, four))

	# ④ 承重:2 格高的墙(8 个子格)⇒ -1(不自动跳,否则会对着墙反复起跳)
	var tall_cells: Array = []
	for k in range(8):
		tall_cells.append(Vector2i(11, 20 - k))
	var tall := _solid_set(tall_cells)
	_chk(StepJump.low_step_height(feet, 1, tall) == -1,
			"★ 高于一格必须返回 -1(实得 %d)" % StepJump.low_step_height(feet, 1, tall))

	# ⑤ 向左看与向右看是镜像的(方向没写反)
	var one_left := _solid_set([Vector2i(9, 20)])
	_chk(StepJump.low_step_height(feet, -1, one_left) == 1
			and StepJump.low_step_height(feet, 1, one_left) == 0,
			"左/右方向必须分开判(左 1 / 右 0;实得 %d / %d)" % [
				StepJump.low_step_height(feet, -1, one_left),
				StepJump.low_step_height(feet, 1, one_left)])

	# ⑥ dir == 0 时恒 0(没按方向键不该触发)
	_chk(StepJump.low_step_height(feet, 0, one) == 0,
			"dir==0 必须返回 0(实得 %d)" % StepJump.low_step_height(feet, 0, one))

	# ⑦b 迈台阶判据:≤2 子格(32px)走上去、3~4 子格(48/64px)才起跳
	var walk_ok := StepJump.is_walk_up_step(1) and StepJump.is_walk_up_step(2)
	var jump_ok := not StepJump.is_walk_up_step(3) and not StepJump.is_walk_up_step(4)
	_chk(walk_ok, "≤2 子格(16/32px)必须是\"走上去\"(不跳)")
	_chk(jump_ok, "3~4 子格(48/64px)必须仍然起跳")
	# ⑦ 台阶"中间有空"不算连续实体(2 个子格高但缺一个 ⇒ 高度 1)
	# ... 以下为「跳跃高度 = 台阶高度」的三条(用户 2026-11-01 裁定)
	var g := 1600.0
	var v64 := StepJump.jump_velocity_for_height(64.0, g)
	var v16 := StepJump.jump_velocity_for_height(16.0, g)
	# ⑧ 峰值高度必须 == 给定高度(v²/(2g) 还原)
	_chk(absf((v64 * v64) / (2.0 * g) - 64.0) < 0.01,
			"★ 64px 台阶的起跳速度应恰好跳到 64px(反算得 %.2f)" % ((v64 * v64) / (2.0 * g)))
	# ⑨ 台阶越高跳得越有力(单调),且 1 格(64px)的小跳必须弱于整段满力跳
	_chk(absf(v16) < absf(v64) and absf(v64) < 1000.0 and absf(v16) > 0.0,
			"★ 16px 台阶应比 64px 跳得轻,且 1 格小跳弱于满力跳(实得 |%.1f| / |%.1f|)" % [v16, v64])
	# ⑩ 退化输入不产生 NaN/正值
	_chk(StepJump.jump_velocity_for_height(0.0, g) == 0.0 and StepJump.jump_velocity_for_height(64.0, 0.0) == 0.0,
			"零高度/零重力必须返回 0(不得出 NaN/正速度)")
	var gap := _solid_set([Vector2i(11, 20), Vector2i(11, 18)])
	_chk(StepJump.low_step_height(feet, 1, gap) == 1,
			"不连续实体只按连续段计高(实得 %d)" % StepJump.low_step_height(feet, 1, gap))

	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("STEP JUMP OK(%d 条断言):无阻挡 0 · 16px 台阶 1 · 正好一格 4 · 高于一格 -1 · 左右镜像 · dir=0 · 连续段" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("STEP JUMP FAILED: %d 处" % _fails.size())
		quit(1)
