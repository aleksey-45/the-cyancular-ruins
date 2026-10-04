extends Node

# `MatchHost.destroyed_cells()` 探针(场景模式:root 有 autoload/`multiplayer`)。
# 跑法: "$GODOT" --headless --path . --quit-after 3600 res://tests/probe/destroyed_cells_probe.tscn
# 通过 = `DESTROYED CELLS: ALL-OK` 退出 0。
#
# ═══ 为什么需要它 ═══
# ★ 这个方法喂的是"重连后补破坏态"的载荷。它算错的表现是**静默**的:客户端少补几格墙
#   (留下幻影墙 → 预测分歧)或多补几格(凭空拆墙)。两种都不报错,只有真比对才照得出来。
# ★ 确定性:顺序必须是"按 y 升序、同 y 按 x 升序",否则同样的地图会给出不同的数组,
#   载荷无法逐字比对(联机侧要能复现)。
# 做法同 match_host_hygiene_probe:真建 MatchHost,但 **role_peers 传空** —— 不建玩家、不排 peer、不发包。

const MAP := "res://maps/newfactory.cyrm"

var _fails: Array[String] = []
var _host = null
# ★ 为什么需要它(实测踩到):`_run()` 里任何**运行期**脚本错误(如调了不存在的方法)会让
#   GDScript 当场从 `_run()` 返回,而 `_ready()` 接着照常调 `_finish()` —— 此时 `_fails` 是空的,
#   探针会**打印 `ALL-OK` 并退出 0**(本任务 Step 3 的真实现象)。这与本仓"判据是 grep ALL-OK"
#   的约定冲突:`ALL-OK` 必须真的意味着"跑完了且全过"。故记一个跑完闩。
var _ran_to_end := false


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  ok  " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


# 相③ 用:`destructible_sub` 里**不属于** cell 的非空子格数。
# ★ 为什么读"数"而不直接读"被清了哪些":`destructible_sub` 是**整图**的可破坏子格表
#   (newfactory 实测非空 7624 个),绝对值恒 > 0 ⇒ 只有**前后两次之差**才等于"别的格被清掉几个"。
func _solid_outside(cell: Vector2i) -> int:
	var n := 0
	var sub_rows: int = _host.destructible_sub.size()
	var sub_cols: int = _host.destructible_sub[0].size()
	for y in range(sub_rows):
		for x in range(sub_cols):
			if _host.destructible_sub[y][x] != MazeGenerator.EMPTY \
					and Vector2i(x / 4, y / 4) != cell:
				n += 1
	return n


# 相③ 选点用:该格 16 个子格是否"纹理非 0 + 爆炸可破坏 + `sub_alive`"。
# ★ 三条缺一不可:纹理 0/不可爆 ⇒ `damage_tile` 首行 return(真路径根本不跑);`sub_alive` 假
#   ⇒ 那格本来就死了,`sub_hp` 那条断言会退化成恒真。
func _cell_pristine_destroyable(cell: Vector2i) -> bool:
	for sy in range(4):
		for sx in range(4):
			var sub := Vector2i(cell.x * 4 + sx, cell.y * 4 + sy)
			var tex: int = TileDefs.sub_texture(sub)
			if tex == 0 or not TileDefs.explosion_destroyable(tex) or not TileDefs.sub_alive(sub):
				return false
	return true


# 相③ 用:该格 16 子格里 `sub_alive` 的个数(**碰撞的真相源**,见 collision_builder.gd:49)。
func _alive_count(cell: Vector2i) -> int:
	var n := 0
	for sy in range(4):
		for sx in range(4):
			if TileDefs.sub_alive(Vector2i(cell.x * 4 + sx, cell.y * 4 + sy)):
				n += 1
	return n


# 相③ 用:该格 16 子格在**服务器可破坏层碰撞数组**里非空的个数。
func _solid_count(cell: Vector2i) -> int:
	var n := 0
	for sy in range(4):
		for sx in range(4):
			if _host.destructible_sub[cell.y * 4 + sy][cell.x * 4 + sx] != MazeGenerator.EMPTY:
				n += 1
	return n


func _ready() -> void:
	_host = MatchHost.new(MAP, {}, {}, [])
	add_child(_host)
	# ★ 关掉宿主自己的物理帧:本探针手工摆 `grid`,不需要它自跑(不关的话 `quit(0)` 是帧末生效,
	#   中间还会跑一帧 `_physics_process` 去读桩对象 → 在断言全过之后刷一屏 SCRIPT ERROR)。
	_host.set_physics_process(false)
	_run()
	_finish()


func _run() -> void:
	var rows: int = _host.grid.size()
	var cols: int = _host.grid[0].size()
	_check(rows > 0 and cols > 0, "宿主建局后有网格(%d×%d)" % [rows, cols])

	# ── ① 未动过 → 空数组 ──
	_check(_host.destroyed_cells().is_empty(), "刚建局的网格差异应为空")

	# ── ② 拆 3 格 → 恰好 3 个,且**顺序确定**(按 y 升序、同 y 按 x 升序)──
	# 故意逆序拆,看返回是否仍按序。
	# ★ 三格必须**保证**在基线里是实心,否则"把空气改成空气"= 零差异,这条断言恒红
	#   (实测:newfactory 的 100×150 网格顶部几行是空气,原样写这三格就是 0 个差异)。
	#   故先在本探针里把基线那三格钉成实心 —— 场景不依赖具体地图内容。
	#   挑 (7,5)/(1,5) 同行(验"同 y 按 x 升序")+ (3,2) 另一行(验"按 y 升序")。
	for c in [Vector2i(7, 5), Vector2i(3, 2), Vector2i(1, 5)]:
		_host._base_grid[c.y][c.x] = MazeGenerator.SOLID
	_host.grid[5][7] = MazeGenerator.EMPTY
	_host.grid[2][3] = MazeGenerator.EMPTY
	_host.grid[5][1] = MazeGenerator.EMPTY
	var d: Array = _host.destroyed_cells()
	_check(d.size() == 3, "拆 3 格应报 3 个(实际 %d)" % d.size())
	# ★ 括号是必需的:`d == [...] as Array` 会被解析成 `(d == [...]) as Array` → 编译期
	#   "Invalid cast. Cannot convert from bool to Array"(整个探针脚本加载失败,连红都跑不出来)。
	# ★ 期望值按 **(y 升序、同 y 按 x 升序)** 写:(3,2) 在 y=2 独行 → 最前;y=5 那行按 x 升序是
	#   (1,5)、(7,5)。别写成按 x 升序的 `[(1,5),(3,2),(7,5)]` —— 那是 x-major,与本方法
	#   (外围 y、内层 x 的双层循环)和契约文字都不符。
	_check(d == ([Vector2i(3, 2), Vector2i(1, 5), Vector2i(7, 5)] as Array),
			"★ 顺序必须是「按 y 升序、同 y 按 x 升序」(实际 %s)" % str(d))

	# ── ③ 走**真破坏路径**(worker 用的那条) → 该格 16 子格全清,且**别的格一格没动** ──
	# ★ 与本任务 brief 的片段有**必要偏离**(全部实测;照抄那份连红都跑不出来):
	#   ① `rows`/`cols` 在本函数顶部(:59-60)已声明 ⇒ 照抄直接 `Parse Error: There is already
	#      a variable named "rows"`,整个探针**加载失败**(不是"红",是根本没跑)。
	#   ② 选点必须落在**真地图里整格可爆的砖**上。brief 写死 (9,6) 并只钉 `_host.grid`:
	#      地图那格是空气 ⇒ `damage_tile` 首行 return、回调根本不跑 ⇒ "16 子格全清"**恒真**;
	#      而 `sub_hp` 是 `init_sub_hp(current_subgrid)` 建的(`match_host.gd:52`),只钉 `grid`
	#      不会让那 16 格"活着" ⇒ 下面那条 `sub_alive` 断言也会**恒真**(本仓最忌的假绿)。
	#      ⇒ 改为**扫子格表**找一格"16 子格全活 + 全可爆",并要求 `cell.x/y ≥ 2`(让 `* 2` 的
	#      越界写法落在**别的格**上,反向断言才不退化)。
	#   ③ `destructible_sub` 是**整图**的可破坏子格表(实测非空 **7624** 个)⇒ "别的格一格没动"
	#      只能读**前后差**,不能读"全图非空数 == 0"(照抄实测恒红 7624,Step 4 永远到不了绿)。
	var cell := Vector2i(-1, -1)
	for cy in range(MazeGenerator.current_subgrid.size()):
		for cx in range((MazeGenerator.current_subgrid[0] as Array).size()):
			var cc := Vector2i(cx / 4, cy / 4)
			if cc.x < 2 or cc.y < 2:
				continue
			if _cell_pristine_destroyable(cc):
				cell = cc
				break
		if cell.x >= 0:
			break
	if cell.x < 0:
		# 早退:下面每一句都依赖"有这么一格",前置不成立时继续跑只会刷假绿。
		# ★ 置 `_ran_to_end` 再 return:`_finish` 的假绿守卫若触发会打成"`_run()` 没跑完(中途
		#   脚本错误?)" —— 那不是实情,实情就是下面这条失败。
		_check(false, "相③ 前置不成立:图上没有「整格 16 子格全活且全可爆」的砖")
		_ran_to_end = true
		return
	# ★ 前置:那 16 格**销毁前确实活着**。不写这条,选点一失效下面就退化成恒真。
	var alive_before := _alive_count(cell)
	_check(alive_before == 16, "相③ 前置:格 %s 销毁前 16 子格应全活(实得 %d)" % [str(cell), alive_before])
	# ★ 前置:`destructible_sub`(服务器**可破坏层碰撞数组**)在该格也该是满的 ——
	#   下面 `left == 0` 只有"本来有 16"才说明得了事。
	var solid_before := _solid_count(cell)
	_check(solid_before == 16, "相③ 前置:格 %s 在可破坏层应是实心 %d/16" % [str(cell), solid_before])
	# ★ 基线同步:真路径会把 `grid` 那格清零,`_base_grid` 留着原值就会给相④/⑤ 添一个假差异
	#   (方向与 brief 那句 `_base_grid[cell] = SOLID` 相反 —— 那句实测让相④ `3 != 2` 变红)。
	_host._base_grid[cell.y][cell.x] = MazeGenerator.EMPTY
	# ★ 变异判据的**前置**:`* 2` 的越界写法会去清格 (cell.x/2, cell.y/2) 的 sx∈{2,3}×sy∈{0,1}
	#   象限 —— 那 4 个子格必须**先钉实**,否则越界写的是"把空气写成空气",变异跑不红。
	var bug_cell := Vector2i(cell.x / 2, cell.y / 2)
	for sy in range(2):
		for sx in range(2):
			_host.destructible_sub[bug_cell.y * 4 + sy][bug_cell.x * 4 + 2 + sx] = MazeGenerator.SOLID
	var others_before := _solid_outside(cell)
	MatchState.test_destroy_cell = cell
	MatchState.test_destroy_after = 0.0
	_host._debug_destroy_tile(0.0)
	var left := 0
	for sy in range(4):
		for sx in range(4):
			if _host.destructible_sub[cell.y * 4 + sy][cell.x * 4 + sx] != MazeGenerator.EMPTY:
				left += 1
	_check(left == 0, "格 %s 的 16 子格应被清光(残留 %d)" % [str(cell), left])
	# ★ 反向断言:2×2 的越界写法会去清**别的格** ⇒ 这里是唯一能抓住"清到别处"的判据。
	var others := others_before - _solid_outside(cell)   # 被清掉的、属于**别的格**的子格数
	_check(others == 0, "不该有别的格被清(实际 %d 个子格)" % others)
	# ★★ 碰撞那一维(评审 Important):服务器碰撞的真相源是 **`sub_hp`**,不是上面那个数组 ——
	#   `CollisionBuilder.build_sub` 按 `sub_alive` 决定子格有没有碰撞(`collision_builder.gd:49`),
	#   而 `WorldBuilder.build_sim` 在**下一局复位**时重算它(`match_round.gd:161`)⇒ 只清
	#   `destructible_sub`、不清 `sub_hp` 的话,那 16 格"还活着"的记录会让墙在复位时**长回来**。
	#   ★ 去掉 `_on_tile_destroyed` 里那句 `TileDefs.zero_cell_sub_hp(cell)` ⇒ 这条必红。
	var alive_after := _alive_count(cell)
	_check(alive_after == 0, "格 %s 的 16 子格应记为已死(sub_hp;残留 %d)" % [str(cell), alive_after])

	# ── ④ 反向:只改回一格 → 只剩 2 个(证明它比的是**差异**不是"非实心")──
	_host.grid[2][3] = _host._base_grid[2][3]
	_check(_host.destroyed_cells().size() == 2, "改回一格后应剩 2 个")

	# ── ⑤ 反向:凭空**加**一格实心(基线是空的地方填实心)也要报 ──
	# ★ 不能只比"当前是不是 EMPTY" —— 服务器理论上不会加砖,但契约是"与基线不同",
	#   写成"当前为空"会在将来加砖时静默漏报。
	var ey := -1
	var ex := -1
	for y in range(rows):
		for x in range(cols):
			if int(_host._base_grid[y][x]) == MazeGenerator.EMPTY and int(_host.grid[y][x]) == MazeGenerator.EMPTY:
				ey = y
				ex = x
				break
		if ey >= 0:
			break
	# ★ 2026-10-02:原先这里是一条恒真的 `_check(ey >= 0, …)`(任何有效地图都有空气格)。
	#   按"说不出真实变异就删"的判据它不该占一条断言 ⇒ 改成**早退报错**:既不占断言数,
	#   又不让下面那条在"前置不成立"时被**静默跳过**(那正是本仓反复在删的形状)。
	if ey < 0:
		_fails.append("地图里找不到基线为空的位置(前置不成立 ⇒ 下面那条无从判)")
		print("  FAIL 地图里找不到基线为空的位置(前置不成立 ⇒ 下面那条无从判)")
	else:
		_host.grid[ey][ex] = MazeGenerator.SOLID
		var d4: Array = _host.destroyed_cells()
		_check(d4.has(Vector2i(ex, ey)), "★ 与基线不同就该报(不管变空还是变实心)(实际 %s)" % str(d4))
		_host.grid[ey][ex] = MazeGenerator.EMPTY

	# ── ⑥ 每局复位:服务器侧**两套表一起**回基线(与客户端对偶) ──
	# ★ 为什么排在**最后**:复位把 `grid` 整份换成 `_base_grid` 的副本(`match_round.gd:147-149`)
	#   ⇒ 相② 造的差异会被一并抹掉,插在相④/⑤ 之前会当场把它们打成红。
	# ★ 为什么调**真复位函数**而不是"照抄那几行":照抄等于喂我自己写的输入,不构成对生产函数的
	#   验证(那样这一相只能证明"我抄的这几行是对的")。夹具安全性实测:`role_peers` 传空 ⇒
	#   `_reset_ground_weapons()` 的玩家循环零次;物理帧已在 `_ready` 关掉,复位不读物理。
	#   代价只是输出多一行 `[CollisionBuilder] … shapes:`(整层重建的正常日志)。
	# ★ 去掉 `match_round.gd` 复位里那句 `TileDefs.init_sub_hp(...)` ⇒ 下面两条**都会**红
	#   (实测:sub_alive 0/16、可破坏层实心 0/16 —— 两端因此分家:客户端还了、服务器没还)。
	_host._reset_world_and_clear_dynamics()
	var alive_reset := _alive_count(cell)
	_check(alive_reset == 16, "复位后格 %s 的 16 子格应回满血(sub_hp;实得 %d)" % [str(cell), alive_reset])
	var solid_reset := _solid_count(cell)
	_check(solid_reset == 16, "复位后格 %s 在可破坏层应回实心(实得 %d/16)" % [str(cell), solid_reset])

	_ran_to_end = true   # ← 只有走到这里才算"跑完"(见 _finish 的假绿守卫)


func _finish() -> void:
	if not _ran_to_end:
		print("DESTROYED CELLS: FAIL")
		print("  - _run() 没跑完(中途脚本错误?)—— 无失败项的 `ALL-OK` 在这情况下是假绿")
		get_tree().quit(1)
		return
	if _fails.is_empty():
		print("DESTROYED CELLS: ALL-OK")
		get_tree().quit(0)
	else:
		print("DESTROYED CELLS: FAIL")
		for f in _fails:
			print("  - %s" % f)
		get_tree().quit(1)
