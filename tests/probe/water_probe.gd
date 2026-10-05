extends SceneTree
# 水逻辑冒烟。用户自跑:
#   "D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/probe/water_probe.gd
# 成功打印 WATER OK 退出 0。-s 阶段 autoload 未实例化,静态代码不得引 autoload。

var _failed := false
func _check(cond: bool, msg: String) -> void:
	if not cond:
		_failed = true
		push_error("FAIL: " + msg)
func _check_eq(a, b, msg: String) -> void:
	if a != b:
		_failed = true
		push_error("FAIL: %s (got %s want %s)" % [msg, a, b])
func _check_approx(a: float, b: float, tol: float, msg: String) -> void:
	if absf(a - b) > tol:
		_failed = true
		push_error("FAIL: %s (got %s want %s)" % [msg, a, b])

func _init() -> void:
	MazeGenerator.current_grid = _make_grid()
	TileDefs.load_defs()

	# v3 格式:纹理 3 位 0xx + 形状 hex(水 21/22)
	var wrow := MapFormat.serialize_v3_grid([[MazeGenerator.pack(21, 15), MazeGenerator.pack(22, 15), 0]])
	_check_eq(wrow[0], "021F022F0000", "v3 序列化水:021F/022F/空气")
	_check_eq(MapFormat.parse_v3_grid(["021F"])[0][0], MazeGenerator.pack(21, 15), "v3 解析水:021F->pack(21,15)")
	_check_eq(TileDefs.type_of(21), "liquid", "tex21 type liquid")
	_check_approx(TileDefs.explosion_decay_of(21), 0.25, 1e-6, "tex21 decay 0.25")
	_check_approx(TileDefs.explosion_decay_of(15), TileDefs.explosion_decay(), 1e-6, "落叶回落全局 0.75")

	# Water 判定(合成网格:y=5 整行水,y=6 墙)
	var surf := Vector2(5 * 64 + 32, 5 * 64 + 32)
	_check(Water.is_in_water(surf), "水格判水")
	_check(not Water.is_in_water(Vector2(5 * 64 + 32, 4 * 64 + 32)), "水面上方不是水")
	_check_eq(Water.surface_y_at(Vector2(5 * 64 + 32, 5 * 64 + 32)), 5 * 64, "水面线=第5行顶")
	_check_eq(Water.surface_y_at(Vector2(5 * 64 + 32, 4 * 64 + 32)), 4 * 64 + 32, "不在水里回传 pos.y")
	_check(Water.submerged(Vector2(5 * 64 + 32, 6 * 64), 5 * 64), "中心在水面线下=没顶")
	_check(not Water.submerged(Vector2(5 * 64 + 32, 5 * 64), 5 * 64), "中心在水面线=浮着不算")

	# 子弹水中阻力
	var f := Water.bullet_drag_factor(true, 2.0, 0.1)
	_check_approx(f, exp(-0.2), 1e-4, "水中阻力 exp(-0.2)")
	_check_approx(Water.bullet_drag_factor(false, 2.0, 0.1), 1.0, 1e-6, "岸上无阻力")

	# 爆炸:目标在水里 ×0.25,岸上 ×1.0
	var g := MazeGenerator.current_grid
	_check_approx(Water.water_mult(Vector2(5 * 64 + 32, 5 * 64 + 32), g), 0.25, 1e-6, "目标在水里 ×0.25")
	_check_approx(Water.water_mult(Vector2(5 * 64 + 32, 4 * 64 + 32), g), 1.0, 1e-6, "目标在岸上 ×1.0")

	# ── 游泳组件:缺 src 的契约(2026-10-04,审计 §2.6 的**第 4 处**)──────────────
	# 与武器那三处同款的兜底:`update(..., src := null)` 原先会在 src 缺省时**自己 new 一个**
	# 「读真实 Input」的本地输入源 ⇒ 组件能从全局输入总线偷读,而且**完全不报错**;权威服务器 /
	# 回放 / 预测下那是错的来源(headless 读到的是**宿主机桌面**的按键)。收口后:缺 src ⇒
	# 点名报错 + 安全返回 false、**不碰 parent 物理**。
	#
	# ★★ 为什么这条**行为**守卫在这个病上**有牙**(与武器那三处不同,别照抄"天生无牙"那句):
	#   武器那三处只返回布尔 ⇒ 旧兜底在 headless 下(轴恒 0、按键恒假)与"安全返回 false"
	#   **逐帧恒等**,行为上不可分。本组件不同:旧兜底会**继续走完**水中物理 ——
	#   `velocity.x` 被 approach 写、`velocity.y` 被写成 player_swim_down(=320),并**返回 true**;
	#   收口后是"不写 parent、返回 false" ⇒ 返回值与 velocity 两处都能把两版区分开。
	#   (源码形状那一半在 `tests/smoke/player_contract_smoke.gd`,两条互补。)
	#
	# ⚠ 本相**故意**触发一条 push_error(缺 src 就是要点名报错)⇒ 绿灯运行时 stderr 里
	#   也会有一行 ERROR,那是**预期输出**;本冒烟的判据是文本 `WATER OK`,不是"stderr 无 ERROR"。
	var body := SwimHost.new()
	body.position = surf                       # 水格正中(y=5 行)
	var swim := SwimComponent.new()
	# ★ 前提断言**必须放最前**:身体若根本不在水里,旧兜底同样会 `return false`
	#   ⇒ 下面两条在"没进水"下恒真(静默假绿)。脚底偏移走 Water 自己的口径(裸体无碰撞箱 ⇒ 24)。
	_check(Water.is_in_water(Vector2(body.position.x, body.position.y + Water.feet_offset(body))),
			"缺 src 相前提:身体脚底应落在水格里(不在水里 ⇒ 下面两条恒真,测不到东西)")
	_check_eq(swim.update(body, 1.0 / 60.0, Vector2.ONE), false,
			"游泳组件缺 src 时必须安全返回 false(旧兜底会自造本地输入源 ⇒ 走完水中物理并返回 true)")
	_check_eq(body.velocity, Vector2.ZERO,
			"游泳组件缺 src 时不得驱动 parent 物理(旧兜底会写 velocity.y = player_swim_down)")
	swim.free()
	body.free()

	if _failed:
		quit(1)
	else:
		print("WATER OK")
		quit(0)

# 缺 src 相用的裸宿主:游泳组件只碰 global_position / velocity。
# ★ 本字段(`pvp_haste_mult`)**已无读者**(2026-10-05 closeout 批 Task 3 之后 —— 下面那句要用**过去时**读):
#   那时 `swim_component.gd` 在 `TimeField.current == null` 时走 `parent.get("pvp_haste_mult")` 的**字符串反射**;
#   现在那一路改成**调用方注入**的 `haste_mult` 调用参数(`player.gd` 每次调用都给)⇒ 组件不再按名摸宿主。
#   ★ 删掉本字段**不会让任何断言红**(本桩的用例都在 `src == null` 上早退、走不到那一支);
#     本包按范围纪律**只订正注释、不删字段**(Ruling 明写"两个桩不用改")。
# ★ 当年为什么必须给这个字段:没有它 `float(null)` 会让**旧兜底那版**在函数中途报错,
#   于是"红"的原因变成类型转换而不是我们要钉的契约(假红,证据不可用)。
class SwimHost extends CharacterBody2D:
	var pvp_haste_mult := 1.0   # ← 已无读者(见上;历史遗迹,不是"为反射而给"的活接口)


# 10×10 合成网格:y=5 整行水(tex21 全砖),y=6 整行实体墙,其余空气。
func _make_grid() -> Array[Array]:
	var grid: Array[Array] = []
	for y in range(10):
		var row: Array[int] = []
		for x in range(10):
			if y == 5:
				row.append(MazeGenerator.pack(21, 15))
			elif y == 6:
				row.append(MazeGenerator.SOLID)
			else:
				row.append(MazeGenerator.EMPTY)
		grid.append(row)
	return grid
