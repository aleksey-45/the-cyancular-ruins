class_name LaserWeaponBase
extends WeaponBase

# 即时光束类武器基类(现:激光枪激光,第6槽)。不开物理子弹 —— WeaponBase.fire() 内衬的
# 出弹循环由本基类整体接管为"开火瞬间用几何追踪算出一束,一次性结算"。
#
# 三个可覆写缝(后续不同行为模式的激光武器据此扩展):
#   缝1 光束几何 _emit_beam(origin, dir) -> Dictionary  —— 这一束长什么样(反射/穿透/扇面/折返…)。
#        基类默认 = 直线 hitscan:BeamTrace.trace(..., max_bounces=0),第一面墙即吸收、否则到 bullet_range。
#   缝2 命中结算 _apply_beam_damage(pts, contacts, hit_points) —— 权威侧怎么结算(路径瞬扫 vs 持续灼烧…)。
#        基类默认 = 逐段扫路径上的敌人/玩家 + 磨可破坏砖(原激光枪语义,原样平移)。
#   缝3 视觉风格 _spawn_beam_visual(pts) / _beam_style() —— 光束/枪口光球怎么画(单发瞬光 vs 持续光束…)。
#        基类默认 = 单发瞬光(LaserVisual FLASH 折线 + 枪口光球)。
# 新激光武器 = 一个 extends LaserWeaponBase 的薄子类 + 场景调参,按需覆写缝;
# 开火编排/视觉/伤害/磨砖/PvP 权威门控与上报全部由基类提供,不再逐枪复制。
#
# PvP:客户端视觉副本只播光束不裁决(_authoritative=false,Level0.pvp_mode=true;伤害由服务器权威结算);
# 服务器权威开火照常结算,并把"本发权威光束"记进 pending_beam_report → MatchHost 每帧轮询广播给
# 非射手客户端(对手本端据此画视觉副本;射手自己客户端已本地预测画自己的光束)。单机无 host 读上报,
# 只留字段无害。上报 dict 可被视觉风格子类覆写 _make_beam_report 加专属字段。

const BeamTrace := preload("res://core/beam_trace.gd")
const TileHitFx := preload("res://scenes/effects/tile_hit_fx.gd")
const LaserVisual := preload("res://core/laser_visual.gd")

# 反射/穿透等几何差异的公共参数(见 _emit_beam 注释);反射次数等子类几何专属参数留在子类。

# ── 光束公共数值(tscn 里按名调)──
# 命中 = 到任一折线段距离 ≤ beam_half_width × HIT_MULT。
@export var beam_half_width: float = 18.0
# 光束视觉存续秒数(tscn 当前 0.25)。
@export var beam_lifetime: float = 0.2
# 对可破坏砖单次扣血量(树叶/树干用 "explosion" 语义,不穿墙只磨)。
@export var tile_chip: int = 8

# 命中判据(每段):折线线段与目标**实际身体 AABB**(由启用中的碰撞多边形算出,含 2.5x 缩放)
# 外扩 beam_half_width×HIT_MULT 后相交即中——激光线穿过身体任一部分都算,不再要求中心点贴线。
# (早前用"中心点到线距离 ≤ 半径+半身",身体大而激光细 → 线扫过身体上半但中心离得远就整只漏判。)
const HIT_MULT: float = 1.75

enum BeamStyle { FLASH = 0 }   # 预留视觉风格;目前只有"单发瞬光"

# ── 开火编排(接管 WeaponBase._spawn_projectiles)──
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

	# 视觉(所有端都播;服务器 headless 播也无害,与子弹视觉先例一致)
	_spawn_beam_visual(pts)
	if not _authoritative():
		return

	# 缝2:权威侧结算(伤害/磨砖)
	_apply_beam_damage(pts, contacts, hit_points)
	# PvP 上报:服务器权威开火记下本发光束,MatchHost 每帧轮询广播给非射手客户端
	_report_beam_fired(pts)

# PvP 门控:与基类出弹一致。Level0.pvp_mode=true(客户端视觉副本)→ 不裁决伤害;
# 单机与 PvP 服务器进程都不实例化 Level0 场景、pvp_mode 恒 false → 权威结算 + 上报。
func _authoritative() -> bool:
	return not Level0.pvp_mode

# ── 缝1:光束几何(子类覆写)。默认=直线 hitscan(max_bounces=0:第一面墙即吸收/到射程)──
# 返回 BeamTrace.trace 同构 {"points", "contacts", "hit_points"}(折线/碰墙 64px 格/碰面点)。
# 穿透激光 = 返回穿墙直折线、contacts 置空(不磨砖);扇面/多束 = 返回多段折线并连带覆写 _apply_beam_damage。
func _emit_beam(origin: Vector2, dir: Vector2) -> Dictionary:
	return BeamTrace.trace(origin, dir, bullet_range, 0)

# ── 缝3:视觉风格(子类覆写)。默认=单发瞬光 ──
func _spawn_beam_visual(pts: PackedVector2Array) -> void:
	if pts.size() < 2:
		return
	var style := _beam_style()
	LaserVisual.spawn_muzzle_orb(get_viewport(), pts[0], laser_color, beam_half_width, beam_lifetime)
	LaserVisual.spawn_beam(get_viewport(), pts, beam_half_width, laser_color, beam_lifetime, style)

# 视觉风格标识(进上报 dict,PvP 远端据此选 LaserVisual 分支)。持续光束等子类覆写为其他值并扩展上报。
func _beam_style() -> int:
	return BeamStyle.FLASH

# ── 缝2:命中结算(子类覆写)。默认=逐段扫路径 + 磨砖(原激光枪语义)──
# 持续/灼烧型覆写本方法(仍可自调 _damage_tiles);注意扫路径结算不是每目标一次/每发一次,
# 而是"每段折线各结算一次"(同原实现:反射折返扫到同一目标多次可叠加)。
func _apply_beam_damage(pts: PackedVector2Array, contacts: Array, hit_points: PackedVector2Array) -> void:
	_damage_path_targets(pts)
	_damage_tiles(contacts, hit_points)

# ── PvP 上报:记录本发权威光束,等 MatchHost 每帧轮询(collect_pending_beam_report 读到即清)──
var pending_beam_report: Dictionary = {}

func _report_beam_fired(pts: PackedVector2Array) -> void:
	pending_beam_report = _make_beam_report(pts)

# 可覆写:视觉风格子类往上报 dict 加专属字段(如持续光束的 id/末端语义),PvP 远端据此渲染。
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

# MatchHost 每物理帧轮询:非空即取走并清空(换枪 free 旧武器时 report 随节点消失,无需额外清理)。
func collect_pending_beam_report() -> Dictionary:
	if pending_beam_report.is_empty():
		return {}
	var rep := pending_beam_report
	pending_beam_report = {}
	return rep

# ── 默认路径伤害扫描(每段折线对目标做"身体 AABB × 线段相交",原激光枪逻辑逐字平移)──
# 收集目标(敌人 + 除射手外的玩家),每段折线独立判定:同一目标被反射折返的多段扫到 → 各段各结算一次(可叠加)。
func _damage_path_targets(pts: PackedVector2Array) -> void:
	var targets: Array = []
	for t in get_tree().get_nodes_in_group("enemies"):
		if t is Node2D:
			targets.append([t, true])
	for p in get_tree().get_nodes_in_group("player"):
		if not (p is Node2D):
			continue
		if p == player:  # 射手本人不吃自己这发
			continue
		if p.has_method("is_downed") and p.is_downed():
			continue
		targets.append([p, false])

	var w := GameParameters.MAP_WIDTH
	var h := GameParameters.MAP_HEIGHT
	var corridor := beam_half_width * HIT_MULT
	# 每段折线独立判定
	for i in range(pts.size() - 1):
		var a := pts[i]
		var b := pts[i + 1]
		for tg in targets:
			var t: Node = tg[0]
			var is_enemy: bool = tg[1]
			var n := t as Node2D
			# 身体 AABB 中心锚到本段起点副本(段足够短,量距一致;跨接缝量近副本)
			var c := MazeGenerator.anchor_to_nearest(n.global_position, a, w, h)
			var half := _body_half(n) + Vector2(corridor, corridor)
			var near := _segment_rect_hit(a, b, Rect2(c - half, half * 2.0))
			if near.x == INF:  # 未穿过身体框
				continue
			if is_enemy:
				_apply_to_enemy(t, c, near)
			else:
				_apply_to_player(t, c, near)

# 目标在世界系的半身(px):扫它启用中的 CollisionPolygon2D / CollisionShape2D 得世界 AABB 半宽高。
# 兼容姿态碰撞箱(玩家/飞鸟站/飞多碰撞体,只取非 disabled 的那个)。兜底 18px(近似半身)。
func _body_half(n: Node2D) -> Vector2:
	var minv := Vector2(INF, INF)
	var maxv := Vector2(-INF, -INF)
	var found := false
	for child in n.get_children():
		if child is CollisionPolygon2D and not (child as CollisionPolygon2D).disabled:
			for v in (child as CollisionPolygon2D).polygon:
				var wp := (child as CollisionPolygon2D).to_global(v)
				minv = Vector2(minf(minv.x, wp.x), minf(minv.y, wp.y))
				maxv = Vector2(maxf(maxv.x, wp.x), maxf(maxv.y, wp.y))
				found = true
		elif child is CollisionShape2D and not (child as CollisionShape2D).disabled:
			var shape := (child as CollisionShape2D).shape
			if shape is RectangleShape2D:
				var hs := (shape as RectangleShape2D).size * 0.5
				for corner in [Vector2(-hs.x, -hs.y), Vector2(hs.x, -hs.y), Vector2(hs.x, hs.y), Vector2(-hs.x, hs.y)]:
					var wp := (child as CollisionShape2D).to_global(corner)
					minv = Vector2(minf(minv.x, wp.x), minf(minv.y, wp.y))
					maxv = Vector2(maxf(maxv.x, wp.x), maxf(maxv.y, wp.y))
					found = true
	if not found:
		return Vector2(18, 18)
	return (maxv - minv) * 0.5

# 线段与矩形是否相交;命中返回线段上最近点(击退源),未命中返回 (INF,0)。
# 实现:矩形外扩(其实调用方已外扩 corridor,此处即精确矩形)逐轴裁剪线段参数区间。
static func _segment_rect_hit(a: Vector2, b: Vector2, rect: Rect2) -> Vector2:
	var d := b - a
	var t0 := 0.0
	var t1 := 1.0
	var pmin := rect.position
	var pmax := rect.position + rect.size
	# 逐轴 Liang-Barsky:更新 t0/t1
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
	# 击杀归因:必须在 hurt 之前写 —— hurt 可能同帧判死,EnemyBase._begin_death 当场读
	# last_damager 播报「击杀 XXX」;写在 hurt 之后则 meta 尚不存在 → 播报静默丢失。
	# 射手 = 武器持有者(WeaponBase.player,equip() 写入;同 _make_beam_report/_damage_path_targets 的射手判定)。
	CombatFeedback.attribute(t, player)   # 归因写端统一入口(含归因时效戳,CombatFeedback 3s 窗口)
	# 击退方向 = 从光束最近点指向目标(径向推离光束);强度走 impact。
	var dir := (pos - near).normalized() if pos.distance_to(near) > 1.0 else Vector2.RIGHT
	t.hurt(damage, dir, impact)

func _apply_to_player(p: Node, pos: Vector2, near: Vector2) -> void:
	if not p.has_method("take_hit"):
		return
	# 击杀归因(同爆炸 apply_aoe 的玩家分支):PvP 大乱斗读 last_damager 判击杀分;
	# 必须写在 take_hit 之前 —— 本方受伤方倒地/死亡当帧的归因读取者才看得到。
	CombatFeedback.attribute(p, player)   # 归因写端统一入口
	# 与爆炸 apply_aoe 一致:take_hit(source_pos, damage, ignore_iframes, knockback)。
	# source_pos 传光束最近点 → 击退沿"光束→目标"径向;ignore_iframes 用 false(激光可被无敌帧挡)。
	p.take_hit(near, damage, false, impact)

# 对碰墙触点里的可破坏砖扣血(树叶/树干,"explosion" 语义不穿墙)。只磨不破:砖血扣到 0
# 变空气由 damage_tile 回调 Level0 处理,下一发射击自然穿过。同一格单发只扣一次。
# 真正扣到血(explosion_destroyable)的砖 → 在触点播 TileHitFx 碎片粒子。
func _damage_tiles(contacts: Array, hit_points: PackedVector2Array) -> void:
	var grid := MazeGenerator.current_grid
	if grid.is_empty():
		return
	var done := {}
	for idx in range(contacts.size()):
		var cell: Vector2i = contacts[idx]
		if done.has(cell):
			continue
		done[cell] = true
		if cell.y < 0 or cell.y >= grid.size() or cell.x < 0 or cell.x >= grid[cell.y].size():
			continue
		var tex: int = grid[cell.y][cell.x] / 16
		if not TileDefs.explosion_destroyable(tex):
			continue
		# 播粒子(所有端都可播视觉;PvP 拆格由服务器 tile_destroyed 驱动,本方法只在权威侧调用)
		if idx < hit_points.size():
			TileHitFx.spawn(get_viewport(), hit_points[idx], tex)
		TileDefs.damage_tile(cell, tile_chip, "explosion")
