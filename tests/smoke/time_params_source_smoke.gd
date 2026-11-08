extends SceneTree

# 单机时间玩法参数守卫(-s,headless,不实例化 autoload):唯一真相源 = time_config.tres。
# 去掉什么会红:
#   ① TimeParams 不再转发 .tres(值搬回 .gd 且与 .tres 不同),或新 @export 字段没转发 ⇒ ② 红
#      (字段清单从 time_config.gd 的 @export 列表反射枚举,不手写);
#   ② 改 .tres 的 GRAIN_INITIAL / COST_* / HASTE_* / SHORT_WINDOW / LOAN_LIMIT / LOAN_ENEMY_SPEED_BONUS
#      ⇒ ③④⑤⑥ 精确红(期望值 = 本文件字面量);③ GrainAccount.new() 不再取 TimeParams 默认值 ⇒ ③⑤⑥ 红。
# ★ 测不到:static var 换 getter 后行为完全一样(只是慢 13.8×)—— 性能不在本守卫射程内。

const EXPECTED_CHECKS := 6

const CONFIG_PATH := "res://core/config/time_config.tres"

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	var cfg: Resource = load(CONFIG_PATH)
	if cfg == null:
		print("TIME PARAMS SOURCE FAILED: load(%s) 为空(-s 空载守卫:不 quit 会挂死)" % CONFIG_PATH)
		quit(1)
		return

	# ① 唯一真相源就是这一份实例(TimeParams 的 _CFG 与按路径 load 出来的必须是同一个对象)。
	_chk(cfg == TimeParams._CFG,
			"① TimeParams 应以 const preload 引入 %s(实得 %s)"
					% [CONFIG_PATH, "同一实例" if cfg == TimeParams._CFG else "另一实例"])

	# ② 逐项与 .tres 一致。字段清单从 time_config.gd 的 @export 列表反射枚举(不手写):
	#    新增字段漏转发 ⇒ TimeParams.new().get(名字) 取不到 ⇒ 红;值搬回 .gd 且与 .tres 分叉 ⇒ 红。
	var schema: Script = cfg.get_script()
	var names: Array[String] = []
	if schema != null:
		for p in schema.get_script_property_list():
			if int(p.get("usage", 0)) & PROPERTY_USAGE_SCRIPT_VARIABLE:
				names.append(str(p.get("name")))
	var tp := TimeParams.new()
	var mism: Array[String] = []
	for name in names:
		var got = tp.get(name)
		var want = cfg.get(name)
		if got == null or got != want:
			mism.append("%s: TimeParams=%s / .tres=%s" % [name, str(got), str(want)])
	_chk(names.size() >= 18 and mism.is_empty(),
			"② schema 枚举 %d 个 @export 应逐项等于 .tres(不一致 %d 项:%s)"
					% [names.size(), mism.size(), ", ".join(mism)])

	# ③ 加速 1 秒:扣 COST_HASTE(80),余额 1000-80=920,GrainAccount 默认值来自 TimeParams。
	var acc := GrainAccount.new()
	var f := TimeField.new(acc)
	TimeField.current = f
	f.update(1.0, false, true)
	_chk(f.mode == TimeField.Mode.HASTE and is_equal_approx(acc.balance, 920.0),
			"③ 加速 1s:模式 HASTE、余额 920(COST_HASTE=80,实得 %s / %.2f)"
					% [str(f.mode), acc.balance])

	# ④ 加速倍率:HSTE_PLAYER=2.0 / HASTE_WORLD=0.5(普通敌与敌弹同吃 0.5)。
	_chk(is_equal_approx(TimeField.player_speed_mult(), 2.0)
			and is_equal_approx(TimeField.world_delta(1.0), 0.5)
			and is_equal_approx(TimeField.enemy_delta(1.0, null), 0.5)
			and is_equal_approx(TimeField.bullet_delta(1.0, null), 0.5),
			"④ 加速倍率应为 玩家 2.0 / 世界 0.5 / 普通敌 0.5 / 敌弹 0.5(实得 %.2f / %.2f / %.2f / %.2f)"
					% [TimeField.player_speed_mult(), TimeField.world_delta(1.0),
							TimeField.enemy_delta(1.0, null), TimeField.bullet_delta(1.0, null)])

	# ⑤ 回溯 1 秒:扣 COST_REWIND(120),余额 1000-120=880,回溯期速度倍率 0。
	var acc2 := GrainAccount.new()
	var f2 := TimeField.new(acc2)
	TimeField.current = f2
	f2.update(1.0, true, false)
	_chk(f2.mode == TimeField.Mode.REWIND and f2.is_rewinding()
			and is_equal_approx(acc2.balance, 880.0)
			and is_equal_approx(TimeField.player_speed_mult(), 0.0),
			"⑤ 回溯 1s:模式 REWIND、余额 880(COST_REWIND=120)、末速倍率 0(实得 %s / %.2f / %.2f)"
					% [str(f2.mode), acc2.balance, TimeField.player_speed_mult()])

	# ⑥ 贷款深度喂给普通敌速度:loan_used 打满 loan_max ⇒ 倍率 1 + LOAN_ENEMY_SPEED_BONUS(0.5) = 1.5。
	var acc3 := GrainAccount.new()
	acc3.spend(1.0, 400.0)     # 打满短时窗,尚未进贷款
	acc3.spend(0.25, 400.0)    # 溢出 100 = 贷款限额 ⇒ 贷满锁定,depth = 1
	var f3 := TimeField.new(acc3)
	TimeField.current = f3     # 模式 NONE:只留贷款深度的世界反馈
	_chk(acc3.locked and is_equal_approx(acc3.loan_depth(), 1.0)
			and is_equal_approx(TimeField.enemy_speed_mult(null), 1.5)
			and is_equal_approx(TimeField.enemy_delta(1.0, null), 1.5),
			"⑥ 贷满(depth=1)普通敌速度倍率应为 1+0.5=1.5(实得 locked=%s / depth=%.2f / speed=%.2f / delta=%.2f)"
					% [str(acc3.locked), acc3.loan_depth(), TimeField.enemy_speed_mult(null),
							TimeField.enemy_delta(1.0, null)])

	if _checks != EXPECTED_CHECKS:
		print("TIME PARAMS SOURCE FAILED: 只跑了 %d 条 != %d(脚本中途中止)" % [_checks, EXPECTED_CHECKS])
		quit(1)
		return
	if not _fails.is_empty():
		print("TIME PARAMS SOURCE FAILED (%d/%d):" % [_fails.size(), EXPECTED_CHECKS])
		for m in _fails:
			print("  - " + m)
		quit(1)
		return
	print("TIME PARAMS SOURCE OK(%d 条断言):.tres 同一实例 · 18 字段逐一一致 · 加速扣费 · 加速倍率 · 回溯扣费 · 贷款深度倍率" % _checks)
	quit(0)
