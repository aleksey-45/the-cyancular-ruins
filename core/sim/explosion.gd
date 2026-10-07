class_name Explosion
extends RefCounted

# 爆炸 AoE 判定:分段衰减 + 遮挡检测 + 友伤。纯静态,冒烟测试可直接调用。
const INNER_FRACTION: float = 0.4  # 内圈半径比例,内圈内满伤
const BLOCKED_FRACTION: float = 0.75  # 墙后(LOS 遮挡)伤害/击退保留比例

static func apply_aoe(center: Vector2, radius: float, max_damage: int, max_knockback: float, shooter: Node = null) -> void:
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
		var dmg := _falloff(d, radius, max_damage) * cover * wmult
		if dmg <= 0:
			continue
		# 命中标记(屏幕中心 X)。-  敌人侧**不写** last_damager 归因 —— 那个 meta 原先的
		# 唯一读者是单机击杀播报(notify_enemy_killed),播报 2026-09-17 删除后写入即死数据。
		# 玩家分支的 attribute() 保留:大乱斗 RoyaleHost 靠它判击杀分。
		CombatFeedback.hit_marker()
		# set_velocity=true:爆炸击退覆盖原速度,严格沿爆心→目标径向(不叠加鸟自身飞行速度带偏)
		e.hurt(int(dmg), _outward_dir(center, (e as Node2D).global_position),
				_falloff(d, radius, max_knockback) * cover * wmult, true)
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
			# - 自伤标记(必须在 `take_hit` **之前**,与 attribute 同一纪律):`attribute` 对
			#   attacker == victim 静默跳过,自伤因此没有归因通道 —— 惩罚要扣"对自己造成的伤害",
			#   靠这一笔把"自伤"与"未识别攻击来源"分开。
			#   - 只有**投掷者本人**在爆区里才写  ->  别人炸不到这条路径;`shooter` 为 null
			#   (无主爆炸/敌方弹药)时 `pp == null` 恒 false,天然不写。
			#   - 本函数**只写标记**,伤害与击退一个数都不动(爆炸对队友满效是用户既有裁定)。
			if shooter == pp:
				CombatFeedback.note_self_hit(pp)
			# 击杀归因(大乱斗 RoyaleHost 读 last_damager 判击杀分);1v1 MatchHost 不读,无行为变化
			# - 同敌人分支:必须在 take_hit 之前写,倒地同帧的归因读取者才看得到(Task 15)。
			# 注:此处原缺 is_instance_valid 守卫,统一入口补上(更严,不影响原本会写的场景)
			CombatFeedback.attribute(pp, shooter)   # 归因写端统一入口
			# 击退随距离衰减传入玩家(独立击退向量结算);ignore_iframes=true 穿透无敌帧
			pp.take_hit(center, int(_falloff(d, radius, max_damage) * mult), true,
					_falloff(d, radius, max_knockback) * mult)
	# 可破坏瓦片(树叶/树干):按 tile_defs 爆炸衰减(75%)扣除生命值,破坏后变空气
	if has_grid:
		_damage_tiles(center, radius, max_damage, shooter)

# 爆区内的可破坏瓦片(树叶/树干)扫描 —— **纯几何查询,不改任何状态**。
# 返回 [{cell: Vector2i, pos: Vector2(格中心), tex: int, d: float(到爆心的环面距离)}]。
# - 两个用途共用同一份扫描,两端表现因此同源:
#   ① 权威侧扣除生命值(_damage_tiles);② 表现层播受击碎片(所有端 —— 见 bullet_base._explode)。
static func destructible_subs(center: Vector2, radius: float) -> Array:
	# cyrm v4(选项 A):爆炸按 **16px 子格**扫描/扣除生命值 —— 炸出的是圆洞而不是整格消失。
	# 返回 [{sub: Vector2i, pos: Vector2(子格中心), tex: int, d: float(到爆心的环面距离)}],
	# 扣除生命值(_damage_tiles)与受击碎片表现(bullet_base._explode)共用同一份扫描。
	var out: Array = []
	var sgrid := MazeGenerator.current_subgrid
	if sgrid.is_empty():
		return out
	var sc: int = sgrid[0].size()
	var sr: int = sgrid.size()
	var csub := Vector2i(posmod(int(center.x) / 16, sc), posmod(int(center.y) / 16, sr))
	var reach := ceili(radius / 16.0) + 1
	for dy in range(-reach, reach + 1):
		for dx in range(-reach, reach + 1):
			var sx := posmod(csub.x + dx, sc)
			var sy := posmod(csub.y + dy, sr)
			var tex: int = sgrid[sy][sx]
			if tex == 0 or not TileDefs.explosion_destroyable(tex):
				continue
			var pos := Vector2(sx * 16.0 + 8.0, sy * 16.0 + 8.0)
			var d := _dist(center, pos)
			if d > radius:
				continue
			out.append({"sub": Vector2i(sx, sy), "pos": pos, "tex": tex, "d": d})
	return out


static func _damage_tiles(center: Vector2, radius: float, max_damage: int, owner: Node = null) -> void:
	for e in destructible_subs(center, radius):
		var dmg := int(_falloff(float(e["d"]), radius, max_damage) * TileDefs.explosion_decay())
		if dmg <= 0:
			continue
		TileDefs.damage_sub(e["sub"], dmg, "explosion", owner)


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


# 掩护衰减系数:内圈(≤INNER_FRACTION 半径)免疫遮挡——贴脸目标被墙棱角判"无视线"
# 扣 25% 会出现"爆心比开阔边缘伤害低"的倒挂(实测 bug);爆心贴脸时掩护不该生效。
# 纯函数(-s 可测);apply_aoe 的敌人/玩家分支共用,保证"任意距离伤害随距离不增"。
static func cover_multiplier(d: float, radius: float, blocked: bool) -> float:
	if d <= radius * INNER_FRACTION:
		return 1.0
	return BLOCKED_FRACTION if blocked else 1.0
