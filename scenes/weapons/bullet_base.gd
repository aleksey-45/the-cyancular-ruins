class_name BulletBase
extends CharacterBody2D

const BOUNCE_DAMPING: float = 0.6  # 撞墙反弹速度保留比例
const TileHitFx := preload("res://scenes/effects/tile_hit_fx.gd")
const HitShape := preload("res://core/sim/hit_shape.gd")   # 受击判定几何唯一入口
const HitFeedbackFx := preload("res://scenes/effects/hit_feedback_fx.gd")   # 世界系命中反馈(X + 伤害数字)

# 榴弹「碰到玩家 → 短引信」的候选组:player = 玩家实体;player_replica = 客户端上的对手视觉副本(它不入 player 组,理由见 player_replica.GROUP)。
const CONTACT_GROUPS: Array[String] = ["player", "player_replica"]

# 子弹只管理物理属性(开火时由武器设置)。不含伤害:命中敌人回调 source.apply_hit。
var velocity_vec: Vector2 = Vector2.ZERO
var speed: float = 0.0
var size: float = 1.0  # 子弹放大倍数(setup 时应用为节点缩放)
var gravity_factor: float = 0.0   # 重力下坠倍率(枪械=0,以后敌方弹药可>0)
var breaks_terrain: bool = false
var has_aoe: bool = false
var bullet_color: Color = Color.WHITE  # 纹理本底;武器如需染色再设
var max_range: float = 0.0
var traveled: float = 0.0
# 上一物理帧开始时的位置:扫掠判定线段的起点。★ 服务器裁决与客户端 cull 都读它 ⇒ 本帧位移必须与上一帧首尾相接;
# 环面 wrap 后本字段与 global_position 同处一个副本空间(见 _physics_process 末尾)。
var prev_pos: Vector2 = Vector2.ZERO
var source: Node = null
var shooter: Node = null  # 射手玩家(击杀归因用):本地=武器持有者;服务器=权威模拟里的玩家
var hit_damage: int = 0    # 命中伤害(武器 fire 注入;切枪后 source 失效时兜底直接结算)
var hit_impact: float = 0.0  # 命中击退(同上)
var apply_damage: bool = true  # 客户端视觉副本设 false:只出特效/轨迹,不裁决伤害(伤害由服务器裁决)

@export var explodes: bool = false        # 是否爆炸弹
@export var direct_hit_damage: int = 10   # 命中敌人的直接伤害(立即结算)
@export var fuse_time: float = 0.5        # 撞墙反弹后延时(秒)
@export var hit_fuse_time: float = 0.1    # 命中敌人反弹后延时(秒);直接伤立即,反弹后短引信
@export var explosion_radius: float = 128.0
@export var explosion_damage: int = 35
@export var explosion_knockback: float = 900.0
@export var explosion_visual: PackedScene = null
# 最小破坏单位(单位 = 格):>=1 按整 64px 格扣格级账;0.25 = 1 个 16px 子格。<1 时按子格扣(榴弹 0.25 才有意义)。
@export var tile_break_unit: float = 1.0

var _fuse_active: bool = false   # 首次碰撞(撞墙/命中敌人)后才开始计时
var _fuse_elapsed: float = 0.0
var _fuse_duration: float = 0.0  # 本次引信时长(撞墙=fuse_time,命中敌人=hit_fuse_time)
# 判定点整体后移帧数:爆炸当帧只播火光/碎片/震屏,再过 EXPLOSION_SETTLE_FRAMES 个物理帧才做一次 apply_aoe。
# 子弹在窗口里保持存活但不可见、不移动;期间被清掉则放弃这次结算。
const EXPLOSION_SETTLE_FRAMES := 3
var _settle_frames: int = 0

func setup(dir: Vector2, spd: float, rng: float, siz: float, col: Color, src: Node) -> void:
	velocity_vec = dir.normalized() * spd
	speed = spd
	max_range = rng
	size = siz
	bullet_color = col
	source = src
	rotation = velocity_vec.angle()
	scale = Vector2(size, size)  # 放大倍数作用于整颗子弹(贴图+碰撞体)

func _ready() -> void:
	prev_pos = global_position
	# 子弹贴图与碰撞体由场景(bullet.tscn)配置,这里只把武器 bullet_color 作 tint,不再动态生成方块。
	var sp := get_node_or_null("Sprite2D") as Sprite2D
	if sp != null:
		sp.modulate = bullet_color
	add_to_group("bullet")
	# 子弹尾迹:设置开启时所有子弹都挂(单人/自己的弹/AI 弹/对手副本弹同一处接线,统一用武器弹色)。
	if Settings.pvp_show_trajectories:
		BulletTrail.attach(self, bullet_color)

func _physics_process(delta: float) -> void:
	delta = TimeField.bullet_delta(delta, self)   # 时间场:回溯冻结/加速(我方弹随玩家)
	if TimeField.current != null and TimeField.current.is_rewinding():
		return   # 回溯中子弹不自步进(位置由回放器摆;引信/水阻/射程都不结算)
	if _settle_frames > 0:
		# 爆炸后的判定窗口:不移动、不再触发引信;倒计时到 0 时一次性结算并销毁。
		_settle_frames -= 1
		if _settle_frames == 0:
			_settle_explosion()
		return
	prev_pos = global_position
	if gravity_factor > 0.0:
		velocity_vec.y += GameParameters.gravity0 * gravity_factor * delta
		if not velocity_vec.is_zero_approx():
			rotation = velocity_vec.angle()
	# 爆炸弹的「碰到玩家 → 短引信」:两端同源(权威结算在 MatchHost._adjudicate_grenade),这里只管引信时机;引信一旦启动就不再改时长。
	if explodes and not _fuse_active:
		_check_player_contact()
	if explodes and _fuse_active:
		_fuse_elapsed += delta
		if _fuse_elapsed >= _fuse_duration:
			_explode()
			if _settle_frames == 0:
				queue_free()
			return
	_apply_water_drag(delta)
	var step := velocity_vec * delta
	traveled += step.length()
	var from := global_position
	var col := move_and_collide(step)
	var to := global_position
	var t_wall := 1.0
	if col != null:
		to = from + col.get_travel()
		var lens := step.length()
		t_wall = (col.get_travel().length() / lens) if lens > 0.0 else 0.0
	# 受击判定只认 hurt_rect 线段扫掠:物理碰撞箱已不承担受击职责(bullet.tscn mask=1 只撞地形)。
	# ★ 顺序:受击面先于地形 —— 同一段上取更早的那个;地形更早则伤害不结算(墙后打不到人)。
	var hurt := first_hurt_on_segment(from, to, ["enemies"])
	if not hurt.is_empty() and float(hurt["t"]) <= t_wall:
		_on_hurt_target(from, to, hurt)
		return
	if col != null:
		_on_terrain_collision(col)
		return
	if traveled >= max_range:
		if explodes:
			_explode()
		if _settle_frames == 0:
			queue_free()
		return
	_wrap()
	# 环面 wrap 会把 global_position 整幅平移;扫掠起点要跟着平移,否则下一帧/裁决读到的线段横穿整图。
	prev_pos = from + (global_position - to)


# 线段扫掠:groups 内最早被穿过的受击面(t 最小;起点在框内 = 0)。exclude = 射手(自己不打自己)。
# ★ 玩家实体的伤害不在这里结算:PvP 的权威单一来源是 MatchHost._adjudicate_bullets(客户端是 _cull_bullet_contacts);
#   这里再扫 player 组会让同一发子弹在服务器上被裁决两次。
func first_hurt_on_segment(from: Vector2, to: Vector2, groups: Array, exclude: Node = null) -> Dictionary:
	var best: Dictionary = {}
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	var grow := hit_grow()
	for group in groups:
		for n in get_tree().get_nodes_in_group(group):
			if n == exclude or not (n is Node2D) or not HitShape.hurtable(n):
				continue
			var t := HitShape.segment_hits_rect(from, to, hurt_rect_for(n as Node2D), w, h, grow)
			if t >= 0.0 and (best.is_empty() or t < float(best["t"])):
				best = {"node": n, "t": t}
	return best


# 子弹体积补回命中:把本弹碰撞矩形的世界 AABB 半展当作受击面外扩量(grow)。
# ★ 矩形随节点旋转 ⇒ 必须用速度角投影到世界轴;直接取 shape.size 会在斜射时只外扩一半。
func hit_grow() -> Vector2:
	var cs := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if cs == null or cs.shape == null or not (cs.shape is RectangleShape2D):
		return Vector2.ZERO
	var half: Vector2 = (cs.shape as RectangleShape2D).size * (0.5 * size)
	var ang := velocity_vec.angle() if not velocity_vec.is_zero_approx() else rotation
	var c := absf(cos(ang))
	var s := absf(sin(ang))
	return Vector2(half.x * c + half.y * s, half.x * s + half.y * c)


# 目标的受击面:优先目标自己的 hurt_rect(玩家/敌人)或 hurt_rect_rendered(对手副本),都没有才按活动碰撞箱兜底。
func hurt_rect_for(n: Node2D) -> Rect2:
	if n == null:
		return Rect2()
	if n.has_method("hurt_rect_rendered"):
		return n.hurt_rect_rendered()
	if n.has_method("hurt_rect"):
		return n.hurt_rect()
	return HitShape.hurt_rect_of(n)


# 扫掠命中受伤目标:普通弹结算伤害并自毁;爆炸弹直伤 + 起短引信 + 按命中面法向反弹(与旧物理反弹同语义)。
func _on_hurt_target(from: Vector2, to: Vector2, hit: Dictionary) -> void:
	var target: Node = hit["node"]
	global_position = from + (to - from) * float(hit["t"])
	if explodes:
		_direct_hit(target)
		_start_fuse(hit_fuse_time)
		var normal := from - hurt_rect_for(target as Node2D).get_center()
		if normal.is_zero_approx():
			normal = -velocity_vec
		velocity_vec = velocity_vec.bounce(normal.normalized()) * BOUNCE_DAMPING
		if not velocity_vec.is_zero_approx():
			rotation = velocity_vec.angle()
		return
	# 命中敌人:优先走 source(武器)的 apply_hit;切枪后旧武器已 free 时用子弹自带 damage/impact 兜底;视觉副本(apply_damage=false)不裁决伤害,直接消失。
	if apply_damage and is_instance_valid(source) and source.has_method("apply_hit"):
		_spawn_hit_fx(target)
		source.apply_hit(target, velocity_vec)
		Sfx.play("hit")
	elif apply_damage and target.has_method("hurt"):
		_spawn_hit_fx(target)
		target.hurt(hit_damage, velocity_vec, hit_impact)
		Sfx.play("hit")
	queue_free()


# 命中反馈:命中 X 回到**屏幕中心**(CombatFeedback.hit_marker,用户裁定 —— 别再把 X 搬到目标上);
# 伤害数字仍画在目标身上(信息在目标处,X 不搬)。★ headless 服务器没有 CombatFeedback 实例 ⇒ 不建 UI 节点。
func _spawn_hit_fx(target: Node) -> void:
	CombatFeedback.hit_marker()
	if CombatFeedback.current == null or not (target is Node2D):
		return
	HitFeedbackFx.spawn_damage(get_viewport(), _fx_pos((target as Node2D).global_position), hit_damage)


# 撞到地形:保留旧语义 —— 爆炸弹反弹并起撞墙引信;其余弹拆可破坏砖后消失。
func _on_terrain_collision(col: KinematicCollision2D) -> void:
	if explodes:
		_start_fuse(fuse_time)
		var normal := col.get_normal()
		var reflected := velocity_vec.bounce(normal)
		velocity_vec = reflected * BOUNCE_DAMPING
		if not velocity_vec.is_zero_approx():
			rotation = velocity_vec.angle()
		return
	# 撞墙:可破坏(树叶/树干)⇒ 播受击碎片 + 权威侧扣血;不可破坏墙 ⇒ 子弹消失;延迟销毁确保破坏回调跑完。
	# ★ PvP 视觉副本(apply_damage=false)也走这里,只播碎片(即时命中反馈),绝不自拆本地瓦片 —— 拆墙渲染只由服务器 tile_destroyed 事件驱动(幽灵墙纪律)。
	_damage_tile_at(col.get_position(), col.get_normal())
	set_physics_process(false)
	velocity_vec = Vector2.ZERO
	get_tree().create_timer(0.05).timeout.connect(queue_free)

# 子弹在水里受速度方向阻力:velocity_vec *= exp(-drag·Δt)(纯系数在 Water.bullet_drag_factor)。
func _apply_water_drag(delta: float) -> void:
	var factor := Water.bullet_drag_factor(Water.is_in_water(global_position), GameParameters.water_bullet_drag, delta)
	if factor < 1.0:
		velocity_vec *= factor


func _wrap() -> void:
	# 与敌人一致:锚定到离玩家最近的副本,接缝附近不消失;PvP 服务器上有两个玩家在 player 组 ⇒ 优先锚到射手(否则 role2 子弹会锚到 role1 副本),客户端视觉副本 shooter 为 null 时回落第一个玩家。
	var p := get_tree().get_first_node_in_group("player") as Node2D
	if shooter != null and is_instance_valid(shooter) and shooter is Node2D and shooter.is_in_group("player"):
		p = shooter as Node2D
	if p == null:
		global_position = MazeGenerator.wrap_to_range(global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		return
	global_position = MazeGenerator.anchor_to_nearest(global_position, p.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)

# 撞墙处理:命中可子弹破坏的格(树叶/树干)⇒ 播受击碎片(所有端同款即时反馈);扣血只在权威侧执行,视觉副本只播碎片、绝不拆本地 grid。
# ★ 破坏粒度由 tile_break_unit 决定:整格(其余枪)走格级 damage_tile;1/2 格(榴弹 = 32px 块,2026-10-30 用户裁定)走 damage_block32;更细的走单子格。
func _damage_tile_at(pos: Vector2, normal: Vector2) -> void:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return
	if _tile_break_is_cell() or MazeGenerator.current_subgrid.is_empty():
		var cell := _tile_cell_at(pos, normal)
		var tex := _cell_texture(cell)
		if tex == 0 or not TileDefs.bullet_destroyable(tex):
			return
		_spawn_tile_hit(pos, tex)
		if apply_damage:
			TileDefs.damage_tile(cell, hit_damage, "bullet")
		return
	var cols: int = MazeGenerator.current_subgrid[0].size()
	var rows: int = MazeGenerator.current_subgrid.size()
	# 候选子格:碰撞点、沿法线推入墙内 0.5/1 个子格 —— 处理贴边命中/边界浮点。
	var probes := [pos, pos - normal * 8.0, pos - normal * 16.0]
	for p in probes:
		var sub := Vector2i(posmod(int(p.x) / 16, cols), posmod(int(p.y) / 16, rows))
		var tex: int = MazeGenerator.current_subgrid[sub.y][sub.x]
		if tex != 0 and TileDefs.bullet_destroyable(tex):
			_spawn_tile_hit(pos, tex)
			if apply_damage:
				if tile_break_unit >= 0.5:
					# 榴弹(0.5 格)直击按 32px 块结算,与爆炸口径一致。
					TileDefs.damage_block32(Vector2i(sub.x / 2, sub.y / 2), hit_damage, "bullet", shooter)
				else:
					TileDefs.damage_sub(sub, hit_damage, "bullet", shooter)
			return


func _tile_break_is_cell() -> bool:
	return tile_break_unit >= 1.0


# 命中点沿法线推入墙内半格,定位 64px 格(与旧"子格表为空"分支同口径)。
func _tile_cell_at(pos: Vector2, normal: Vector2) -> Vector2i:
	var grid := MazeGenerator.current_grid
	var ts: int = GameParameters.TILE_SIZE
	return MazeGenerator.cell_of(pos - normal * (ts * 0.5), ts, grid[0].size(), grid.size())


func _cell_texture(cell: Vector2i) -> int:
	var grid := MazeGenerator.current_grid
	if cell.y < 0 or cell.y >= grid.size() or cell.x < 0 or cell.x >= grid[cell.y].size():
		return 0
	return MazeGenerator.texture_of(int(grid[cell.y][cell.x]))


# 受击碎片只在命中点播一次(所有端同款);mark_hit 供服务器随后的拆砖事件去重(task-6 的粒子层)。
func _spawn_tile_hit(pos: Vector2, tex: int) -> void:
	var at := _fx_pos(pos)
	TileHitFx.spawn(get_viewport(), at, tex)
	TileHitFx.mark_hit(at)


func _direct_hit(hit: Node) -> void:
	if not apply_damage:
		return
	if hit.has_method("hurt"):
		var dir := velocity_vec.normalized() if not velocity_vec.is_zero_approx() else Vector2.RIGHT
		CombatFeedback.hit_marker()
		hit.hurt(direct_hit_damage, dir)


# 命中标记对所有端都调:headless 服务器进程无 CombatFeedback 实例 ⇒ hit_marker 是空操作,无副作用。

# 爆炸弹「碰到玩家」判定(引信时机的单一来源):候选 = CONTACT_GROUPS 里的玩家实体与对手副本,排除 shooter(否则自己的榴弹一出膛就在自己身上起短引信)。
# ★ 判据 = 爆弹点是否落在目标受击面内(与子弹/激光同一套 hurt_rect);命中只起短引信、不改轨迹,直接伤由 MatchHost._adjudicate_grenade 结算。
func _check_player_contact() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var w := float(GameParameters.MAP_WIDTH)
	var h := float(GameParameters.MAP_HEIGHT)
	for group in CONTACT_GROUPS:
		for n in tree.get_nodes_in_group(group):
			if n == shooter or not (n is Node2D) or not HitShape.hurtable(n):
				continue
			var rect := hurt_rect_for(n as Node2D)
			if HitShape.distance_px_to_rect_at(global_position, rect, global_position, w, h) <= 0.0:
				start_player_fuse()
				return

# 起「命中玩家」的短引信(hit_fuse_time):权威侧由 MatchHost._adjudicate_grenade 调,客户端视觉副本由 _check_player_contact 自行调;纪律与 _start_fuse 一致 —— 首次碰撞决定时长、之后不刷新。
func start_player_fuse() -> void:
	if explodes:
		_start_fuse(hit_fuse_time)

# ── 时间回溯:引信/射程状态的读写口(WorldRewind 快照用)──
# ★ 引信是这颗弹还剩多久炸的全部状态,必须进快照:否则重建出来的榴弹退回未点燃 —— 会在错误时刻爆炸,且与玩家重叠时走 0.1s 触碰引信贴脸起爆;traveled 同理,射程累计清零会让子弹飞过头。
func rewind_state() -> Dictionary:
	return {
		"fa": _fuse_active,
		"fe": _fuse_elapsed,
		"fd": _fuse_duration,
		"tr": traveled,
		# ★ max_range / gravity_factor / speed / size 都是开火时由武器注入的(scene 上不是这些值),不进快照 ⇒ 重建出来的弹带场景默认值,max_range 默认 0 会让 traveled >= max_range 当场成立、榴弹一松手就在回溯落点爆炸。
		"mr": max_range,
		"gf": gravity_factor,
		"sp": speed,
		"sz": size,
		"col": bullet_color,
	}


# 由快照写回(空字典 = 该帧没这份状态,保持原样 —— 老快照/无引信弹都安全)。
func apply_rewind_state(d: Dictionary) -> void:
	if d.is_empty():
		return
	_fuse_active = bool(d.get("fa", false))
	_fuse_elapsed = float(d.get("fe", 0.0))
	_fuse_duration = float(d.get("fd", 0.0))
	traveled = float(d.get("tr", 0.0))
	max_range = float(d.get("mr", max_range))
	gravity_factor = float(d.get("gf", gravity_factor))
	speed = float(d.get("sp", speed))
	size = float(d.get("sz", size))
	scale = Vector2(size, size)
	bullet_color = d.get("col", bullet_color)
	var sp2 := get_node_or_null("Sprite2D") as Sprite2D
	if sp2 != null:
		sp2.modulate = bullet_color


# 开始引信:首次碰撞(撞墙/命中敌人)起算,撞墙用 fuse_time、命中敌人用 hit_fuse_time;后续反弹不重置时长。
func _start_fuse(duration: float) -> void:
	if not _fuse_active:
		_fuse_duration = duration
	_fuse_active = true

func _explode() -> void:
	# 判定点后移:权威/单机路径先只排结算,火光/碎片/震屏照旧当帧播;
	# 子弹本体隐藏并留在树上数 EXPLOSION_SETTLE_FRAMES 个物理帧(_settle_explosion 结算后销毁)。视觉副本没有结算 ⇒ 照旧当帧销毁。
	if apply_damage:
		_settle_frames = EXPLOSION_SETTLE_FRAMES
		visible = false
	# 权威侧广播爆炸位置(组回调;子弹内不引 autoload —— `-s` 冒烟会 parse 失败)。单机没有这个组 ⇒ 空操作。
	if apply_damage:
		var sink := get_tree().get_first_node_in_group("authority_explosion_sink")
		if sink != null and sink.has_method("on_authority_explosion"):
			sink.on_authority_explosion(global_position, shooter, explosion_visual)
	if explosion_visual != null:
		var fx: Node = explosion_visual.instantiate()
		fx.global_position = global_position
		get_viewport().add_child(fx)
	# 被炸到的可破坏砖按**破坏单位**播碎片,所有端都播;扫的是与权威扣血同一个 Explosion.destructible_units,
	# 两端粒子落在同一批单位上(榴弹 = 32px 块 ⇒ 一块一簇,不再一块 4 簇)。
	# ★ Explosion 返回的 pos 是 canonical:表现层必须先锚到本地玩家附近的环面副本,否则接缝附近炸出的碎片会画到另一份副本/屏幕外。
	for e in Explosion.destructible_units(global_position, explosion_radius, tile_break_unit):
		var at := _fx_pos(e["pos"])
		TileHitFx.spawn(get_viewport(), at, int(e["tex"]))
		# 爆炸本端已播命中碎片 ⇒ 服务器随后的逐子格破坏事件去重(否则一次爆炸的双份粒子成倍)。
		TileHitFx.mark_hit(at)
	if not apply_damage:
		# 视觉副本(PvP 客户端):apply_aoe 被 gate 掉 ⇒ 爆炸震屏在这里单独补,否则联机里旁边爆炸完全没有震感。
		Explosion.client_cam_shake(global_position, explosion_radius)


# 判定窗口结束:一次且仅一次 apply_aoe(位置/半径/伤害/击退都取爆炸当帧的值;子弹在这 3 帧里被清掉则不会走到这里)。
func _settle_explosion() -> void:
	var s: Node = shooter if is_instance_valid(shooter) else null
	Explosion.apply_aoe(global_position, explosion_radius, explosion_damage, explosion_knockback, s, tile_break_unit)
	queue_free()


# 表现层锚点:离本地玩家最近的那份环面副本(与 _wrap 同一套选择规则)。
# 服务器(headless)上碎片不可见,这里仍照常返回 → 已登记为已知边界,不在此处特判。
func _fx_anchor() -> Node2D:
	var p := get_tree().get_first_node_in_group("player") as Node2D
	if shooter != null and is_instance_valid(shooter) and shooter is Node2D and shooter.is_in_group("player"):
		p = shooter as Node2D
	return p


func _fx_pos(at: Vector2) -> Vector2:
	var p := _fx_anchor()
	if p == null:
		return at
	return MazeGenerator.anchor_to_nearest(at, p.global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)