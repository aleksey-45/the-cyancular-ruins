extends SceneTree

# 攀爬诊断:把真实玩家放到 demo 地图的梯子上,模拟按上,追踪它停在哪、能否到顶。
# 用法:godot --headless --path . -s res://tests/probe/climb_probe.gd

# 读回**真实**攀附状态。
# ★ 为什么不能写 `p.get("_latched")`:该字段住在 `ClimbComponent`(`scenes/player/climb_component.gd:9`),
#   玩家**根**只转发 `is_latched()`(`scenes/player/player.gd:261`)⇒ 在根上 `get("_latched")` 恒返回
#   `null`,"是否攀附"这一维**从来没有读数**(改前实测 4 处打印全是 `latched=<null>`)。
#   形状照抄仓内既有读法:`tests/probe/squash_host_water_probe.gd:285` 的 `_p.climb.is_latched()`。
# ★ 覆盖上限(照实写,别读多):本函数只让这一维**可观测**。`climb_probe` **仍不是守卫** ——
#   它没有断言、也没有 `EXPECTED_CHECKS` 条数闸,判据是人读输出。钉图(`c5804f4`)只消掉
#   "抽到哪张地图"这一维;**时序类**不确定性(帧数 / 机器负载)不受影响。
func _latched_of(p) -> Variant:
	if p == null:
		return "<no player>"
	if p.climb == null:
		return "<no climb>"
	return p.climb.is_latched()

func _initialize() -> void:
	TileDefs.load_defs()
	# ★★ 2026-10-04(**必须钉图**,任务 9):不钉的话 `MazeGenerator.map_file_path()` 会在
	#   `res://maps/*.cyrm` 里**随机抽一份**(`core/sim/maze_generator.gd:44` =
	#   `maps[randi() % maps.size()]`),而本探针把梯子位置**写死**成 demo.cyrm 的 c80 / r5-r8
	#   (下面 `cell_of(..., 125, 75)` 那对尺寸也是 demo.cyrm 的)⇒ 抽到 newfactory.cyrm(150×100,
	#   c76-84 / r3-12 一带**没有梯子**)时玩家脚下根本没有梯子,整份输出换一套:
	#   实测同版本连跑 6 次 → **3 次**是 demo(4032 shapes,爬到 y=259.7 卡在梯顶 r4)、
	#   **3 次**是 newfactory(4527 shapes,一路掉到 y=1286.9 / r20),两种结论**相反**。
	#   ⇒ 不钉图的 `climb_probe` **不能当"改前/改后一致"的基线**。
	# ★ 形状照抄仓内既有钉图写法(tests/probe/muzzle_probe.gd:12-18、preview_probe.gd:15-21):
	#   set_map_file → load_map_file → 空图早退 → 赋 current_grid。
	# ★ 覆盖上限:钉图只消掉"哪张地图"这一维;**时序类**不确定性(帧数 / 机器负载)不受影响。
	MazeGenerator.set_map_file("res://maps/demo.cyrm")
	var grid: Array[Array] = MazeGenerator.load_map_file()
	if grid.is_empty():
		printerr("地图加载失败")
		quit(1)
		return
	MazeGenerator.current_grid = grid

	# 真实墙体碰撞(验证 78px 宽碰撞箱爬 64px 梯子会不会卡墙)
	var host := Node2D.new()
	host.name = "PerfHost"
	root.add_child(host)
	CollisionBuilder.build_permanent(CollisionBuilder.build_sub(grid, false), host, "WallCollision")
	CollisionBuilder.build_destructible_chunks(CollisionBuilder.build_sub(grid, true), host)
	CollisionBuilder.build_climb_ledges(grid, host)

	var player_scene: PackedScene = load("res://scenes/player/player.tscn")
	var p = player_scene.instantiate()
	root.add_child(p)

	# 场景:r5-r8 的梯子在 c80(贴墙 c76-79)。玩家放 r8 c80(梯子底部)。
	p.global_position = Vector2(80 * 64 + 32, 8 * 64 + 32)
	await physics_frame
	print("[climb] 起点 y=", p.global_position.y, " cell=",
			MazeGenerator.cell_of(p.global_position, 64, 125, 75))
	Input.action_press("up")
	var prev_y: float = p.global_position.y
	for i in range(90):
		await physics_frame
		var y: float = p.global_position.y
		if absf(y - prev_y) < 0.01 and i > 3:
			# 卡住:连续几帧不动
			var stuck_frames := 0
			for j in range(10):
				await physics_frame
				if absf(p.global_position.y - y) < 0.01:
					stuck_frames += 1
			print("[climb] 卡住 @ frame %d y=%.1f(脚距顶 %dpx) latched=%s cell=%s" % [
				i, y, int(y + 57 - 5 * 64), _latched_of(p),
				MazeGenerator.cell_of(p.global_position, 64, 125, 75)])
			break
		prev_y = y
		if i % 10 == 0:
			print("[climb] frame %d y=%.1f latched=%s on_floor=%s" % [i, y, _latched_of(p), p.is_on_floor()])
	Input.action_release("up")
	print("[climb] 结束 y=%.1f cell=%s" % [p.global_position.y,
			MazeGenerator.cell_of(p.global_position, 64, 125, 75)])
	p.free()
	quit(0)
