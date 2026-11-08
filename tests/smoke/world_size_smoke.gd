extends SceneTree

# 世界尺寸派生守卫(`-s`,headless,不实例化 autoload)。
# 守的是**行为契约**:世界像素尺寸没有独立存储,它只能等于"当前网格 / 地图文件头 × TILE_SIZE"。
# 去掉什么会红:
#   ① 给 MAP_WIDTH 加回 setter 或退回可写字段(尺寸与网格脱钩)⇒ 换网格后尺寸不变,红;
#   ② world_cells() 不按 `set_map_file` 失效文件头缓存 ⇒ 换图后尺寸仍是上一张,红(靠 ④ 抓到);
#   ③ TILE_SIZE 与网格换算写错(漏乘 / 乘两次)⇒ 红;
#   ④ 可调参数不再来自 world_config.tres(有人搬回 .gd 常量)⇒ ⑤ 红。
# ★ 不是"拿实现验实现":断言只读**外部可观测的输入**(网格内容、被钉住的地图文件、.tres 字段),
#   期望值由测试自己算,不复用被测函数的返回值。

const EXPECTED_CHECKS := 5

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	# ★ 空载守卫(仓规):load() 失败还往下走会在 null 上抛错,而 `-s` 抛错走不到 quit() ⇒ 进程永久挂起。
	if load("res://core/config/game_parameters.gd") == null \
			or load("res://core/sim/maze_generator.gd") == null:
		print("WORLD SIZE FAILED: load(game_parameters/maze_generator) 为 null(-s 空载守卫:不 quit 会挂死)")
		quit(1)
		return

	var ts := 64   # 期望值自己算:64 是本仓 TILE_SIZE 的约定值,不从被测代码取

	# ① 网格 → 尺寸:8×6 格 ⇒ 512×384 px
	MazeGenerator.current_grid = _make_grid(8, 6)
	_chk(GameParameters.MAP_WIDTH == 8 * ts and GameParameters.MAP_HEIGHT == 6 * ts,
			"① 8×6 网格应得 512×384 px(实得 %d×%d)"
					% [GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT])

	# ② 换一份网格(20×11)⇒ 尺寸必须跟着变。这一条挡住"尺寸有独立存储 / 缓存没失效"。
	MazeGenerator.current_grid = _make_grid(20, 11)
	_chk(GameParameters.MAP_WIDTH == 20 * ts and GameParameters.MAP_HEIGHT == 11 * ts,
			"② 换 20×11 网格后应得 1280×704 px(实得 %d×%d;不变 = 尺寸与网格脱钩)"
					% [GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT])

	# ③ 网格清空 ⇒ 回退到**被钉住的地图文件头**。钉仓库内真实地图,期望值由 map_size() 独立取。
	var test_map := "res://maps/demo.cyrm"
	MazeGenerator.current_grid = []
	MazeGenerator.set_map_file(test_map)
	var cells: Vector2i = MazeGenerator.map_size()
	_chk(cells.x > 0
			and GameParameters.MAP_WIDTH == cells.x * ts
			and GameParameters.MAP_HEIGHT == cells.y * ts,
			"③ 网格清空后应回退到 %s 的文件头尺寸 %d×%d px(实得 %d×%d)"
					% [test_map, cells.x * ts, cells.y * ts,
							GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT])

	# ④ 换一张**不同尺寸**的图 ⇒ 回退值必须跟着换。这一条挡住"文件头缓存不按路径失效":
	#    ③ 只进了一次文件分支,缓存哪怕永不失效也照样绿;必须两张图来回切才观测得到。
	var other_map := "res://maps/newfactory.cyrm"
	MazeGenerator.set_map_file(other_map)
	var cells2: Vector2i = MazeGenerator.map_size()
	_chk(cells2 != cells
			and GameParameters.MAP_WIDTH == cells2.x * ts
			and GameParameters.MAP_HEIGHT == cells2.y * ts,
			"④ 换图到 %s 后应得 %d×%d px(实得 %d×%d;仍是旧图 = 文件头缓存没失效)"
					% [other_map, cells2.x * ts, cells2.y * ts,
							GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT])

	# ⑤ 可调参数确实走 world_config.tres:改 .tres 的值 ⇒ GameParameters 读到的必须跟着变。
	#    做法:用 CACHE_MODE_IGNORE 另加载一份、就地改字段,再确认**默认那份**不受影响、
	#    且 GameParameters 的值 = 默认那份 .tres 的值(不是别的来源)。
	#    去掉什么会红:有人把数值搬回 .gd 当常量、或 GameParameters 不再转发 .tres ⇒ 两边对不上,红。
	var cfg_path := "res://core/config/world_config.tres"
	var cfg: Resource = load(cfg_path)
	if cfg == null:
		_chk(false, "⑤ 空载守卫:load(world_config.tres) 为 null")
	else:
		var fresh: Resource = ResourceLoader.load(cfg_path, "", ResourceLoader.CACHE_MODE_IGNORE)
		fresh.gravity0 = cfg.gravity0 + 1234.0
		_chk(GameParameters.gravity0 == cfg.gravity0
				and fresh.gravity0 != GameParameters.gravity0,
				"⑤ gravity0 应来自 %s(期望 %.2f;另加载一份改成 %.2f 后必须不同,实得 %.2f)"
						% [cfg_path, cfg.gravity0, fresh.gravity0, GameParameters.gravity0])

	if _checks < EXPECTED_CHECKS:
		print("WORLD SIZE FAILED: 只跑了 %d 条 < %d(脚本中途中止)" % [_checks, EXPECTED_CHECKS])
		quit(1)
		return
	if not _fails.is_empty():
		print("WORLD SIZE FAILED (%d/%d):" % [_fails.size(), EXPECTED_CHECKS])
		for f in _fails:
			print("  - " + f)
		quit(1)
		return
	print("WORLD SIZE OK(%d 条断言):网格→尺寸 · 换网格跟变 · 空网格回退地图文件头 · 换图跟变 · 参数来自 .tres" % _checks)
	quit(0)


func _make_grid(cols: int, rows: int) -> Array[Array]:
	var g: Array[Array] = []
	for y in rows:
		var row: Array[int] = []
		row.resize(cols)
		row.fill(0)
		g.append(row)
	return g
