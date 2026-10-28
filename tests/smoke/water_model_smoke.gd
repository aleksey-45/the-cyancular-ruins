extends SceneTree

# 水判定冒烟(纯逻辑 -s,合成网格,不读地图文件、不引 autoload)。
# 最强保证:Water.sample_body 的采样点/水面线/滞回/环面归一/全液列上限按设计工作,
#   且 feet_offset 的缓存签名能把 CollisionPolygon2D 的姿态切换算进去(旧实现只数 CollisionShape2D ⇒ 缓存永不失效)。
# 测不到什么:实际游泳手感/水面观感(人眼验收)、真实玩家姿态箱几何(player.tscn)、
#   子弹阻力与爆炸的"点口径"(本轮未迁移)、水粒子观感。
# 跑法:"$GODOT" --headless --path . -s res://tests/smoke/water_model_smoke.gd;通过 = 结尾打 WATER MODEL OK(n 条断言)。

const EXPECTED_CHECKS := 13
const ROWS := 12
const COLS := 20
const WS := preload("res://core/sim/water_sample.gd")
const GameConfig := preload("res://core/config/game_parameters.gd")

var _fails: Array[String] = []
var _checks := 0
var _bodies: Array[Node] = []


func _initialize() -> void:
	TileDefs.load_defs()
	MazeGenerator.current_grid = _make_grid()

	# ① 干地:整条竖线没有液体 ⇒ 不湿、无水面
	var b := _make_body(544.0, 400.0, 64.0)   # 第 8 列全空气
	var s := Water.sample_body(b, false)
	_chk(not s.in_water and s.surface_kind == WS.SURFACE_NONE, "干地:in_water=false 且 surface_kind=NONE")

	# ② 单格水:脚在水格中段 ⇒ 自由液面 + 深度 32 + 半没入
	b = _make_body(96.0, 352.0, 64.0)          # 第 1 列 row5 水、row6 墙
	s = Water.sample_body(b, false)
	_chk(s.in_water and s.surface_kind == WS.SURFACE_FREE and _eq(s.surface_y, 320.0)
			and _eq(s.feet_depth, 32.0) and _eq(s.submersion_ratio, 0.5) and not s.head_under,
			"单格水:软/硬字段 —— in_water / FREE / surface=320 / depth=32 / ratio=0.5 / 头在水上")

	# ③ 浅水站立:脚正好压在实心底边界(旧点查询会把脚判成"墙格 ⇒ 不在水里")
	b = _make_body(160.0, 384.0, 96.0)         # 第 2 列 row5 水、row6 墙;脚=row6 顶边
	s = Water.sample_body(b, false)
	_chk(s.in_water and _eq(s.surface_y, 320.0), "浅水站立:脚落在实心格边界仍算在水中(按活动箱底边采样)")

	# ④ 2 格深池底:头没入水面线 ⇒ head_under=true(呼吸的唯一判据)
	b = _make_body(224.0, 448.0, 107.0)        # 第 3 列 row5/6 水、row7 墙;头顶=341,在水面 320 下方 21px
	s = Water.sample_body(b, false)
	_chk(s.in_water and s.head_under and _eq(s.feet_depth, 128.0) and _eq(s.submersion_ratio, 1.0),
			"2 格深池底:in_water + head_under + depth=128 + ratio=1")

	# ⑤ 多段水柱:取身体所在段的顶边,不是整列最顶
	b = _make_body(288.0, 576.0, 64.0)         # 第 4 列 row3 水、row8 水、row9 墙
	s = Water.sample_body(b, false)
	_chk(s.in_water and _eq(s.surface_y, 512.0), "多段水柱:水面线取所在段顶边(512 = row8 顶),不是 row3")

	# ⑥ 墙封顶:surface_kind=CEILING(水袋被天花板压住,没有自由面)
	b = _make_body(352.0, 384.0, 64.0)         # 第 5 列 row4 墙、row5 水、row6 墙
	s = Water.sample_body(b, false)
	_chk(s.surface_kind == WS.SURFACE_CEILING and _eq(s.surface_y, 320.0), "墙封顶:CEILING + 水面线=row5 顶")

	# ⑦ 全液列:标 FULL、仍算在水里,且向上扫有上限(旧实现 while(true) 会挂死)
	b = _make_body(416.0, 400.0, 64.0)         # 第 6 列整列液体
	s = Water.sample_body(b, false)
	_chk(s.surface_kind == WS.SURFACE_FULL and s.in_water and s.head_under, "全液列:FULL/in_water/head_under 且不挂")

	# ⑧ 跨上下 seam:水面线归一到最近环面副本(-128),深度 = 168
	b = _make_body(480.0, 40.0, 64.0)          # 第 7 列 row10/11/0/1 水
	s = Water.sample_body(b, false)
	_chk(s.in_water and _eq(s.surface_y, -128.0) and _eq(s.feet_depth, 168.0),
			"跨上下 seam:surface_y 归一最近副本(-128)、depth=168(旧实现返回 canonical 640 ⇒ 永不没顶)")

	# ⑨ 左右 seam:负 x 取模到最后一列,判定不受影响
	b = _make_body(-5.0, 384.0, 96.0)          # 第 19 列 row5 水、row6 墙
	s = Water.sample_body(b, false)
	_chk(s.in_water and _eq(s.surface_y, 320.0), "左右 seam:负 x 落到最后一列照常判水")

	# ⑩ 滞回:深度 5px 从外不进水、从里保持;在线(深度 0)从里保持、从外不进;线上方 1px 退出
	b = _make_body(96.0, 325.0, 64.0)
	var from_out := Water.sample_body(b, false).in_water
	var stay_in := Water.sample_body(b, true).in_water
	var at_line_in := Water.sample_body(_make_body(96.0, 320.0, 64.0), true).in_water
	var at_line_out := Water.sample_body(_make_body(96.0, 320.0, 64.0), false).in_water
	var above := Water.sample_body(_make_body(96.0, 319.0, 64.0), true).in_water
	_chk(not from_out and stay_in and at_line_in and not at_line_out and not above,
			"滞回:enter=8px / 水面线附近保持上一帧结论 / 脚进水线上方即退出")

	# ⑪ feet_offset 缓存签名:混合箱 + 只切换多边形也要失效重算(旧实现只数 CollisionShape2D ⇒ 卡在 40)
	var mixed := _make_mixed_body()
	_bodies.append(mixed)
	var off_before := Water.feet_offset(mixed)
	(mixed.get_child(1) as CollisionPolygon2D).disabled = true
	(mixed.get_child(2) as CollisionPolygon2D).disabled = false
	var off_after := Water.feet_offset(mixed)
	_chk(_eq(off_before, 40.0) and _eq(off_after, 60.0),
			"feet_offset:混合 CollisionShape2D+CollisionPolygon2D,只切多边形时缓存也失效(40→60)")

	# ⑫ 没顶判定严格性:头正好在水面线不算没顶,再往下 1px 才算(y 向下,> = 更低)
	var at_surface := Water.sample_body(_make_body(224.0, 448.0, 128.0), false)   # 头顶=320=水面
	var below_surface := Water.sample_body(_make_body(224.0, 448.0, 127.0), false)  # 头顶=321
	_chk(not at_surface.head_under and below_surface.head_under, "head_under:头=水面线不算没顶,低 1px 才算")

	# ⑬ 未迁移面保活:is_in_water/surface_y_at/submerged 与阈值来源
	var compat := Water.is_in_water(Vector2(96.0, 352.0)) and not Water.is_in_water(Vector2(96.0, 256.0)) \
			and _eq(Water.surface_y_at(Vector2(480.0, 40.0)), -128.0) \
			and is_finite(Water.surface_y_at(Vector2(416.0, 400.0))) \
			and Water.submerged(Vector2(0.0, 100.0), 50.0) and not Water.submerged(Vector2(0.0, 50.0), 50.0) \
			and _eq(GameConfig.water_enter_depth, 8.0) and _eq(GameConfig.water_exit_depth, -2.0) \
			and Water.is_liquid(21) and not Water.is_liquid(8)
	_chk(compat, "未迁移面:is_in_water/surface_y_at(含全液列有限值)/submerged/阈值常量/liquid 类型")

	for n in _bodies:
		if is_instance_valid(n):
			n.free()
	if _checks != EXPECTED_CHECKS:
		_fails.append("实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("WATER MODEL OK(%d 条断言):采样/水面线/环面归一/全液列/滞回/feet_offset/未迁移面" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("WATER MODEL FAILED: %d 处" % _fails.size())
		quit(1)


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _eq(a: float, b: float) -> bool:
	return absf(a - b) <= 0.001


# 合成网格:20×12 格,按断言各自造一段水域(其余全空气)。
func _make_grid() -> Array[Array]:
	var grid: Array[Array] = []
	for y in ROWS:
		var row: Array[int] = []
		row.resize(COLS)
		row.fill(MazeGenerator.EMPTY)
		grid.append(row)
	var water := MazeGenerator.pack(21, 15)
	var wall := MazeGenerator.pack(8, 15)
	grid[5][1] = water
	grid[6][1] = wall
	grid[5][2] = water
	grid[6][2] = wall
	grid[5][3] = water
	grid[6][3] = water
	grid[7][3] = wall
	grid[3][4] = water
	grid[8][4] = water
	grid[9][4] = wall
	grid[4][5] = wall
	grid[5][5] = water
	grid[6][5] = wall
	for y in ROWS:
		grid[y][6] = water
	grid[10][7] = water
	grid[11][7] = water
	grid[0][7] = water
	grid[1][7] = water
	grid[5][19] = water
	grid[6][19] = wall
	return grid


# 测试身体:原点在几何中心,碰撞箱底边 = feet_y、顶边 = feet_y - height。
func _make_body(x: float, feet_y: float, height: float) -> CharacterBody2D:
	var body := CharacterBody2D.new()
	var cs := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(40.0, height)
	cs.shape = rect
	body.add_child(cs)
	root.add_child(body)
	body.global_position = Vector2(x, feet_y - height * 0.5)
	_bodies.append(body)
	return body


# 混合碰撞体:矩形箱底 30;多边形 A 底 40(启用)、多边形 B 底 60(禁用)。
func _make_mixed_body() -> CharacterBody2D:
	var body := CharacterBody2D.new()
	var cs := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(40.0, 60.0)
	cs.shape = rect
	body.add_child(cs)
	var poly_a := CollisionPolygon2D.new()
	poly_a.polygon = PackedVector2Array([Vector2(-20, -20), Vector2(20, -20), Vector2(20, 40), Vector2(-20, 40)])
	body.add_child(poly_a)
	var poly_b := CollisionPolygon2D.new()
	poly_b.polygon = PackedVector2Array([Vector2(-20, -20), Vector2(20, -20), Vector2(20, 60), Vector2(-20, 60)])
	poly_b.disabled = true
	body.add_child(poly_b)
	root.add_child(body)
	return body
