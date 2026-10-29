class_name LaserWeaponBase
extends WeaponBase

# 即时光束类武器基类(现:激光枪激光,第 6 槽):不走物理子弹,开火瞬间用几何追踪算出一束,一次性结算。
# 三个可覆写缝:缝1 光束几何 _emit_beam(origin, dir)(默认直线 hitscan:第一面墙即吸收,否则到 bullet_range);缝2 命中结算 _apply_beam_damage(pts, contacts, hit_points)(默认逐段扫路径上的敌人/玩家 + 磨可破坏砖);缝3 视觉风格 _spawn_beam_visual(pts) 与 _beam_style()(默认单发瞬光)。
# 新激光武器 = 一个 extends LaserWeaponBase 的薄子类 + 场景调参,按需覆写缝;开火编排/视觉/伤害/磨砖/PvP 权威门控与上报全部由基类提供。
# PvP:客户端视觉副本只播光束不裁决(_authoritative=false),服务器权威开火照常结算并把本发权威光束记进 pending_beam_report → MatchHost 每帧轮询广播给非射手客户端;单机无 host 读上报,只留字段无害。

const BeamTrace := preload("res://core/sim/beam_trace.gd")
const TileHitFx := preload("res://scenes/effects/tile_hit_fx.gd")
const LaserVisual := preload("res://core/present/laser_visual.gd")


# ── 光束公共数值(tscn 里按名调)── 命中 = 到任一折线段距离 ≤ beam_half_width × HIT_MULT。
@export var beam_half_width: float = 18.0
@export var beam_lifetime: float = 0.2
# 对可破坏砖单次扣血量(树叶/树干用 explosion 语义,不穿墙只磨)。
@export var tile_chip: int = 8

# 命中判据(每段):折线线段与目标实际身体 AABB(由启用中的碰撞多边形算出,含 2.5x 缩放,见 _body_rect)外扩 beam_half_width×HIT_MULT 后相交即中 —— 激光线穿过身体任一部分都算,不再要求中心点贴线。
# ★ 早前这条判据并不生效:CollisionAabb 认不出多边形时身体框一直是原点周围 36×36 的兜底值,修好后判定才第一次落在身体上。
const HIT_MULT: float = 1.75

enum BeamStyle { FLASH = 0 }   # 预留视觉风格;目前只有"单发瞬光"

func _spawn_projectiles(base_dir: Vector2) -> void:
	if muzzle == null:
		return
	var origin := muzzle.global_position
	var dir := base_dir.normalized()
	if dir == Vector2.ZERO:
		dir = Vector2(float(get_facing()), 0.0)
	var res := _emit_beam(origin, dir)   # 缝1:这一发几何(反射/穿透…)
	var pts: PackedVector2Array = res["points"]
	var contacts: Array = res["contacts"]
	var hit_points: PackedVector2Array = res["hit_points"]

	_spawn_beam_visual(pts)
	if not _authoritative():
		# PvP 客户端不裁决伤害(拆墙由服务器 tile_destroyed 驱动),但砖块受击粒子是纯反馈,与子弹同口径照播 —— 否则同一局里子弹打砖有碎片、激光打砖零反馈。
		_spawn_tile_fx(contacts, hit_points)
		return

	_apply_beam_damage(pts, contacts, hit_points)
	_report_beam_fired(pts)

# PvP 门控:Level0.pvp_mode=true(客户端视觉副本)⇒ 不裁决伤害;单机与 PvP 服务器进程都不实例化 Level0 场景、pvp_mode 恒 false ⇒ 权威结算 + 上报。
func _authoritative() -> bool:
	return not Level0.pvp_mode

# ── 缝1:光束几何(子类覆写)。默认 = 直线 hitscan(max_bounces=0:第一面墙即吸收/到射程)──
# 返回 BeamTrace.trace 同构的三键(points / contacts / hit_points);穿透激光 = 返回穿墙直折线、contacts 置空(不磨砖);扇面/多束 = 返回多段折线并连带覆写 _apply_beam_damage。
func _emit_beam(origin: Vector2, dir: Vector2) -> Dictionary:
	return BeamTrace.trace(origin, dir, bullet_range, 0)

func _spawn_beam_visual(pts: PackedVector2Array) -> void:
	if pts.size() < 2:
		return
	var style := _beam_style()
	LaserVisual.spawn_muzzle_orb(get_viewport(), pts[0], laser_color, beam_half_width, beam_lifetime)
	LaserVisual.spawn_beam(get_viewport(), pts, beam_half_width, laser_color, beam_lifetime, style)

func _beam_style() -> int:
	return BeamStyle.FLASH

# ── 缝2:命中结算(子类覆写)。默认 = 逐段扫路径 + 磨砖(原激光枪语义)── 注意结算粒度是每段折线各一次,不是每目标一次/每发一次:反射折返扫到同一目标多次可叠加。
func _apply_beam_damage(pts: PackedVector2Array, contacts: Array, hit_points: PackedVector2Array) -> void:
	_damage_path_targets(pts)
	_damage_tiles(contacts, hit_points)

# ── PvP 上报:记录本发权威光束,等 MatchHost 每物理帧轮询取走并清空(读到即清;换枪 free 旧武器时 report 随节点消失,无需额外清理)──
var pending_beam_report: Dictionary = {}

func _report_beam_fired(pts: PackedVector2Array) -> void:
	pending_beam_report = _make_beam_report(pts)

# 可覆写:视觉风格子类往上报 dict 加专属字段,PvP 远端据此渲染。
func _make_beam_report(pts: PackedVector2Array) -> Dictionary:
	return {
		"pts": pts,   # 射手副本连续系原始折线(长度 ≤ bullet_range,远小于半图,跨接缝安全)
		"origin": pts[0] if not pts.is_empty() else Vector2.ZERO,
		"canonical": player.global_position if player != null else Vector2.ZERO,  # 射手 canonical 中心
		"color": laser_color,
		"half_width": beam_half_width,
		"lifetime": beam_lifetime,
		"style": _beam_style(),
	}

func collect_pending_beam_report() -> Dictionary:
	if pending_beam_report.is_empty():
		return {}
	var rep := pending_beam_report
	pending_beam_report = {}
	return rep

# ── 默认路径伤害扫描(每段折线对目标做身体 AABB × 线段相交)── 每段独立判定:同一目标被反射折返的多段扫到,各段各结算一次(可叠加)。
func _damage_path_targets(pts: PackedVector2Array) -> void:
	var targets: Array = []
	for t in get_tree().get_nodes_in_group("enemies"):
		if t is Node2D:
			targets.append([t, true])
	# ★ 宿主的队伍判据与 notify_direct_hit 同一条形状:单机下 player.get_parent() 是 WorldViewport、has_method(is_friendly) 为假 ⇒ team_aware 为假,行为与改动前逐字相同;PvP 服务器下父节点是 MatchHost(继承 MatchState)⇒ 判据可用。
	var host := player.get_parent() if player != null else null
	var team_aware := host != null and host.has_method("is_friendly")
	for p in get_tree().get_nodes_in_group("player"):
		if not (p is Node2D):
			continue
		if p == player:  # 射手本人不吃自己这发
			continue
		if p.has_method("is_downed") and p.is_downed():
			continue
		if team_aware and host.is_friendly(player, p):
			continue     # ★ 队友穿透:与子弹/榴弹直击同口径(不伤害、也不挡光束)
		targets.append([p, false])

	var w := GameParameters.MAP_WIDTH
	var h := GameParameters.MAP_HEIGHT
	var corridor := beam_half_width * HIT_MULT
	for i in range(pts.size() - 1):
		var a := pts[i]
		var b := pts[i + 1]
		for tg in targets:
			var t: Node = tg[0]
			var is_enemy: bool = tg[1]
			var n := t as Node2D
			# 身体框锚到本段起点最近的副本(段足够短,量距一致;跨接缝量近副本),再外扩 corridor。
			var body := _body_rect(n, a, w, h)
			var c := body.get_center()
			var near := _segment_rect_hit(a, b, body.grow(corridor))
			if near.x == INF:  # 未穿过身体框
				continue
			if is_enemy:
				_apply_to_enemy(t, c, near)
			else:
				_apply_to_player(t, c, near)

# 目标身体在世界系的方框(px),中心已锚到 near_to 最近的环面副本;几何取自 CollisionAabb(只并启用中的碰撞体,兼容玩家/飞鸟的多姿态碰撞箱),无碰撞体时兜底 18px 半身、以节点原点为中心。
# ★ 必须用带 position 的整框 —— 身体框中心不在节点原点(跳鸟偏低约 8px、黑影偏低约 5px),只取 size 再以原点为中心会让整框错位。
func _body_rect(n: Node2D, near_to: Vector2, w: float, h: float) -> Rect2:
	var r := Rect2(n.global_position - Vector2(18, 18), Vector2(36, 36))
	if CollisionAabb.has_any(n):
		r = CollisionAabb.world_rect(n)
	var c := MazeGenerator.anchor_to_nearest(r.get_center(), near_to, w, h)
	return Rect2(c - r.size * 0.5, r.size)

# 线段与矩形是否相交;命中返回线段上最近点(击退源),未命中返回 (INF,0)。实现:矩形逐轴裁剪线段参数区间(Liang-Barsky)。
static func _segment_rect_hit(a: Vector2, b: Vector2, rect: Rect2) -> Vector2:
	var d := b - a
	var t0 := 0.0
	var t1 := 1.0
	var pmin := rect.position
	var pmax := rect.position + rect.size
	for axis in range(2):
		var p := a[axis]
		var dd := d[axis]
		var lo := pmin[axis]
		var hi := pmax[axis]
		if absf(dd) < 1e-9:
			if p < lo or p > hi:
				return Vector2(INF, 0.0)
		else:
			var ta := (lo - p) / dd
			var tb := (hi - p) / dd
			if ta > tb:
				var tmp := ta
				ta = tb
				tb = tmp
			t0 = maxf(t0, ta)
			t1 = minf(t1, tb)
			if t0 > t1:
				return Vector2(INF, 0.0)
	return a + d * t0

func _apply_to_enemy(t: Node, pos: Vector2, near: Vector2) -> void:
	if not t.has_method("hurt"):
		return
	# 命中标记(X)。★ 敌人侧不写归因(那个 meta 的唯一读者是单机击杀播报,已随播报删除);本函数只在权威侧被调,headless 服务器无 CombatFeedback 实例时为空操作。
	CombatFeedback.hit_marker()
	# 击退方向 = 从光束最近点指向目标(径向推离光束);强度走 impact。
	var dir := (pos - near).normalized() if pos.distance_to(near) > 1.0 else Vector2.RIGHT
	t.hurt(damage, dir, impact)

func _apply_to_player(p: Node, pos: Vector2, near: Vector2) -> void:
	if not p.has_method("take_hit"):
		return
	# 归因 + 命中标记的一体入口(同爆炸 apply_aoe 的玩家分支):PvP 大乱斗读 last_damager 判击杀分;★ 必须写在 take_hit 之前,本方受伤方倒地/死亡当帧的归因读取者才看得到。
	CombatFeedback.attribute_hit(p, player)
	# 与爆炸 apply_aoe 一致:take_hit(source_pos, damage, ignore_iframes, knockback);source_pos 传光束最近点 ⇒ 击退沿光束→目标径向;ignore_iframes 用 false(激光可被无敌帧挡)。
	p.take_hit(near, damage, false, impact)
	# 激光直击的命中确认:把「你打中了」告诉射手本人(MatchHost.notify_direct_hit 经 Wire.hit_confirm 发出),放在 take_hit 之后;单机下 player 的父节点是 WorldViewport ⇒ has_method 为假 ⇒ 自动跳过。
	var host := player.get_parent() if player != null else null
	if host != null and host.has_method("notify_direct_hit"):
		host.notify_direct_hit(player, p)

# 碰墙触点里值得处理的可破坏砖:去重 + 越界过滤 + 可破坏判定,纯查询不改状态;扣血(权威侧)与播粒子(所有端)共用同一份扫描,两端表现同源。
func _tile_contacts(contacts: Array, hit_points: PackedVector2Array) -> Array:
	var out: Array = []
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return out
	var done := {}
	for idx in range(contacts.size()):
		var cell: Vector2i = contacts[idx]
		if done.has(cell):
			continue
		done[cell] = true
		if cell.y < 0 or cell.y >= grid.size() or cell.x < 0 or cell.x >= grid[cell.y].size():
			continue
		var tex: int = MazeGenerator.texture_of(grid[cell.y][cell.x])
		if not TileDefs.explosion_destroyable(tex):
			continue
		out.append({"cell": cell, "tex": tex,
				"pos": hit_points[idx] if idx < hit_points.size() else Vector2.ZERO})
	return out

# 触点的受击碎片,所有端都播(与 bullet_base 的 TileHitFx 同口径):PvP 客户端本地激光不裁决伤害,但粒子是纯反馈 —— 此前那句 if not _authoritative(): return 把它一起吞掉,于是子弹打砖有碎片、激光打砖零反馈。
func _spawn_tile_fx(contacts: Array, hit_points: PackedVector2Array) -> void:
	for t in _tile_contacts(contacts, hit_points):
		var pos: Vector2 = t["pos"]
		TileHitFx.spawn(get_viewport(), pos, int(t["tex"]))

# 对碰墙触点里的可破坏砖扣血(树叶/树干,explosion 语义不穿墙):只磨不破,砖血扣到 0 变空气由 damage_tile 回调 Level0 处理,下一发射击自然穿过;同一格单发只扣一次(扫描跑两遍:一遍播粒子一遍扣血,触点只有几个)。
func _damage_tiles(contacts: Array, hit_points: PackedVector2Array) -> void:
	_spawn_tile_fx(contacts, hit_points)
	for t in _tile_contacts(contacts, hit_points):
		TileDefs.damage_tile(t["cell"], tile_chip, "explosion")
