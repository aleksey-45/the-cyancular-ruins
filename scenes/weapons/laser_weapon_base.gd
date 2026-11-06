class_name LaserWeaponBase
extends WeaponBase


const BeamTrace := preload("res://core/sim/beam_trace.gd")
const HitShape := preload("res://core/sim/hit_shape.gd")
const TileHitFx := preload("res://scenes/effects/tile_hit_fx.gd")
const LaserVisual := preload("res://core/present/laser_visual.gd")


@export var beam_half_width: float = 18.0
@export var beam_lifetime: float = 0.2
@export var tile_chip: int = 8

const HIT_MULT: float = 1.75

enum BeamStyle { FLASH = 0 }

func _spawn_projectiles(base_dir: Vector2) -> void:
	if muzzle == null:
		return
	var origin := muzzle.global_position
	var dir := base_dir.normalized()
	if dir == Vector2.ZERO:
		dir = Vector2(float(get_facing()), 0.0)
	var res := _emit_beam(origin, dir)
	var pts: PackedVector2Array = res["points"]
	var contacts: Array = res["contacts"]
	var hit_points: PackedVector2Array = res["hit_points"]

	_spawn_beam_visual(pts)
	if not _authoritative():
		_spawn_tile_fx(contacts, hit_points)
		return

	_apply_beam_damage(pts, contacts, hit_points)
	_report_beam_fired(pts)

func _authoritative() -> bool:
	return not Level0.pvp_mode

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

func _apply_beam_damage(pts: PackedVector2Array, contacts: Array, hit_points: PackedVector2Array) -> void:
	_damage_path_targets(pts)
	_damage_tiles(contacts, hit_points)

# ── PvP 上报:记录本发权威光束,等 MatchHost 每物理帧轮询取走并清空(读到即清;换枪 free 旧武器时 report 随节点消失,无需额外清理)──
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

func collect_pending_beam_report() -> Dictionary:
	if pending_beam_report.is_empty():
		return {}
	var rep := pending_beam_report
	pending_beam_report = {}
	return rep

func _damage_path_targets(pts: PackedVector2Array) -> void:
	var targets: Array = []
	for t in get_tree().get_nodes_in_group("enemies"):
		if t is Node2D:
			targets.append([t, true])
	var host := player.get_parent() if player != null else null
	var team_aware := host != null and host.has_method("is_friendly")
	for p in get_tree().get_nodes_in_group("player"):
		if not (p is Node2D):
			continue
		if p == player:
			continue
		if p.has_method("is_downed") and p.is_downed():
			continue
		if team_aware and host.is_friendly(player, p):
			continue
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
			var body := _body_rect(n, a, w, h)
			var c := body.get_center()
			var near := _segment_rect_hit(a, b, body.grow(corridor))
			if near.x == INF:
				continue
			if is_enemy:
				_apply_to_enemy(t, c, near)
			else:
				_apply_to_player(t, c, near)

func _body_rect(n: Node2D, near_to: Vector2, w: float, h: float) -> Rect2:
	var r: Rect2 = n.hurt_rect() if n.has_method("hurt_rect") else HitShape.hurt_rect_of(n)
	return HitShape.rect_at(r, near_to, w, h)

# 线段与矩形是否相交;命中返回线段上最近点(击退源),未命中返回 (INF,0)。实现已收进 HitShape(Liang-Barsky 单一来源)。
static func _segment_rect_hit(a: Vector2, b: Vector2, rect: Rect2) -> Vector2:
	return HitShape.segment_entry_point(a, b, rect)

func _apply_to_enemy(t: Node, pos: Vector2, near: Vector2) -> void:
	if not t.has_method("hurt"):
		return
	CombatFeedback.hit_marker()
	var dir := (pos - near).normalized() if pos.distance_to(near) > 1.0 else Vector2.RIGHT
	t.hurt(damage, dir, impact)

func _apply_to_player(p: Node, pos: Vector2, near: Vector2) -> void:
	if not p.has_method("take_hit"):
		return
	CombatFeedback.attribute_hit(p, player)
	p.take_hit(near, damage, false, impact)
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

func _spawn_tile_fx(contacts: Array, hit_points: PackedVector2Array) -> void:
	for t in _tile_contacts(contacts, hit_points):
		var pos: Vector2 = t["pos"]
		TileHitFx.spawn(get_viewport(), pos, int(t["tex"]))
		TileHitFx.mark_hit(pos)

func _damage_tiles(contacts: Array, hit_points: PackedVector2Array) -> void:
	_spawn_tile_fx(contacts, hit_points)
	for t in _tile_contacts(contacts, hit_points):
		TileDefs.damage_tile(t["cell"], tile_chip, "explosion")
