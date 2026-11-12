class_name ShotRules
extends RefCounted

static func projectiles(combat: CombatSimulator, actor: Player, shot: Dictionary, spec: Dictionary) -> void:
	var id := shot_id(actor.role, shot["serial"])
	var velocities := projectile_velocities(actor.role, shot, spec, actor.pvp_haste_mult)
	var damage := attack_damage(spec, shot["charge"])
	for pellet in velocities.size():
		combat.spawn_projectile(id | pellet, shot["type_id"], actor.get_instance_id(),
				shot["pos"], velocities[pellet], damage)

static func shot_id(role: int, serial: int) -> int:
	return (role << 48) | (serial << 8)

static func attack_damage(spec: Dictionary, charge: float) -> int:
	return roundi(lerpf(spec.get("min_damage", spec["damage"]), spec["damage"], charge))

static func launch_speed(spec: Dictionary, charge: float) -> float:
	var speed: float = spec["speed"]
	return lerpf(spec.get("min_speed", speed), speed, charge)

static func projectile_velocities(role: int, shot: Dictionary, spec: Dictionary, speed_mult: float) -> Array[Vector2]:
	var rng := RandomNumberGenerator.new()
	rng.seed = ("%d:%d" % [role, shot["serial"]]).hash()
	var spread := deg_to_rad(spec["spread"])
	var direction: Vector2 = shot["dir"]
	var speed := launch_speed(spec, shot["charge"]) * speed_mult
	var velocities: Array[Vector2] = []
	for _pellet in int(spec["count"]):
		var angle := direction.angle() + rng.randf_range(-spread, spread)
		velocities.append(Vector2.from_angle(angle) * speed)
	return velocities

static func flight_velocity(terrain: Terrain, at: Vector2, velocity: Vector2, gravity: float, delta: float) -> Vector2:
	velocity.y += GameParameters.gravity0 * gravity * delta
	return velocity * Water.bullet_drag_factor(terrain.water(at), GameParameters.water_bullet_drag, delta)

static func trace_arc(terrain: Terrain, at: Vector2, velocity: Vector2, spec: Dictionary,
		delta: float, duration: float) -> PackedVector2Array:
	var points := PackedVector2Array([at])
	var distance_left: float = spec["range"]
	var gravity: float = spec["gravity"]
	for _step in ceili(duration / delta):
		velocity = flight_velocity(terrain, at, velocity, gravity, delta)
		var motion := velocity * delta
		if not terrain.line_of_sight(at, at + motion):
			break
		at += motion
		points.append(at)
		distance_left -= motion.length()
		if distance_left <= 0.0:
			break
	return points

static func trace_beam(map: Terrain, shot: Dictionary, spec: Dictionary) -> Dictionary:
	return map.trace_beam(shot["pos"], shot["dir"], spec["range"], spec["bounces"])

static func melee(combat: CombatSimulator, actor: Player, shot: Dictionary, spec: Dictionary) -> void:
	var start: Vector2 = shot["pos"]
	var end: Vector2 = start + shot["dir"] * spec["range"]
	_hit_corridor(combat, actor, shot, spec, PackedVector2Array([start, end]), true)

static func _hit_corridor(combat: CombatSimulator, shooter: Player, shot: Dictionary, spec: Dictionary,
		points: PackedVector2Array, block_walls: bool) -> void:
	var damage := attack_damage(spec, shot["charge"])
	var space := CollisionWorld.for_space(combat.terrain.space_rid())
	var contacts := space.corridor_contacts(points, spec["hit_radius"], CombatSimulator.ACTOR_LAYERS, [shooter.get_rid()])
	for contact: Dictionary in contacts:
		var target: Node2D = contact["target"]
		if block_walls and not combat.terrain.line_of_sight(points[0], target.global_position):
			continue
		var at: Vector2 = points[0] if block_walls else contact["point"]
		combat.resolve_hit(shooter, target, CombatProfiles.DIRECT, at, damage, spec["impact"],
				combat.hit_direction(at, target.global_position))

static func beam(combat: CombatSimulator, shooter: Player, shot: Dictionary, spec: Dictionary) -> void:
	var terrain := combat.terrain
	var trace := trace_beam(terrain, shot, spec)
	var points: PackedVector2Array = trace["points"]
	_hit_corridor(combat, shooter, shot, spec, points, false)
	var seen := {}
	var cells: Array = trace["contacts"]
	for index in cells.size():
		var cell: Vector2i = cells[index]
		if seen.has(cell):
			continue
		seen[cell] = true
		var tex := MapFormat.texture_of(terrain.value(cell))
		if TileDefs.explosion_destroyable(tex):
			combat.tile_hit.emit(trace["hit_points"][index], tex)
			terrain.damage_tile(cell, spec["tile_chip"], 1, shooter.role)
	combat.beam_fired.emit(shot_id(shooter.role, shot["serial"]), shot, points)

static func step_projectile(combat: CombatSimulator, bullet: BulletBody, delta: float, pvp: bool) -> void:
	var advance := bullet.advance_physics(delta)
	match advance:
		BulletBody.AdvanceResult.TERRAIN_HIT, BulletBody.AdvanceResult.ACTOR_HIT:
			var response: Dictionary = bullet.definition["wall" if advance == BulletBody.AdvanceResult.TERRAIN_HIT else "actor"]
			var incoming := bullet.velocity_vec
			if response["fuse"] > 0.0:
				bullet.start_fuse(response["fuse"])
			if response["bounce"]:
				bullet.bounce(bullet.impact_normal)
			match response["effect"]:
				CombatProfiles.ContactEffect.CHIP_SUB:
					var tex := combat.terrain.damage_impact(bullet.impact_point, bullet.impact_normal,
							bullet.hit_damage, CombatSimulator.source_role(bullet.shooter))
					if tex != 0:
						combat.tile_hit.emit(bullet.impact_point, tex)
				CombatProfiles.ContactEffect.HIT:
					_projectile_hit(combat, bullet, incoming, pvp)
			if not response["bounce"]:
				combat.erase_projectile(bullet.entity_id)
				combat.projectile_ended.emit(bullet.entity_id)
		BulletBody.AdvanceResult.FUSE_END, BulletBody.AdvanceResult.RANGE_END:
			var blast: Dictionary = bullet.definition["blast"]
			combat.erase_projectile(bullet.entity_id)
			if blast.is_empty():
				combat.projectile_ended.emit(bullet.entity_id)
			else:
				combat.submit_blast(bullet.entity_id, bullet.global_position, blast, bullet.shooter)

static func _projectile_hit(combat: CombatSimulator, bullet: BulletBody, incoming: Vector2, pvp: bool) -> void:
	var target := bullet.impact_node()
	var single_direct := target is Player and pvp and bool(bullet.definition.get("single_pvp_direct", false))
	if single_direct and bullet.direct_hit:
		return
	var applied := combat.resolve_hit(bullet.shooter, target, bullet.definition["hit"],
			bullet.global_position, bullet.hit_damage, bullet.hit_impact, incoming)
	if applied and single_direct:
		bullet.direct_hit = true
	if applied and target is EnemyBase:
		combat.projectile_hit_npc.emit(bullet.type_id)
