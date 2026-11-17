extends SceneTree

# 敌人参数守卫(`-s`,headless,不实例化 autoload)。
# 守的是**扁平字段 → 内层命名空间**的映射:enemy_config.tres 的字段是 `fly_bird_wake_radius` 这种扁平名,
# 由 enemy_params.gd 的内层类转成 `EnemyParams.FlyBird.wake_radius`。**错位赋值不会报任何错**,
# 只是读到另一个数字(典型的"改坏了很久才发现")。所以这里专盯映射,不重复测"参数来自 .tres"。
# 去掉什么会红:
#   ① 把 jump_bird_*/fly_bird_*/black_bird_* 三组前缀接错(如 FlyBird 读了 jump_bird_ 的字段)⇒ 红;
#   ② .tres 的 int 字段被写成 float 或被转发成 float ⇒ 类型断言红;
#   ③ 全部搬回 .gd 常量、不再读 .tres ⇒ ③ 红。
# ★ 期望值取自 .tres 本身(唯一真相源),不写字面量 —— 数值会调,钉死就会变成维护负担。

const EXPECTED_CHECKS := 3

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	# ★ 空载守卫(仓规):load() 失败还往下走会在 null 上抛错,而 `-s` 抛错走不到 quit() ⇒ 进程永久挂起。
	if load("res://core/config/enemy_params.gd") == null \
			or load("res://core/config/enemy_config.tres") == null:
		print("ENEMY PARAMS FAILED: load(enemy_params/enemy_config) 为 null(-s 空载守卫:不 quit 会挂死)")
		quit(1)
		return
	var cfg: Resource = load("res://core/config/enemy_config.tres")

	# ① 映射不错位:三只鸟的**同名**常量 wake_radius 必须分别等各自的扁平字段。
	#    三者在 .tres 里是三个不同的数 ⇒ 任意错位都会让某一条对不上。
	_chk(EnemyParams.JumpBird.wake_radius == cfg.jump_bird_wake_radius
			and EnemyParams.FlyBird.wake_radius == cfg.fly_bird_wake_radius
			and EnemyParams.BlackBird.wake_radius == cfg.black_bird_wake_radius
			and cfg.jump_bird_wake_radius != cfg.fly_bird_wake_radius
			and cfg.fly_bird_wake_radius != cfg.black_bird_wake_radius,
			"① 三只鸟的 wake_radius 应各取自自己的扁平字段(实得 %.1f / %.1f / %.1f;tres 里 %.1f / %.1f / %.1f)"
					% [EnemyParams.JumpBird.wake_radius, EnemyParams.FlyBird.wake_radius,
							EnemyParams.BlackBird.wake_radius,
							cfg.jump_bird_wake_radius, cfg.fly_bird_wake_radius,
							cfg.black_bird_wake_radius])

	# ② int 字段必须仍是 int。.tres 是文本、Godot 解析数字一律按类型标注还原,
	#    但转发时若写成 float 就会把 `drown_damage` / `bullet_damage` 这类整数量悄悄变成浮点(比较/取整全变味)。
	_chk(typeof(EnemyParams.shared.drown_damage) == TYPE_INT
			and typeof(EnemyParams.FlyBird.bullet_damage) == TYPE_INT
			and EnemyParams.shared.drown_damage == cfg.shared_drown_damage
			and EnemyParams.FlyBird.bullet_damage == cfg.fly_bird_bullet_damage,
			"② drown_damage / bullet_damage 应仍是 int 且等于 .tres(实得 %s / %s)"
					% [type_string(typeof(EnemyParams.shared.drown_damage)),
							type_string(typeof(EnemyParams.FlyBird.bullet_damage))])

	# ③ 确实来自 .tres:另加载一份、就地改字段,默认那份与 EnemyParams 都必须保持原值而与之不同。
	var fresh: Resource = ResourceLoader.load("res://core/config/enemy_config.tres", "",
			ResourceLoader.CACHE_MODE_IGNORE)
	fresh.fly_bird_charge_speed = cfg.fly_bird_charge_speed + 777.0
	_chk(EnemyParams.FlyBird.charge_speed == cfg.fly_bird_charge_speed
			and fresh.fly_bird_charge_speed != EnemyParams.FlyBird.charge_speed,
			"③ FlyBird.charge_speed 应来自 enemy_config.tres(期望 %.1f;另一份改成 %.1f 后必须不同,实得 %.1f)"
					% [cfg.fly_bird_charge_speed, fresh.fly_bird_charge_speed,
							EnemyParams.FlyBird.charge_speed])

	if _checks < EXPECTED_CHECKS:
		print("ENEMY PARAMS FAILED: 只跑了 %d 条 < %d(脚本中途中止)" % [_checks, EXPECTED_CHECKS])
		quit(1)
		return
	if not _fails.is_empty():
		print("ENEMY PARAMS FAILED (%d/%d):" % [_fails.size(), EXPECTED_CHECKS])
		for f in _fails:
			print("  - " + f)
		quit(1)
		return
	print("ENEMY PARAMS OK(%d 条断言):扁平→内层映射不错位 · int 仍是 int · 值来自 enemy_config.tres" % _checks)
	quit(0)
