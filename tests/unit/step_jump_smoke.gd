extends SceneTree

const EXPECTED_CHECKS := 12

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _solid_set(cells: Array) -> Callable:
	var m := {}
	for c in cells:
		m[c] = true
	return func(c: Vector2i) -> bool: return m.has(c)


func _initialize() -> void:
	if load("res://core/sim/step_jump.gd") == null:
		print("STEP JUMP FAILED: load(step_jump.gd) 返回 null(-s 空载守卫:不 quit 会挂死)")
		quit(1)
		return

	var feet := Vector2i(10, 20)

	_chk(StepJump.low_step_height(feet, 1, _solid_set([])) == 0,
			"前方无实体必须是 0(实得 %d)" % StepJump.low_step_height(feet, 1, _solid_set([])))

	var one := _solid_set([Vector2i(11, 20)])
	_chk(StepJump.low_step_height(feet, 1, one) == 1,
			"16px 台阶必须是高度 1(实得 %d)" % StepJump.low_step_height(feet, 1, one))

	var four := _solid_set([Vector2i(11, 20), Vector2i(11, 19), Vector2i(11, 18), Vector2i(11, 17)])
	_chk(StepJump.low_step_height(feet, 1, four) == 4,
			"★ 正好 1 格(4 子格)必须允许自动跳、高度 4(实得 %d)" % StepJump.low_step_height(feet, 1, four))

	var tall_cells: Array = []
	for k in range(8):
		tall_cells.append(Vector2i(11, 20 - k))
	var tall := _solid_set(tall_cells)
	_chk(StepJump.low_step_height(feet, 1, tall) == -1,
			"★ 高于一格必须返回 -1(实得 %d)" % StepJump.low_step_height(feet, 1, tall))

	var one_left := _solid_set([Vector2i(9, 20)])
	_chk(StepJump.low_step_height(feet, -1, one_left) == 1
			and StepJump.low_step_height(feet, 1, one_left) == 0,
			"左/右方向必须分开判(左 1 / 右 0;实得 %d / %d)" % [
				StepJump.low_step_height(feet, -1, one_left),
				StepJump.low_step_height(feet, 1, one_left)])

	_chk(StepJump.low_step_height(feet, 0, one) == 0,
			"dir==0 必须返回 0(实得 %d)" % StepJump.low_step_height(feet, 0, one))

	var walk_ok := StepJump.is_walk_up_step(1) and StepJump.is_walk_up_step(2)
	var jump_ok := not StepJump.is_walk_up_step(3) and not StepJump.is_walk_up_step(4)
	_chk(walk_ok, "≤2 子格(16/32px)必须是\"走上去\"(不跳)")
	_chk(jump_ok, "3~4 子格(48/64px)必须仍然起跳")
	var g := 1600.0
	var v64 := StepJump.jump_velocity_for_height(64.0, g)
	var v16 := StepJump.jump_velocity_for_height(16.0, g)
	_chk(absf((v64 * v64) / (2.0 * g) - 64.0) < 0.01,
			"★ 64px 台阶的起跳速度应恰好跳到 64px(反算得 %.2f)" % ((v64 * v64) / (2.0 * g)))
	_chk(absf(v16) < absf(v64) and absf(v64) < 1000.0 and absf(v16) > 0.0,
			"★ 16px 台阶应比 64px 跳得轻,且 1 格小跳弱于满力跳(实得 |%.1f| / |%.1f|)" % [v16, v64])
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
