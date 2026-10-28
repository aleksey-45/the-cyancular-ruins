class_name LaserWeaponBase
extends WeaponBase

# 即时光束类武器基类。开火瞬间执行几何追踪并一次性结算伤害与视觉效果。
#
# 扩展接口设计：
# - _emit_beam(origin, dir) -> Dictionary：光束几何计算（直线、反射、穿透等）
# - _apply_beam_damage(pts, contacts, hit_points)：伤害与地形破坏结算
# - _spawn_beam_visual(pts) / _beam_style()：视觉光束渲染风格
#
# 多人对战的已知光束参与客户端击退预测，伤害由服务端结算。

const BeamTrace := preload("res://core/sim/beam_trace.gd")
const TileHitFx := preload("res://scenes/effects/tile_hit_fx.gd")
const LaserVisual := preload("res://core/present/laser_visual.gd")

# 判定宽度半径（像素）
@export var beam_half_width: float = 18.0
# 光束视觉残留时长（秒）
@export var beam_lifetime: float = 0.2
# 对可破坏瓦片的单次破坏伤害值
@export var tile_chip: int = 8

# 判定宽度乘数
const HIT_MULT: float = 1.75

enum BeamStyle { FLASH = 0 }

func _spawn_projectiles(action: Dictionary) -> void:
	var origin: Vector2 = action["pos"]
	var dir: Vector2 = action["dir"].normalized()
	if dir == Vector2.ZERO:
		dir = Vector2(float(get_facing()), 0.0)
	var res := _emit_beam(origin, dir)
	var pts: PackedVector2Array = res["points"]
	var contacts: Array = res["contacts"]
	var hit_points: PackedVector2Array = res["hit_points"]

	if player.authority_world == null:
		_spawn_beam_visual(pts)
	if not _authoritative():
		_spawn_tile_fx(contacts, hit_points)
		return

	_apply_beam_damage(pts, contacts, hit_points)
	_report_beam_fired(pts)

func _authoritative() -> bool:
	return player.authority_world != null or not Level0.pvp_mode

# 计算光束几何折线（默认单段直线，碰撞障碍物即停止）
func _emit_beam(origin: Vector2, dir: Vector2) -> Dictionary:
	return BeamTrace.trace(origin, dir, bullet_range, 0)

# 生成光束视觉特效
func _spawn_beam_visual(pts: PackedVector2Array) -> void:
	if pts.size() < 2:
		return
	var style := _beam_style()
	LaserVisual.spawn_muzzle_orb(get_viewport(), pts[0], laser_color, beam_half_width, beam_lifetime)
	LaserVisual.spawn_beam(get_viewport(), pts, beam_half_width, laser_color, beam_lifetime, style)

func _beam_style() -> int:
	return BeamStyle.FLASH

# 结算光束伤害与地形破坏
func _apply_beam_damage(pts: PackedVector2Array, contacts: Array, hit_points: PackedVector2Array) -> void:
	_damage_path_targets(pts)
	_damage_tiles(contacts, hit_points)

var pending_beam_report: Dictionary = {}

func _report_beam_fired(pts: PackedVector2Array) -> void:
	pending_beam_report = _make_beam_report(pts)

func _make_beam_report(pts: PackedVector2Array) -> Dictionary:
	return {
		"pts": pts,
		"origin": pts[0] if not pts.is_empty() else Vector2.ZERO,
		"canonical": player.global_position if player != null else Vector2.ZERO,
		"color": laser_color,
		"half_width": beam_half_width,
		"lifetime": beam_lifetime,
		"style": _beam_style(),
	}

# 获取并清空待同步的光束数据
func collect_pending_beam_report() -> Dictionary:
	if pending_beam_report.is_empty():
		return {}
	var rep := pending_beam_report
	pending_beam_report = {}
	return rep

# 检测折线路径上的目标并结算伤害
func _damage_path_targets(pts: PackedVector2Array) -> void:
	var targets: Array = []
	for t in get_tree().get_nodes_in_group("enemies"):
		if t is Node2D:
			targets.append([t, true])
	var host: Node = player.authority_world
	for p in get_tree().get_nodes_in_group("player"):
		if not (p is Node2D):
			continue
		if p == player:
			continue
		if p.has_method("is_downed") and p.is_downed():
			continue
		if host != null and host.is_friendly(player, p):
			continue
		targets.append([p, false])

	var w := GameParameters.MAP_WIDTH
	var h := GameParameters.MAP_HEIGHT
	var corridor := beam_half_width * HIT_MULT
	for tg in targets:
		var target: Node2D = tg[0]
		var rect := _body_rect(target, pts[0], w, h)
		var near := path_contact(pts, rect, corridor)
		if near.x == INF: continue
		if tg[1]:
			_apply_to_enemy(target, rect.get_center(), near)
		else:
			_apply_to_player(target, rect.get_center(), near)

static func path_contact(points: PackedVector2Array, rect: Rect2, corridor: float) -> Vector2:
	for i in range(points.size() - 1):
		var center := GridPathfinder.anchor_to_nearest(rect.get_center(), points[i],
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		var anchored := Rect2(center - rect.size * 0.5, rect.size)
		var near := _segment_rect_hit(points[i], points[i + 1], anchored.grow(corridor))
		if near.x != INF: return near
	return Vector2(INF, 0.0)

# 获取目标在环面世界中的 AABB 包围盒（锚定至距起点最近的副本位置）
func _body_rect(n: Node2D, near_to: Vector2, w: float, h: float) -> Rect2:
	var r := Rect2(n.global_position - Vector2(18, 18), Vector2(36, 36))
	if CollisionAabb.has_any(n):
		r = CollisionAabb.world_rect(n)
	if n.is_in_group("player") and player.authority_world != null:
		r = player.authority_world.target_rect_at(n, player)
	var c := MazeGenerator.anchor_to_nearest(r.get_center(), near_to, w, h)
	return Rect2(c - r.size * 0.5, r.size)

# 线段与矩形相交检测（Liang-Barsky 算法），返回线段上的交点或最近点
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
	CombatFeedback.hit_marker()
	var dir := (pos - near).normalized() if pos.distance_to(near) > 1.0 else Vector2.RIGHT
	t.hurt(damage, dir, impact)

func _apply_to_player(target: Node, _pos: Vector2, hit: Vector2) -> void:
	if player.authority_world != null:
		player.authority_world.damage(player.role, target.role, hit, damage, false, impact,
				(player.role << 48) | (player.shot_serial << 8), 1)
	else:
		CombatFeedback.attribute_hit(target, player)
		target.take_hit(hit, damage, false, impact)

# 收集折线触点中的可破坏瓦片列表
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

# 生成瓦片受击碎屑粒子
func _spawn_tile_fx(contacts: Array, hit_points: PackedVector2Array) -> void:
	for t in _tile_contacts(contacts, hit_points):
		var pos: Vector2 = t["pos"]
		TileHitFx.spawn(get_viewport(), pos, int(t["tex"]))

# 对触点瓦片结算破坏伤害
func _damage_tiles(contacts: Array, hit_points: PackedVector2Array) -> void:
	_spawn_tile_fx(contacts, hit_points)
	for t in _tile_contacts(contacts, hit_points):
		TileDefs.damage_tile(t["cell"], tile_chip, "explosion")
