class_name Explosion
extends RefCounted

# 爆炸 AoE 判定:分段衰减 + 遮挡检测 + 友伤。纯静态,冒烟测试可直接调用。
const INNER_FRACTION: float = 0.4  # 内圈半径比例,内圈内满伤
const BLOCKED_FRACTION: float = 0.75  # 墙后(LOS 遮挡)伤害/击退保留比例

# 无伤冲击(apply_force_aoe)的力度-距离关系:QUADRATIC=二次缓出(缺省,不设即旧击退手感)、
# LINEAR=按距离线性(pr_attraction rev18~19)、FLAT=全域等强(pr_attraction rev20 /
# pr_knockback rev2:只要在范围内,力度一律拉满,不分距离)。
enum Falloff { QUADRATIC, LINEAR, FLAT }

static func apply_aoe(center: Vector2, radius: float, max_damage: int, max_knockback: float,
		shooter: Node = null, falloff_mode: int = Falloff.QUADRATIC) -> void:
	var tree := _tree()
	var grid := MazeGenerator.current_grid
	var has_grid := not grid.is_empty()
	for e in tree.get_nodes_in_group("enemies"):
		if not (e is Node2D):
			continue
		var d := _dist(center, (e as Node2D).global_position)
		if d > radius:
			continue
		# 遮挡(墙后)= 部分掩体;内圈免疫遮挡(见 cover_multiplier 注释)
		var blocked := has_grid and not _has_los(center, e as Node2D, grid)
		var cover := cover_multiplier(d, radius, blocked)
		var wmult := Water.water_mult((e as Node2D).global_position, grid)  # 目标在水里:×水格 decay
		var dmg := _blast_falloff(d, radius, max_damage, falloff_mode) * cover * wmult
		if dmg <= 0:
			continue
		# set_velocity=true:爆炸击退覆盖原速度,严格沿爆心→目标径向(不叠加鸟自身飞行速度带偏)
		e.hurt(int(dmg), _outward_dir(center, (e as Node2D).global_position),
				_blast_falloff(d, radius, max_knockback, falloff_mode) * cover * wmult, true)
		# 击杀归因 + 命中标记(单机:玩家榴弹炸到敌人;服务器进程无 CombatFeedback 实例则空转)
		if shooter != null and is_instance_valid(shooter) and shooter != e:
			e.set_meta("last_damager", shooter)
		CombatFeedback.hit_marker()
	# 遍历所有玩家(PvP 服务器两个玩家;单机组里只有一个 → 行为不变)
	var first_player: Node2D = null
	for p in tree.get_nodes_in_group("player"):
		if not (p is Node2D):
			continue
		var pp := p as Node2D
		if first_player == null:
			first_player = pp
			_cam_shake(center, radius, pp)
		if not pp.has_method("take_hit"):
			continue
		if pp.has_method("is_downed") and pp.is_downed():
			continue
		var d := _dist(center, pp.global_position)
		if d <= radius:
			# 同敌人:内圈免疫遮挡衰减
			var blocked := has_grid and not _has_los(center, pp, grid)
			var mult := cover_multiplier(d, radius, blocked)
			mult *= Water.water_mult(pp.global_position, grid)  # 目标在水里:×0.25
			# 击退随距离衰减传入玩家(独立击退向量结算);ignore_iframes=true 穿透无敌帧
			pp.take_hit(center, int(_blast_falloff(d, radius, max_damage, falloff_mode) * mult), true,
					_blast_falloff(d, radius, max_knockback, falloff_mode) * mult)
			# 击杀归因(大乱斗 RoyaleHost 读 last_damager 判击杀分);1v1 MatchHost 不读,无行为变化
			if shooter != null and shooter != pp:
				pp.set_meta("last_damager", shooter)
				pp.set_meta("last_damager_time", Time.get_ticks_msec())   # 归因时效(RoyaleHost.ATTRIB_WINDOW)
	# 可破坏瓦片(树叶/树干):按 tile_defs 爆炸衰减(75%)扣血,破坏后变空气
	if has_grid:
		_damage_tiles(center, radius, max_damage, grid, falloff_mode)

# 爆炸对可破坏瓦片(树叶/树干)扣血:按距离衰减 × tile_defs 爆炸衰减(0.75),破坏后变空气。
static func _damage_tiles(center: Vector2, radius: float, max_damage: int, grid: Array[Array],
		falloff_mode: int = Falloff.QUADRATIC) -> void:
	var ts: int = GameParameters.TILE_SIZE
	var rows := grid.size()
	var cols := grid[0].size()
	var cc := MazeGenerator.cell_of(center, ts, cols, rows)
	var reach_cells := ceili(radius / ts) + 1
	for dy in range(-reach_cells, reach_cells + 1):
		for dx in range(-reach_cells, reach_cells + 1):
			var cx := posmod(cc.x + dx, cols)
			var cy := posmod(cc.y + dy, rows)
			var v: int = grid[cy][cx]
			if v == 0:
				continue
			var tex: int = v / 16
			if not TileDefs.explosion_destroyable(tex):
				continue
			var d := _dist(center, Vector2(cx * ts + ts * 0.5, cy * ts + ts * 0.5))
			if d > radius:
				continue
			var dmg := int(_blast_falloff(d, radius, max_damage, falloff_mode) * TileDefs.explosion_decay())
			if dmg <= 0:
				continue
			TileDefs.damage_tile(Vector2i(cx, cy), dmg, "explosion")


# 静态函数取场景树:全局 get_tree() 在 static 上下文不可用,走主循环。
# 爆炸相机震动:爆心越贴近玩家震得越猛,随距离线性衰减;超出影响距离无震动。
# 与伤害分支独立——玩家倒地/在爆区外也能看到震动。
static func _cam_shake(center: Vector2, radius: float, p: Node2D) -> void:
	if p == null:
		return
	var d := _dist(center, p.global_position)
	var reach := maxf(radius * 2.5, 400.0)
	if d > reach:
		return
	var cam: Camera2D = p.get_viewport().get_camera_2d()
	if cam == null or not cam.has_method("shake"):
		return
	var amt := PlayerParams.explosion_cam_shake * (1.0 - d / reach)
	cam.shake(amt, PlayerParams.explosion_cam_shake_time)

static func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree

# 软圆白贴图:占位爆炸/榴弹占位/预瞄爆点标记共用。
static func make_circle_texture(size: int) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var cx := size * 0.5
	for y in range(size):
		for x in range(size):
			var d := Vector2(x - cx, y - cx).length() / cx
			if d <= 1.0:
				img.set_pixel(x, y, Color(1, 1, 1, (1.0 - d) * 0.9))
	return ImageTexture.create_from_image(img)

static func _dist(center: Vector2, target: Vector2) -> float:
	return MazeGenerator.toroidal_delta_px(center, target,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()

static func _outward_dir(center: Vector2, target: Vector2) -> Vector2:
	var delta := MazeGenerator.toroidal_delta_px(center, target,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	return delta.normalized() if not delta.is_zero_approx() else Vector2.RIGHT

static func _has_los(center: Vector2, target: Node2D, grid: Array[Array]) -> bool:
	var ts: int = GameParameters.TILE_SIZE
	var center_cell := MazeGenerator.cell_of(center, ts, grid[0].size(), grid.size())
	var target_cell := MazeGenerator.cell_of(target.global_position, ts, grid[0].size(), grid.size())
	return MazeGenerator.has_line_of_sight(center_cell, target_cell)

# 平缓衰减:内圈满值,二次方(1-t²)渐变到 0——比 smoothstep 平缓,中远距离保留更多伤害/击退
static func _falloff(d: float, radius: float, max_val: float) -> float:
	var inner := radius * INNER_FRACTION
	if d < inner:
		return max_val
	if d >= radius:
		return 0.0
	var t := (d - inner) / (radius - inner)
	return max_val * (1.0 - t * t)


# 爆炸(伤/击退)-距离关系(apply_aoe 用,Falloff 枚举同款语义):
# FLAT=全域等强;LINEAR=按距离线性(爆心满值、边缘归零、中点半值,计时爆炸团卡:
# 「与爆炸中心距离成线性衰减」);缺省=旧二次缓出(_falloff,内圈满值)。纯函数(-s 可测)。
static func _blast_falloff(d: float, radius: float, max_val: float, mode: int) -> float:
	if d >= radius:
		return 0.0
	if mode == Falloff.FLAT:
		return max_val
	if mode == Falloff.LINEAR:
		return max_val * clampf(1.0 - d / maxf(radius, 0.001), 0.0, 1.0)
	return _falloff(d, radius, max_val)


# 掩护衰减系数:内圈(≤INNER_FRACTION 半径)免疫遮挡——贴脸目标被墙棱角判"无视线"
# 扣 25% 会出现"爆心比开阔边缘伤害低"的倒挂(实测 bug);爆心贴脸时掩护不该生效。
# 纯函数(-s 可测);apply_aoe 的敌人/玩家分支共用,保证"任意距离伤害随距离不增"。
static func cover_multiplier(d: float, radius: float, blocked: bool) -> float:
	if d <= radius * INNER_FRACTION:
		return 1.0
	return BLOCKED_FRACTION if blocked else 1.0


## 无伤冲击 AoE(排斥弹头/引力核心):对范围内玩家/敌人/子弹施加推力。
## force > 0 = 推离爆心;force < 0 = 吸向爆心。不扣血、不触发无敌帧、不播受击白闪。
## 子弹(含在飞榴弹/敌方投弹——都经 BulletBase._ready 进 bullet 组)被推/吸会改变
## velocity_vec(服务器权威弹改变轨迹;exclude 排除投掷物本体)。
## falloff_mode 见 Falloff 枚举:缺省二次缓出 / 线性(pr_attraction rev18~19)/
## 全域等强(pr_attraction rev20 / pr_knockback rev2:只要在范围内,力度一律同等拉满)。
static func apply_force_aoe(center: Vector2, radius: float, force: float,
		shooter: Node = null, exclude: Node = null, falloff_mode: int = Falloff.QUADRATIC) -> void:
	var tree := _tree()
	var sgn := signf(force)
	var mag := absf(force)
	# 玩家(含倒地者:倒地物理仍在,会被推动)
	for p in tree.get_nodes_in_group("player"):
		if not (p is Node2D) or p == exclude:
			continue
		var pp := p as Node2D
		var d := _dist(center, pp.global_position)
		if d > radius:
			continue
		var f := _force_falloff(d, radius, mag, falloff_mode)
		if f <= 0.0:
			continue
		if pp.has_method("apply_blast_force"):
			pp.apply_blast_force(center, f * sgn)
	# 敌人(尸体也推:它们的物理仍在)
	for e in tree.get_nodes_in_group("enemies"):
		if not (e is Node2D) or e == exclude:
			continue
		var en := e as Node2D
		var d2 := _dist(center, en.global_position)
		if d2 > radius:
			continue
		var f2 := _force_falloff(d2, radius, mag, falloff_mode)
		if f2 <= 0.0:
			continue
		if e.has_method("apply_blast_force"):
			e.apply_blast_force(center, f2 * sgn)
	# 子弹
	for b in tree.get_nodes_in_group("bullet"):
		if not (b is Node2D) or b == exclude:
			continue
		var bb := b as Node2D
		var d3 := _dist(center, bb.global_position)
		if d3 > radius:
			continue
		var f3 := _force_falloff(d3, radius, mag, falloff_mode)
		if f3 <= 0.0:
			continue
		var dir := _outward_dir(center, bb.global_position) * sgn
		if bb.get("velocity_vec") != null:
			bb.set("velocity_vec", (bb.get("velocity_vec") as Vector2) + dir * f3)

# 冲击强度-距离关系(Falloff):FLAT=全域等强(范围内任何距离一律满力度,pr_attraction rev20 /
# pr_knockback rev2);
# LINEAR=按距离线性(1-d/r,pr_attraction rev18~19);缺省沿用伤害同款二次缓出。
# 范围外一律 0(调用方已先行剔除 d>radius,这里兜底)。纯函数(-s 可测)。
static func _force_falloff(d: float, radius: float, mag: float, mode: int) -> float:
	if d >= radius:
		return 0.0
	if mode == Falloff.FLAT:
		return mag
	if mode == Falloff.LINEAR:
		return mag * clampf(1.0 - d / maxf(radius, 0.001), 0.0, 1.0)
	return _falloff(d, radius, mag)
