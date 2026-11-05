class_name LaserWeaponBase
extends WeaponBase

# 即时光束类武器基类。开火瞬间由统一射线求几何、由形状扫描求目标，一次性结算伤害与视觉效果。
#
# 扩展接口设计：
# - _emit_beam(origin, dir) -> Dictionary：光束几何（直线、反射、穿透等）
# - _apply_beam_damage(pts, contacts, hit_points)：伤害与地形破坏结算
# - _spawn_beam_visual(pts) / _beam_style()：视觉光束渲染风格
#
# 多人对战的已知光束参与客户端击退预测，伤害由服务端结算。

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
	return TileDefs.terrain.trace_beam(origin, dir, bullet_range, 0)

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

# 光束走廊与实体的接触由 CollisionWorld 一次采完；这里只按目标身份结算。
func _damage_path_targets(pts: PackedVector2Array) -> void:
	if pts.size() < 2 or player == null:
		return
	var corridor := beam_half_width * HIT_MULT
	var world := CollisionWorld.acquire(self)
	# 自己打出的光束不命中自己（本体含镜像槽一起排除）。
	var exclude: Array = [player.get_rid()]
	var mask := CollisionWorld.LAYER_ENEMY | CollisionWorld.LAYER_TEAM_A \
			| CollisionWorld.LAYER_TEAM_B
	var host: Node = player.authority_world
	var seen := {}
	for contact: Dictionary in world.beam_contacts(pts, corridor, mask, exclude):
		var target := _contact_node(contact)
		if target == null or seen.has(target.get_instance_id()):
			continue
		seen[target.get_instance_id()] = true
		var hit: Vector2 = contact["point"]
		if target is EnemyBase:
			_apply_to_enemy(target, hit)
		elif target is Player:
			if target == player or (host != null and host.is_friendly(player, target)) \
					or (target as Player).is_downed():
				continue
			_apply_to_player(target, hit)

# 目标都是真实物理体，碰撞节点直接给出。
func _contact_node(contact: Dictionary) -> Node2D:
	return contact["collider"] as Node2D

func _apply_to_enemy(t: Node, near: Vector2) -> void:
	CombatFeedback.hit_marker()
	var pos: Vector2 = (t as Node2D).global_position
	var dir := (pos - near).normalized() if pos.distance_to(near) > 1.0 else Vector2.RIGHT
	t.hurt(damage, dir, impact)

func _apply_to_player(target: Node, hit: Vector2) -> void:
	if player.authority_world != null:
		player.authority_world.damage(player.role, target.role, hit, damage, false, impact,
				(player.role << 48) | (player.shot_serial << 8), 1)
	else:
		CombatFeedback.attribute_hit(target, player)
		target.take_hit(hit, damage, false, impact)

# 收集折线触点中的可破坏瓦片列表
func _tile_contacts(contacts: Array, hit_points: PackedVector2Array) -> Array:
	var out: Array = []
	var terrain := TileDefs.terrain
	if terrain.empty():
		return out
	var dims := Vector2i(terrain.size() / GameParameters.TILE_SIZE)
	var done := {}
	for idx in range(contacts.size()):
		var cell: Vector2i = contacts[idx]
		if done.has(cell):
			continue
		done[cell] = true
		if cell.y < 0 or cell.y >= dims.y or cell.x < 0 or cell.x >= dims.x:
			continue
		var tex: int = MapFormat.texture_of(terrain.value(cell))
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
	for tile in _tile_contacts(contacts, hit_points):
		TileHitFx.spawn(get_viewport(), tile["pos"], int(tile["tex"]))
		TileDefs.damage_tile(tile["cell"], tile_chip)
