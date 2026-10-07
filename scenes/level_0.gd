class_name Level0
extends Node2D

# 运行时破坏支持:瓦片被破坏(变空气)后,由 TileDefs.damage_tile 回调刷新瓦片层 + 重建碰撞。
static var wall_layer: TileMapLayer = null
static var water_layer: TileMapLayer = null
static var surface_texture: Texture2D = null
static var water_surface_layer: Node2D = null
static var _grid_ref: Array[Array] = []
# 建图时的原始(未破坏)网格深拷贝:每局复位用它重铺瓦片/碰撞(不被运行时 damage_tile 污染)。
static var _pristine_grid: Array[Array] = []
static var _pristine_subgrid: Array[Array] = []   # cyrm v4:子格纹理表基线(复位/回溯用)
# 持久化可破坏层 32px 子格(250×150):摧毁时只清该格 2×2,下帧只重建所在分块。
static var _destructible_sub: Array[Array] = []
# 本帧被摧毁砖所在的分块(Vector2i → true);_process 里逐块重建后清空。
static var _dirty_chunks: Dictionary = {}

# PvP 模式:只建世界(地图/瓦片/碰撞/水),玩家/敌人/相机/后处理由 PvP 场景负责。
static var pvp_mode: bool = false

# ── 安全场景切换:游戏世界(全量碰撞)从场景树中移除后**分帧拆除** ──
# change_scene_to_file 会在切换时同步 memdelete 当前场景;单机/PvP 游戏世界含几千节点 +
# 庞大的 SubViewport,一次性同步析构偶发原生段错误(实测死亡后回菜单/按 R 重载都会触发)。
# 做法:新场景手动实例化并接管 current_scene,旧世界从场景树中移除,再交给**分帧拆除器**(见 start_reap)
# 在后续几秒里一小批一小批拆掉 —— 既躲开"一帧里同步 memdelete 整具世界",又不像以前那样
# **永不释放**(那会让退出时渲染器析构段错误,见 safe_change_scene 里那段注释)。
# 注意:从场景树中移除必须回到帧末进行,故本函数先 await 一帧(见函数内注释)。

# 场景切换过渡中标志：防止同帧或相近帧重复进入切换逻辑。
# 本函数首行 await 一帧,故两次调用可以同时在飞。第二次 resume 时 `old = tree.current_scene`
# 拿到的已是**第一次刚建出来的新场景** → 于是再实例化一份、把第一份也挂进拆除队列
# (建出两份场景、菜单叠菜单)。触发很现实:PvP 的「对手离开」2.5s 定时器与玩家点「回到主菜单」
# 可以先后落在同一帧附近。
# - 守卫放在**这个统一集中处理点**而非各调用点:调用点每新增一条退出路径就要记得补一次守卫,漏一条
# 就复现 —— 与「拆除逻辑散在多处」同病。此处一处覆盖全部现有与将来的调用方。
static var _switching: bool = false

## 怀表时间系统账户与时间场(单机;PvP 不建 → 时间系统整体旁路)
static var grain_account: GrainAccount = null
static var time_field: TimeField = null
var _rewind: WorldRewind = null   # 世界快照/回放(单机;PvP 不建)
var _prev_time_mode: int = 0      # 上一帧时间场模式(判回溯进入/退出)
var _post_process: PostProcess = null
var _tile_ledger: TileLedger = null      # 玩家破坏瓦片账本(瓦片回溯)
var _tile_pending: Array = []            # 本帧待入账的格(帧末合并)
var _tile_cursor: float = -1.0           # 本次回溯的瓦片还原高水位
var _film_t: float = 0.0          # 回溯底片化强度(get 平滑 ramp,≤200ms)
var _haste_t: float = 0.0         # 加速视效强度(ramp 100ms)
# 时间状态高亮(B13):加色副本(见 scenes/effects/time_glow.gd),实体 → TimeGlow
var _glows: Dictionary = {}


static func safe_change_scene(tree: SceneTree, path: String) -> void:
	if _switching:
		return   # 已有正在进行的场景切换：忽略后续并发请求（目标均为同一菜单，保留最先发起者）
	_switching = true
	# 先回到帧末再动树:调用方(按钮按下/R 重载的输入处理)可能正处于旧场景节点发出的
	# 信号调用栈里,立刻从场景树中移除会触发 CanvasItem EXIT_TREE 状态错误(headless 实测)。
	await tree.process_frame
	var t0 := Time.get_ticks_usec()
	var t := t0
	var old: Node = tree.current_scene
	var next: Node = load(path).instantiate()
	t = _perf_log("load+instantiate", t)
	tree.root.add_child(next)      # 新场景 _ready 先跑(旧世界仍在树上,静态引用完好)
	t = _perf_log("add_child(next)", t)
	tree.current_scene = next      # 接管 current_scene 指针,旧场景不再被 change 流程释放
	if old != null and old != next:
		if OS.get_cmdline_user_args().has("--perf-teardown-detail"):
			# 诊断模式:不退役,改成逐子树拆开计时。-  破坏性 —— 整具世界就此拆光,故走完
			# 这条路就**没有旧世界可退役**了(只给单跑一次的诊断用)。
			_teardown_detail(tree, old)
			_perf_log("总计", t0)
			_switching = false
			return
		tree.root.remove_child(old)
		t = _perf_log("remove_child(old)", t)
		old.visible = false
		# 注意： 2026-09-15(导出 exe 实测):**不再把旧世界挂起**。
		#   原先从场景树中移除后存进 `_retired`、挂到"下一次换场"才释放,于是:
		#     - **退出时那具挂起的世界从不释放** → SubViewport 的 RID 全泄漏(实测 6264 个
		#       CanvasItem + 3 个 shader 未释放)→ 渲染器析构**段错误**(exit 139),
		#       进程要拖 ~1.5s 才死。用户报的"玩好一局后点退出/叉号要等 1s"就是这条。
		#     - 第 2 次及以后换场还要同步 free 一整具世界(实测 79.5ms,见下)。
		#   现在:从场景树中移除后**立刻**交给分帧拆除器,几秒内拆干净 —— 用户真去点退出时它早没了。
		#   对照实测(导出 exe):不进游戏的流程退出码 0、零泄漏;进过游戏的是 139。
		#
		# `--perf-reap-sync` 保留旧行为(同步 free),只给 A/B 对照用:本机负载漂移能让
		# 同一段代码的 remove_child 在 20~100ms 之间跳,跨轮比较不可信,只有同进程交替才量得准。
		if OS.get_cmdline_user_args().has("--perf-reap-sync"):
			old.free()
			t = _perf_log("free() 同步(对照)", t)
		else:
			start_reap(tree, old)
			t = _perf_log("start_reap(旧世界)", t)
	_perf_log("总计", t0)
	_switching = false   # 换场完成:放行后续换场(回菜单→再进游戏→再回菜单是一串合法调用)

# ── 退役世界的分帧拆除器 ──
# 背景(实测,`--autotest-switch` 两趟单机往返):
#   第 1 次退出: load 2.21 / add_child 13.06 / remove_child 31.86 / 总计  53.90 ms
#   第 2 次退出: load 3.21 / add_child 14.68 / remove_child 21.72 / free 79.54 / 总计 133.28 ms
# 第 2 次是第 1 次的 2.5 倍 —— 「有些时候才卡」就是这一笔(第 1 次 _retired 还是空)。
# 做法:那笔同步 free 改为**摊到后续帧**。菜单已上屏、旧世界已从场景树中移除,分帧拆它谁也看不见。
#
# 拆除顺序 = **逆前序**:一次性收集整棵子树的前序列表,然后**从尾往前** free。
# 前序保证「祖先先于后代被访问」 ->  逆序即「后代先于祖先被释放」 ->  每个父节点轮到时子节点
# 早已拆光。这很重要:大容器本来是一锤子买卖(4000 个 CollisionShape2D 挂在同一个
# StaticBody2D 下),逆前序把它变成一个个拆,单帧峰值才压得下来。
# 预算按**时间**而非个数:节点大小差三个数量级,按个数会一会儿无效操作一会儿爆帧。
const REAP_BUDGET_US := 3000      # 每帧拆除预算(≈0.18 帧 @60fps)
static var _reap_queue: Array[Node] = []
static var _reaper_driver: Node = null
# 诊断计数(只在 --perf-switch 下打印):拆了多少节点、摊了多少帧。
static var _reap_nodes := 0
static var _reap_frames := 0
static var _reap_us := 0

# 驱动者:挂在 root 上的小节点,随场景切换存活;队列拆空即自毁。
# - 不写 _exit_tree 保底处理:半途被拆(退出游戏)时宁可漏掉残余,也不要在树清理期间回头 free
#   一批已从场景树中移除的节点 —— 那正是本函数要躲开的那类同步销毁。
class _Reaper extends Node:
	func _ready() -> void:
		# 换场可能发生在暂停中(暂停菜单点「回到主菜单」),拆除不该被暂停卡住
		process_mode = Node.PROCESS_MODE_ALWAYS
		# - 显式开 _process:别指望"脚本定义了 _process 就自动启用" —— 本节点是**内部类**
		#   实例,自动启用走的是脚本方法探测那条路,不显式开就可能一帧都不进
		#   (实测:不开时拆除器全程零调用,残余只能靠下次换场的 finish_reap 同步保底处理)。
		set_process(true)

	func _process(_delta: float) -> void:
		if Level0.reap_step():
			queue_free()

	func _exit_tree() -> void:
		if Level0._reaper_driver == self:
			Level0._reaper_driver = null

# 把一具退役世界交给分帧拆除器。上一具若还没拆完,先就地拆掉(通常已近空壳,代价很小)。
static func start_reap(tree: SceneTree, world: Node) -> void:
	if world == null or not is_instance_valid(world):
		return
	# - 追加而不是"清空重来":上一具可能还没拆完(用户在菜单里只待了一小会儿就又进游戏)。
	#   两棵树混在一个队列里也拆不错 —— 队列按逆前序消费,每个节点只属于一棵树。
	var t0 := Time.get_ticks_usec()
	_collect_preorder(world, _reap_queue)
	_reap_nodes = _reap_queue.size()
	_reap_frames = 0
	_reap_us = Time.get_ticks_usec() - t0
	# 驱动者还活着就复用(它与拆除队列都是全局的,不需要第二个);已排队待删的另起一个 ——
	# 不能只判 != null:它可能刚判空、正等帧末销毁,复用会让新队列没人拆。
	if _reaper_driver == null or not is_instance_valid(_reaper_driver) \
			or _reaper_driver.is_queued_for_deletion():
		_reaper_driver = _Reaper.new()
		_reaper_driver.name = "WorldReaper"
		tree.root.add_child(_reaper_driver)

# 推进一步。返回 true = 队列已空(驱动者据此自毁)。
static func reap_step() -> bool:
	var deadline := Time.get_ticks_usec() + REAP_BUDGET_US
	while not _reap_queue.is_empty() and Time.get_ticks_usec() < deadline:
		var n: Node = _reap_queue.pop_back()
		if is_instance_valid(n):
			n.free()
	_reap_frames += 1
	if _reap_queue.is_empty():
		if OS.get_cmdline_user_args().has("--perf-switch"):
			print("[perf-switch] reap 完成              %d 节点 / %d 帧 / 收集 %.2f ms" % [
					_reap_nodes, _reap_frames, float(_reap_us) / 1000.0])
		return true
	return false

# 就地拆完剩余(下一次换场接手时保底处理)。
static func finish_reap() -> void:
	for n in _reap_queue:
		if is_instance_valid(n):
			n.free()
	_reap_queue.clear()

# 诊断(只给 `--perf-teardown-detail` 用):把旧世界**逐个子树**拆下来计时,
# 回答"remove_child 那几十毫秒到底花在谁身上"。-  这个模式是**破坏性**的 —— 子树当场 free、
# 世界不再退役,故只能单次诊断用,别在日常流程里开。
static func _teardown_detail(tree: SceneTree, old: Node) -> void:
	var total := Time.get_ticks_usec()
	var kids := old.get_children()
	print("[perf-switch] 旧世界 %d 个顶层子节点(逐个 free 计时):" % kids.size())
	for c in kids:
		# - 名字/类名必须在 free **之前**取:c.free() 之后 c 已失效,再读 c.name 是
		#   use-after-free(实测:整行 print 直接不出现,只留下表头)。
		var nm := str(c.name)
		var cls := c.get_class()
		var s := Time.get_ticks_usec()
		c.free()
		var e := Time.get_ticks_usec()
		print("[perf-switch]   %-22s %-14s %8.2f ms" % [nm, cls, float(e - s) / 1000.0])
	var s2 := Time.get_ticks_usec()
	if old.is_inside_tree():
		tree.root.remove_child(old)
	old.free()
	var husk := float(Time.get_ticks_usec() - s2) / 1000.0
	print("[perf-switch]   空壳 remove+free               %8.2f ms;整具合计 %.2f ms" % [
			husk, float(Time.get_ticks_usec() - total) / 1000.0])


static func _collect_preorder(n: Node, out: Array[Node]) -> void:
	out.append(n)
	for c in n.get_children():
		_collect_preorder(c, out)

# ── 换场耗时打点(**诊断用,默认静默**)──
# 打开方式:`--perf-switch`(与 `--worker` 同规,开关必须落在 `- ` 之后,
# 见 OS.get_cmdline_user_args())。打一次换场就在 stdout 打四行。
# 配套 `tests/smoke/menu_autotest.gd` 的 `--autotest-switch`(两趟往返,把第 2 次退出也走到)。
static func _perf_log(label: String, t0: int) -> int:
	var now := Time.get_ticks_usec()
	if OS.get_cmdline_user_args().has("--perf-switch"):
		print("[perf-switch] %-20s %8.2f ms" % [label, float(now - t0) / 1000.0])
	return now

# 根 Window 的输入事件不会自动路由进 SubViewport（WorldViewport），
# 所以 SubViewport 内节点（玩家/枪）的 _unhandled_input 收不到。
# 在根级把未处理输入手动转发进 WorldViewport。
func _unhandled_input(event: InputEvent) -> void:
	$WorldViewport.push_input(event)

func _ready() -> void:
	# 清屏色 = 世界的"空气"色。-  单一来源放在 TerrainAtlas:主菜单背景的底色也读同一个
	# 常量(用户 2026-10-03:"菜单背景颜色要和局内一致"),两处不许各写一份。
	RenderingServer.set_default_clear_color(TerrainAtlas.SKY_COLOR)
	CombatFeedback.spawn(self)

	# 临时：从固定地图文件加载（随机生成已注释，两者之后一起删除）
	var grid := WorldBuilder.load_grid()
	if grid.is_empty():
		push_error("Level0: 地图加载失败，跳过建图")
		return
	_grid_ref = grid
	_pristine_grid = MazeGenerator.copy_grid(grid)
	_pristine_subgrid = []   # _ready 里随 current_subgrid 一起存基线
	Level0.wall_layer = $WorldViewport/WallLayer
	TileDefs.on_sub_destroyed = Callable(self, "_on_sub_destroyed")
	TileDefs.init_hp(grid)
	TileDefs.init_sub_hp(MazeGenerator.current_subgrid)
	_pristine_subgrid = MazeGenerator.copy_grid(MazeGenerator.current_subgrid)

	var tile_set = _create_wall_tileset()
	var wl: TileMapLayer = $WorldViewport/WallLayer
	wl.tile_set = tile_set
	_paint_maze(wl)
	Level0.water_layer = $WorldViewport/WaterLayer
	Level0.water_surface_layer = $WorldViewport/WaterSurfaceLayer
	Level0.water_layer.tile_set = _create_water_tileset()
	_paint_water(grid)


	_build_wall_collision.call_deferred(grid)
	if pvp_mode:
		return  # 世界已建;敌人/单玩家放置/后处理交给 PvP 场景
	EnemySpawner.load_types()
	var spawns := MazeGenerator.load_spawns()
	_place_player(grid, spawns.get("player", Vector2i(-1, -1)))
	$WorldViewport/Player.weapons.set_enabled_types(RunOptions.disabled_weapons)   # 开局选项:禁用武器槽生效
	# 怀表时间系统(第一阶段):单机建账户与世界时间场(PvP 不建 → TimeField.current 为 null,倍率恒 1)
	grain_account = GrainAccount.new()
	time_field = TimeField.new(grain_account)
	TimeField.current = time_field
	_rewind = WorldRewind.new($WorldViewport)
	_tile_ledger = TileLedger.new()
	# 透支锁定:怀表红闪提示(表针锁定期间两键都取不出颗粒)
	grain_account.loan_locked.connect(func() -> void:
		var w = get_tree().get_first_node_in_group("watch_hud")
		if w != null and w.has_method("flash_locked"):
			w.flash_locked())
	_give_starting_weapon($WorldViewport/Player)
	$EnemySpawner.spawn_all.call_deferred(spawns)
	# 单机初始武器:每种 2 把、共 12 把,随机散落全图;玩家开局**空手**(见 player.gd)。
	# - `deferred`:scatter_weapons 要读 MazeGenerator.current_grid,延迟到帧末避半初始化状态。
	scatter_weapons.call_deferred(_default_weapon_types())

	var pp := PostProcess.new()
	pp.world_viewport = $WorldViewport
	_post_process = pp
	call_deferred("add_child", pp)
	_build_pause_menu()


# 墙体/所有非空气砖的图集(16px 象限制)。构造已上提到 TerrainAtlas —— 主菜单背景
# 要"真实的那个世界",必须与这里用**同一份**映射(见 terrain_atlas.gd 文件头)。
func _create_wall_tileset() -> TileSet:
	return TerrainAtlas.make_wall_tileset()


# 水体专用 64px 图集(B18 把墙体图集改成 16px 象限制后,_paint_water 的"形状列×纹理行"
# 老格式没了着落:水体被按 16px 坐标压缩画错位,真水体看不见,还在地图 1/4 坐标处散布
# 一堆无碰撞的"幽灵方块")。水不可破坏,永远按 64px 整格渲染——按 B18 之前的老构建
# 逻辑原样重建,仅供 water_layer 使用。构造同样收在 TerrainAtlas。
func _create_water_tileset() -> TileSet:
	var ts := GameParameters.TILE_SIZE
	# 水面合批 shader 的采样源(= 水体纹理放大到 ts×ts)
	Level0.surface_texture = ImageTexture.create_from_image(TerrainAtlas.water_brick_image(ts))
	return TerrainAtlas.make_water_tileset(ts)


func _paint_maze(layer: TileMapLayer) -> void:
	# cyrm v4:铺 **16px 子格**(MazeGenerator.current_subgrid;纹理 0 = 空气跳过,
	# 液体由 _paint_water 分层铺)。瓦片坐标 = (象限 qy*4+qx, 纹理-1)。
	var source_id = 0
	var sc = MazeGenerator.current_subgrid[0].size()
	var sr = MazeGenerator.current_subgrid.size()
	for ty in range(-1, 2):
		for tx in range(-1, 2):
			var offset_x = tx * sc
			var offset_y = ty * sr
			for y in range(sr):
				var row: Array = MazeGenerator.current_subgrid[y]
				for x in range(sc):
					var tex: int = row[x]
					if tex == MazeGenerator.EMPTY or Water.is_liquid(tex):
						continue
					layer.set_cell(Vector2i(x + offset_x, y + offset_y), source_id,
							Vector2i((y % 4) * 4 + (x % 4), tex - 1))


# 水格铺图:水体格铺水体瓦片(纹理 21,水体专用 64px 图集的 atlas 行 0);水面格(上方非 liquid)只放 Sprite 亮线,不铺瓦片(避免双层半透明叠加变深)。
func _paint_water(grid: Array[Array]) -> void:
	const BODY_ROW := 0   # 水体专用图集只有一行(纹理 21)
	var ts := GameParameters.TILE_SIZE
	var cols := grid[0].size()
	var rows := grid.size()
	var wl: TileMapLayer = Level0.water_layer
	var surf: Node2D = Level0.water_surface_layer
	var surface_cells: Array = []
	for ty in range(-1, 2):
		for tx in range(-1, 2):
			var ox := tx * cols
			var oy := ty * rows
			for y in range(rows):
				var row: Array = grid[y]
				for x in range(cols):
					var v: int = row[x]
					if v == MazeGenerator.EMPTY:
						continue
					if not Water.is_liquid(MazeGenerator.texture_of(v)):
						continue
					var above: int = grid[posmod(y - 1, rows)][x]
					var is_surface := above == 0 or not Water.is_liquid(MazeGenerator.texture_of(above))
					if is_surface:
						# 收集水面格,合批成一个 canvas item(替代 N 个 Sprite,省 draw call,画面不变)
						surface_cells.append({
							"pos": Vector2((x + ox) * ts + ts * 0.5, (y + oy) * ts + ts),
							"phase": (x + ox) * 1.7 + (y + oy) * 2.3,
						})
					else:
						wl.set_cell(Vector2i(x + ox, y + oy), 0,
							Vector2i(MazeGenerator.shape_of(v), BODY_ROW))


	# 合批:一个 canvas item 画所有水面格(替代 N 个 Sprite,省 draw call,画面不变)
	if not surface_cells.is_empty():
		var batch := WaterSurfaceBatch.new()
		batch.setup(surface_cells, Level0.surface_texture, ts)
		surf.call_deferred("add_child", batch)


func _process(_delta: float) -> void:
	# 时间场驱动(单机;先于实体各自的物理帧让模式生效——实体在 _physics_process 里查询)
	if time_field != null and not pvp_mode:
		_drive_time(_delta, Input.is_action_pressed("rewind"), Input.is_action_pressed("haste"))
		_tick_rewind(_delta)
		_tick_time_visuals(_delta)
	_update_pickup_prompt()
	if not _dirty_chunks.is_empty():
		# 分帧重建:每帧最多重建 2 块,爆炸同时毁多块时摊到多帧,避免 CPU 尖峰
		const MAX_REBUILD_PER_FRAME := 2
		var processed := 0
		var chunks := _dirty_chunks.keys()
		_dirty_chunks.clear()
		for ch in chunks:
			if processed >= MAX_REBUILD_PER_FRAME:
				_dirty_chunks[ch] = true  # 放回下帧继续
				continue
			CollisionBuilder.rebuild_chunk(_destructible_sub, ch, $WorldViewport)
			processed += 1


# 瓦片被破坏(变空气):清掉 3×3 环面副本对应格 + 持久子格该格 2×2,标记所在块下帧重建。
## 单格写回(瓦片回溯用):网格 + 9 环面副本渲染 + 持久子格 2×2 + 脏块重建标记。
## 回溯期子弹对精英的二次伤害(策划案:「回退造成二次伤害」)——
## 回溯中普通实体冻结/由快照摆位,唯有精英照常存在;倒飞的子弹再次穿过它就再吃一次伤害。
func _rewind_elite_hits() -> void:
	if _rewind == null:
		return
	var elites: Array = []
	for e in get_tree().get_nodes_in_group("enemies"):
		if is_instance_valid(e) and e.has_meta("elite") and not bool(e.get("is_dead")):
			elites.append(e)
	if elites.is_empty():
		return
	for b in _rewind.replay_bullets():
		if not is_instance_valid(b):
			continue
		var dmg := int(b.get("hit_damage"))
		if dmg <= 0:
			continue
		var bp: Vector2 = (b as Node2D).global_position
		for e in elites:
			var ep: Vector2 = (e as Node2D).global_position
			var d := MazeGenerator.toroidal_delta_px(bp, ep,
					GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
			if d.length() > 42.0:
				continue
			var hit_ids: Array = b.get_meta("rw_hit_ids", [])
			if hit_ids.has(e.get_instance_id()):
				continue
			hit_ids.append(e.get_instance_id())
			b.set_meta("rw_hit_ids", hit_ids)
			var dir := d.normalized() if not d.is_zero_approx() else Vector2.RIGHT
			e.call("hurt", dmg, dir, float(b.get("hit_impact")))


func _restore_sub(e: Dictionary) -> void:
	# 回溯还原一个 16px 子格:HP 写回 + 重铺贴图 + 碰撞子格复位 + 账本时间轴照旧。
	# 所属 64px 格若已因"全子格死光"被清零,这里一并从基线恢复(格级逻辑重新看到它)。
	if _grid_ref.is_empty() or wall_layer == null or MazeGenerator.current_subgrid.is_empty():
		return
	var sub: Vector2i = e["sub"]
	var hp := int(e["hp"])
	var sc: int = MazeGenerator.current_subgrid[0].size()
	var sr: int = MazeGenerator.current_subgrid.size()
	if sub.x < 0 or sub.y < 0 or sub.x >= sc or sub.y >= sr:
		return
	TileDefs.restore_sub(sub, hp)
	var tex := int(MazeGenerator.current_subgrid[sub.y][sub.x])
	var cell := Vector2i(sub.x / 4, sub.y / 4)
	if tex == 0:
		return
	for ty in range(-1, 2):
		for tx in range(-1, 2):
			wall_layer.set_cell(Vector2i(sub.x + tx * sc, sub.y + ty * sr), 0,
					Vector2i((sub.y % 4) * 4 + (sub.x % 4), tex - 1))
	if not _destructible_sub.is_empty():
		_destructible_sub[sub.y][sub.x] = MazeGenerator.SOLID
		_dirty_chunks[CollisionBuilder.chunk_of(cell)] = true
	if _grid_ref[cell.y][cell.x] == 0 and not _pristine_grid.is_empty():
		_grid_ref[cell.y][cell.x] = _pristine_grid[cell.y][cell.x]


func _on_sub_destroyed(sub: Vector2i, pre_hp: int, _owner: Node = null) -> void:
	# cyrm v4 子格破坏:清一个 16px 渲染格(9 环面副本)+ 记回溯账本 + 重建所在碰撞块。
	# 回溯捕获(**摧毁前**的 hp 由 TileDefs 传进来;仅单机时间系统激活且非回放期)
	if _tile_ledger != null and TimeField.current != null and not TimeField.current.is_rewinding() and wall_layer != null:
		_tile_pending.append({"sub": sub, "hp": pre_hp})
	if wall_layer != null:
		var sc: int = MazeGenerator.current_subgrid[0].size()
		var sr: int = MazeGenerator.current_subgrid.size()
		for ty in range(-1, 2):
			for tx in range(-1, 2):
				wall_layer.set_cell(Vector2i(sub.x + tx * sc, sub.y + ty * sr), -1)
	if not _destructible_sub.is_empty():
		_destructible_sub[sub.y][sub.x] = MazeGenerator.EMPTY
		_dirty_chunks[CollisionBuilder.chunk_of(Vector2i(sub.x / 4, sub.y / 4))] = true


# PvP 换局复位:把可破坏砖/碰撞/瓦片全量还原成建图时的原始状态(当前网格重置为基线深拷贝)。
# 服务器每局开赛也做同样复位,双方从同一基线出发 → 不存在"客户端多拆/少拆"的幽灵墙。
# CollisionBuilder 的 build 幂等(同名节点先 free 再建),可安全整体重建。
func reset_destructibles() -> void:
	if _pristine_grid.is_empty():
		return
	var g := MazeGenerator.copy_grid(_pristine_grid)
	MazeGenerator.current_grid = g
	_grid_ref = g
	TileDefs.init_hp(g)
	# cyrm v4:子格表/子格 HP 一并回基线
	MazeGenerator.current_subgrid = MazeGenerator.copy_grid(_pristine_subgrid)
	TileDefs.init_sub_hp(MazeGenerator.current_subgrid)
	# 瓦片层整层重铺(清掉 -1 残留,恢复被破坏瓦片的贴图)
	var wl := Level0.wall_layer
	if wl != null:
		_paint_maze(wl)
	# 碰撞:可破坏分块 + 永久墙 + 攀爬条整体重建为基线
	_destructible_sub = WorldBuilder.build_sim($WorldViewport, g)


func _build_wall_collision(grid: Array[Array]) -> void:
	# 永久墙 + 可破坏分块 + 攀爬基座条,逻辑迁到 WorldBuilder.build_sim(服务器复用)
	_destructible_sub = WorldBuilder.build_sim($WorldViewport, grid)


# 单人「倒地按 R 重启」:原地复位,不重建世界。
# 旧实现走场景重载(第二份完整世界 + 退役拆旧世界),重启过程在引擎原生层偶发段错误
# (实测表象:重启后蓝屏/地图未加载)。改为在当前 Level0 内复位:可破坏砖/瓦片/碰撞回
# 基线 + 清子弹/敌人后重刷 + 玩家满血满氧回出生点,从机制上绕开「新建/拆毁大世界」。
# PvP 不走这里(服务器权威管复活)。由 player.gd 倒地 R 调用。
func restart_single() -> void:
	if _pristine_grid.is_empty() or _grid_ref.is_empty():
		return
	var player: CharacterBody2D = $WorldViewport/Player
	# 瓦片/碰撞整层还原为建图基线;顺手清掉本帧的破坏瓦片重建队列(基线已是最新)
	_dirty_chunks.clear()
	reset_destructibles()
	# 清场上动态物:子弹 + 敌人(尸体/坠落物一起清,避免与重刷的敌人并排残留)
	for b in get_tree().get_nodes_in_group("bullet"):
		if is_instance_valid(b):
			(b as Node).queue_free()
	for e in get_tree().get_nodes_in_group("enemies"):
		if is_instance_valid(e):
			(e as Node).queue_free()
	# 玩家满血满氧回出生点,姿态/武器复位
	var spawns := MazeGenerator.load_spawns()
	var spawn_cell: Vector2i = spawns.get("player", Vector2i(-1, -1))
	if spawn_cell.x < 0:
		spawn_cell = Vector2i(_grid_ref[0].size() / 2, _grid_ref.size() / 2)
	player.restart_at(spawn_cell)
	# 敌人重刷(与 _ready 相同机制;deferred 等旧敌 queue_free 先生效,避免同名冲突)
	EnemySpawner.load_types()
	$EnemySpawner.spawn_all.call_deferred(spawns)
	# - 单机按 R = **完全重开**:背包清空、地面武器重新散落。
	#   与"还原可破坏砖 + 清子弹/敌人重刷 + 玩家满血回出生点"是同一语义 ——
	#   装备也是本局的进度,重开就该从头攒。
	#   (联机不走这条路:服务器权威另有复活规则,武器只保留随机一把。)
	clear_pickups()
	_give_starting_weapon(player)
	scatter_weapons.call_deferred(_default_weapon_types())


func _place_player(_grid: Array[Array], spawn_cell: Vector2i) -> void:
	var player: CharacterBody2D = $WorldViewport/Player
	var ts: int = GameParameters.TILE_SIZE
	var pos := Vector2i(-1, -1)
	if spawn_cell.x >= 0 and spawn_cell.y >= 0:
		pos = spawn_cell
	else:
		# 地图无 # player:固定用左上第一个空格(地图唯一来源)
		for y in range(_grid.size()):
			for x in range(_grid[y].size()):
				if _grid[y][x] == MazeGenerator.EMPTY:
					pos = Vector2i(x, y)
					break
			if pos.x >= 0:
				break
		if pos.x < 0:
			push_error("No empty cells to place player!")
			return
	player.position = Vector2(pos.x * ts + ts / 2.0, pos.y * ts + ts / 2.0)

# 单机 ESC 菜单:呼出=暂停整份模拟,退出=解暂停后回主菜单。
# PauseMenu 自己管暂停与切场景(open() 里 paused=true、go_menu() 首行先解暂停再走
# Level0.safe_change_scene),故本处不需要任何信号接线。
# (PvP 菜单由 pvp_client 自建——PvP 下本方法不会被调,见 _ready 的 pvp_mode 早 return。)
func _build_pause_menu() -> void:
	add_child(PauseMenu.new(false))   # 隐藏待命,自行处理 ui_cancel


# ── 地面武器(2026-09-15,武器槽位计划)──
# 单机的权威就是本场景;联机的权威在 MatchHost(见联机计划),那边另存一份。
var ground_weapons := GroundWeaponField.new()
var _next_pickup_inst: int = 1
var _pickup_nodes: Dictionary = {}      # inst -> WeaponPickup
var _self_drop_until: Dictionary = {}   # inst -> 解禁时刻(ms),防"丢完立刻捡回"的抖动

const PICKUP_SCENE := preload("res://scenes/weapons/weapon_pickup.tscn")


# 单机开局武器:玩家**手里带一把**(用户 2026-09-15 要求「单机模式初始携带手枪」),
# 其余散落在地图上。
#
# - 必须排在 `set_enabled_types` **之后** —— 如果先给再禁,手上一旦是被禁的那把,
#   `set_enabled_types` 会判成"没有可用的"→ 空手;过滤顺序反了就直接白给。
# - 用 `default_type()`(最小**启用**槽位)而不是写死 "1":玩家禁用手枪时应当发下一把,
#   而不是发一把本局根本不让用的枪。发出来的仍是手枪,除非手枪被禁。
# - 本函数只服务单机;PvP/大乱斗的初始武器由服务器 MatchHost 自己决定(见联机计划)。
func _give_starting_weapon(p: Node) -> void:
	if p == null or p.weapons == null:
		return
	p.weapons.set_initial_inventory([int(p.weapons.default_type())])


# 单机初始武器清单:每种 2 把,跳过本局被禁的类型。
# (禁用武器不该出现在地图上 —— 与 set_enabled_types 同源:RunOptions.disabled_weapons)
# - 清单来自注册表(json 顺序 = 散落顺序)。加第 7 把枪只改 json,这里一个字不动。
func _default_weapon_types() -> Array:
	var out: Array = []
	for type_id in WeaponRegistry.all_ids():
		if not RunOptions.disabled_weapons.has(type_id):
			out.append(type_id)
			out.append(type_id)
	return out


# 生成一件地面武器。self_drop=true 表示"这是玩家刚自己丢下的",
# 会在 weapon_pickup_self_delay 内不参与**该玩家**的拾取判定。
func spawn_pickup(type_id: int, mag: int, pos: Vector2, vel: Vector2,
		inst: int = 0, self_drop: bool = false) -> WeaponPickup:
	if inst <= 0:
		inst = _next_pickup_inst
		_next_pickup_inst += 1
	else:
		_next_pickup_inst = maxi(_next_pickup_inst, inst + 1)
	var node: WeaponPickup = PICKUP_SCENE.instantiate()
	# - 顺序不能反:configure **必须在 add_child 之前** —— _ready 一加入场景树就按当时的 type_id
	#   建视觉与碰撞箱,先加入场景树的话它已经用 @export 默认值(手枪)建过一次了。
	node.configure(type_id, inst, mag, vel)
	# 注意： 必须挂进 **WorldViewport**(SubViewport),不能 add_child(self):
	#   世界(瓦片/玩家/敌人)全渲染在那个 SubViewport 里,由相机 + PostProcess 呈现。
	#   挂到 Level0 自己身上 = 在渲染树之外 —— 节点存在、有视觉、有碰撞,**但屏幕上什么都看不到**。
	#   (EnemySpawner.spawn_all 走的是同一件事:get_parent().get_node("WorldViewport"))。
	$WorldViewport.add_child(node)
	node.global_position = pos
	node.canonical_pos = pos   # 权威位置(渲染位置由锚点推出,见 WeaponPickup)
	ground_weapons.map_size = Vector2(float(GameParameters.MAP_WIDTH), float(GameParameters.MAP_HEIGHT))
	ground_weapons.add({"inst": inst, "type_id": type_id, "mag": mag, "pos": pos, "vel": vel})
	_pickup_nodes[inst] = node
	if self_drop:
		_self_drop_until[inst] = Time.get_ticks_msec() + int(PlayerParams.weapon_pickup_self_delay * 1000.0)
	return node


func remove_pickup(inst: int) -> void:
	ground_weapons.remove(inst)
	_self_drop_until.erase(inst)
	var n = _pickup_nodes.get(inst, null)
	if n != null and is_instance_valid(n):
		n.queue_free()
	_pickup_nodes.erase(inst)


func clear_pickups() -> void:
	for n in _pickup_nodes.values():
		if is_instance_valid(n):
			n.queue_free()
	_pickup_nodes.clear()
	_self_drop_until.clear()
	ground_weapons.clear()


# 把 types 里每种武器铺到全图开阔地板格上(尽量互相远离)。
func scatter_weapons(types: Array) -> void:
	clear_pickups()
	if MazeGenerator.current_grid.is_empty():
		return
	ground_weapons.map_size = Vector2(float(GameParameters.MAP_WIDTH), float(GameParameters.MAP_HEIGHT))
	var cols := int(ground_weapons.map_size.x / float(GameParameters.TILE_SIZE))
	var rows := int(ground_weapons.map_size.y / float(GameParameters.TILE_SIZE))
	var cells: Array = $EnemySpawner.open_floor_cells(MazeGenerator.current_grid)
	var want := types.size()
	var picked: Array = GridPathfinder.spread_cells(cells, want, 10, cols, rows)
	# 与 EnemySpawner 的 "spawned N enemies from map" 相同机制:布点数量要能一眼核对
	# (不足时也走这行 —— 小图/密封图有多少铺多少,不报错也不能卡住开局)。
	print("[Level0] 地面武器 %d/%d 件(开阔地板格 %d)" % [picked.size(), want, cells.size()])
	var half := float(GameParameters.TILE_SIZE) * 0.5
	for i in picked.size():
		var pos := Vector2(picked[i]) * float(GameParameters.TILE_SIZE) + Vector2(half, half)
		spawn_pickup(int(types[i]), WeaponInventory.MAG_FULL, pos, Vector2.ZERO)


# 玩家按 F 的落点:一次只捡**最近的一把**(不是"范围里能捡的全捡")——
# 这是"多把武器叠在一起捡不起来某些枪"的解法:连着按 F 就能逐把捡走。
# 见 GroundWeaponField 的类头注释。
func try_pickup_for(p: Node2D) -> void:
	if p == null or p.weapons == null:
		return
	var e: Dictionary = ground_weapons.nearest_within(
		p.global_position, PlayerParams.weapon_pickup_radius, _live_self_drops())
	if e.is_empty():
		return
	var inst := int(e["inst"])
	var dropped_type: int = p.weapons.pick_up(int(e["type_id"]), int(e["mag"]))
	if dropped_type < 0:
		return   # 被门控前置校验拒绝(禁用武器),地面那件留着
	remove_pickup(inst)
	if dropped_type > 0:
		# 放不下 → 被换下的那把掉在玩家脚下(残弹跟着枪走)
		var d: Dictionary = p.weapons.take_last_dropped()
		spawn_pickup(dropped_type, int(d.get("mag", WeaponInventory.MAG_FULL)),
			p.global_position + PlayerParams.weapon_drop_offset * Vector2(float(p.facing_direction), 1.0),
			Vector2(PlayerParams.weapon_drop_speed * p.facing_direction, -PlayerParams.weapon_drop_up))


# 自己刚丢下的枪在冷却期内不参与自己的拾取判定(否则丢完原地按 F 就捡回来)
func _live_self_drops() -> Array:
	var now := Time.get_ticks_msec()
	var out: Array = []
	for inst in _self_drop_until.keys():
		if int(_self_drop_until[inst]) > now:
			out.append(inst)
		else:
			_self_drop_until.erase(inst)
	return out


# ── 拾取提示(每把**能捡的**武器各自一个"F")──
# 用户 2026-09-16:「只要能捡起就会显示 F」。所以判据 = **能不能捡**,不是"是不是最近那把":
#   在拾取半径内 + 不是自己刚丢下的(冷却) + 该武器类型没被禁用。
# - 与 `try_pickup_for` 的选法**仍然是同一套** —— 按 F 捡的仍是最近那把,只是"能捡"的
#   每一把都会提示(踩到其中任何一把都能捡起来)。
## 时间玩法视效驱动:底片化 ramp ≤200ms、加速压暗 ramp 100ms、透支深度直传
func _tick_time_visuals(delta: float) -> void:
	if _post_process == null or time_field == null:
		return
	var rewinding: bool = time_field.is_rewinding()
	_film_t = move_toward(_film_t, 1.0 if rewinding else 0.0, delta / 0.2)
	_haste_t = move_toward(_haste_t, 1.0 if time_field.is_hasting() else 0.0, delta / 0.1)
	_post_process.set_time_effects(_film_t, time_field.loan_depth(), _haste_t)

	# 透支/加速/回溯的音调变形(全局系数;透支越深越尖)
	var depth := time_field.loan_depth()
	var mult := 1.0 + TimeParams.LOAN_PITCH_RANGE * depth
	if time_field.is_hasting():
		mult += 0.12
	elif rewinding:
		mult -= 0.15
	Sfx.pitch_mult = clampf(mult, 0.7, 1.8)
	_sync_time_glows()


# 时间状态高亮(B13):加速 → 主角 + 场上敌人;回溯 → **只有精英**。
# - 配色是**规则**不是装饰:精英在加速与回溯两种状态下都必须是"极为亮眼的黄"(用户指定),
#   其余实体的高亮只是"时间场生效中"的可读提示。用加色副本(TimeGlow)而不是 modulate ——
#   后者在非 HDR 2D 里被夹到 1.0,且会被敌人每帧的受击白闪覆盖(实测完全看不出高亮)。
const GLOW_PLAYER := Color(0.30, 0.62, 1.0)      # 主角:冷白蓝
const GLOW_ENEMY := Color(1.0, 0.94, 0.86)       # 普通敌:暖白
const GLOW_ELITE := Color(1.0, 0.82, 0.06)       # 精英:亮黄(两层叠加 → "极为亮眼")
const GLOW_RADIUS := 1500.0                      # 只给近处敌人上副本(远处的看不见,白花销)

func _sync_time_glows() -> void:
	if time_field == null:
		return
	var want: Dictionary = {}
	if time_field.is_hasting():
		var pl := get_node_or_null("WorldViewport/Player") as Node2D
		if pl != null:
			want[pl] = [GLOW_PLAYER, 1]
		for e in get_tree().get_nodes_in_group("enemies"):
			if not (e is Node2D) or not is_instance_valid(e) or bool(e.get("is_dead")):
				continue
			if e.has_meta("elite"):
				want[e] = [GLOW_ELITE, 2]      # 精英不分远近(它是时间场的"例外",要一眼看到)
			elif _near_player(e as Node2D):
				want[e] = [GLOW_ENEMY, 1]
	elif time_field.is_rewinding():
		for e in get_tree().get_nodes_in_group("enemies"):
			if is_instance_valid(e) and e is Node2D and not bool(e.get("is_dead")) and e.has_meta("elite"):
				want[e] = [GLOW_ELITE, 2]
	for k in _glows.keys():
		if not is_instance_valid(k) or not want.has(k):
			var old: TimeGlow = _glows[k]
			if is_instance_valid(old):
				old.queue_free()
			_glows.erase(k)
	for k in want.keys():
		var spec: Array = want[k]
		var g: TimeGlow = _glows.get(k)
		if g == null or not is_instance_valid(g):
			g = TimeGlow.attach(k, spec[0], int(spec[1]))
			if g != null:
				_glows[k] = g
		else:
			g.set_color(spec[0])


func _near_player(n: Node2D) -> bool:
	var pl := get_node_or_null("WorldViewport/Player") as Node2D
	if pl == null:
		return false
	var d := MazeGenerator.toroidal_delta_px(n.global_position, pl.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	return d.length() <= GLOW_RADIUS


## 时间场驱动缝(探针直调;正常路径由 _process 传真实按键态)
var _prev_want_rewind := false
var _prev_want_haste := false


func _drive_time(delta: float, want_rewind: bool, want_haste: bool) -> void:
	# 锁定/空账时的按键无效操作:按下那一下给 deny 反馈(否则玩家以为键坏了)
	if grain_account != null and want_rewind and not _prev_want_rewind and not grain_account.can_spend():
		Sfx.play("deny")
	if grain_account != null and want_haste and not _prev_want_haste and not grain_account.can_spend():
		Sfx.play("deny")
	_prev_want_rewind = want_rewind
	_prev_want_haste = want_haste
	time_field.update(delta, want_rewind, want_haste)


## 世界回放 tick:录制 ↔ 回放的状态机 + 尸体保留/过期清理(单机)
func _tick_rewind(delta: float) -> void:
	if _rewind == null:
		return
	var pl := get_node_or_null("WorldViewport/Player")
	var rewinding: bool = time_field != null and time_field.is_rewinding()
	if rewinding and not _rewind.was_rewinding:
		_rewind.begin()
		_tile_cursor = _rewind.recorded_seconds()   # 瓦片还原高水位=进入回溯时刻
	elif not rewinding and _rewind.was_rewinding:
		var exit_t: float = _rewind.finish()
		if _tile_ledger != null:
			_tile_ledger.prune_after(exit_t)   # 瓦片账本与磁带同裁:被复写时段的破坏瓦片条目一并消失
	_rewind.was_rewinding = rewinding
	_prev_time_mode = time_field.mode if time_field != null else 0
	if rewinding:
		WorldRewind.hold_corpses = false
		_rewind.step(delta, pl)
		# 二次伤害:倒飞的子弹穿过**精英**(精英不受回溯,照常在场)时再结算一次伤害。
		# 每颗回放弹对同一精英只结算一次(meta 记 id),避免逐帧反复扣除生命值。
		_rewind_elite_hits()
		# 瓦片还原:跨过 target 的破坏按 t 降序写回(最新破坏先还,最早的值最后落地)
		if _tile_ledger != null and _tile_cursor >= 0.0:
			var target := _rewind.current_target()
			for e in _tile_ledger.take_range(target, _tile_cursor):
				for c in e["cells"]:
					_restore_sub(c)
			_tile_cursor = target
	else:
		WorldRewind.hold_corpses = true
		_rewind.record(delta, pl, get_tree().get_nodes_in_group("enemies"),
				get_tree().get_nodes_in_group("bullet"))
		WorldRewind.expire_corpses(get_tree())
		# 瓦片账本:帧末入账本帧拆掉的格;并裁剪超出回溯窗口的旧条目
		if _tile_ledger != null:
			if not _tile_pending.is_empty():
				_tile_ledger.record(_rewind.recorded_seconds(), _tile_pending)
				_tile_pending = []
			_tile_ledger.prune(_rewind.recorded_seconds() - TimeParams.SNAP_SECONDS)


func _update_pickup_prompt() -> void:
	var pl := $WorldViewport.get_node_or_null("Player") as Node2D
	# - 先把表里的 pos 重置为**视觉中心**(可见的枪在哪),判定与提示才与玩家看到的一致。
	# 注意： 并且必须**先设锚点**:WeaponPickup 的 canonical_pos(权威,恒在 [0,MAP))与渲染位置
	#   是两回事,渲染位置每帧由锚点锚到玩家的最近副本 —— 不设锚点的话跨接缝的枪会画在
	#   地图另一头(屏幕外),表现就是"接缝附近的枪看不见/取模不对"。
	#   (联机侧由 PvpMatchClient._tick_ground_weapons 做同一件事;这里原先漏了。)
	var anchor: Vector2 = pl.global_position if pl != null else Vector2.ZERO
	for inst in _pickup_nodes:
		var n0 = _pickup_nodes.get(inst, null)
		if n0 != null and is_instance_valid(n0):
			var pk0 := n0 as WeaponPickup
			pk0.set_anchor(anchor)
			pk0.sync_render_from_canonical()
			var e0: Dictionary = ground_weapons.get_entry(int(inst))
			if not e0.is_empty():
				e0["pos"] = pk0.canonical_pos
	var self_drops := _live_self_drops()
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	for inst in _pickup_nodes:
		var n = _pickup_nodes.get(inst, null)
		if n == null or not is_instance_valid(n):
			continue
		var pk := n as WeaponPickup
		var can := false
		if pl != null and not self_drops.has(int(inst)):
			if pl.weapons.is_type_enabled(int(pk.type_id)):
				var d := GridPathfinder.toroidal_delta_px(
						pk.canonical_pos, pl.global_position, w, h).length()
				can = d <= PlayerParams.weapon_pickup_radius
		pk.set_prompt_visible(can)
