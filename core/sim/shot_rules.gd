class_name ShotRules
extends RefCounted

static func prepare(terrain: Terrain, shot: Dictionary, spec: Dictionary) -> void:
	var pos: Vector2 = shot["pos"]
	var dir: Vector2 = shot["dir"]
	match spec["attack"]:
		WeaponRegistry.Attack.PROJECTILE:
			shot["vectors"] = projectile_velocities(shot["role"], shot, spec)
		WeaponRegistry.Attack.BEAM:
			var trace := terrain.trace_beam(pos, dir, spec["range"], spec["bounces"])
			shot["trace"] = trace
			shot["vectors"] = trace["points"]
		WeaponRegistry.Attack.MELEE:
			shot["vectors"] = PackedVector2Array([pos, pos + dir * float(spec["range"])])

static func projectiles(combat: CombatSimulator, actor: Player, shot: Dictionary, spec: Dictionary,
		ids: Array[int] = []) -> void:
	var id := shot_id(actor.role, shot["serial"])
	var velocities: PackedVector2Array = shot["vectors"]
	var damage := attack_damage(spec, shot["charge"])
	for pellet in velocities.size():
		var key := pellet_id(id, pellet)
		if not ids.is_empty() and not ids.has(key):
			continue
		var bullet := combat.spawn_projectile(key, shot["type_id"], actor,
				shot["pos"], velocities[pellet], damage)
		bullet.launch = shot

static func shot_id(role: int, serial: int) -> int:
	return (role << 48) | (serial << 8)

static func shooter_role(id: int) -> int:
	return id >> 48

static func shot_serial(id: int) -> int:
	return (id >> 8) & 0xffffffff

static func pellet_id(shot: int, pellet: int) -> int:
	return shot | pellet

static func shot_from_projectile(id: int) -> int:
	return id & ~0xff

static func attack_damage(spec: Dictionary, charge: float) -> int:
	return roundi(lerpf(spec.get("min_damage", spec["damage"]), spec["damage"], charge))

static func launch_offset(spec: Dictionary, charge: float) -> Vector2:
	var offset: Vector2 = spec["muzzle"]
	offset.x -= float(spec.get("draw_length", 0.0)) * charge
	return offset

static func launch_speed(spec: Dictionary, charge: float) -> float:
	var speed: float = spec["speed"]
	return lerpf(spec.get("min_speed", speed), speed, charge)

static func projectile_velocities(role: int, shot: Dictionary, spec: Dictionary) -> PackedVector2Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = ("%d:%d" % [role, shot["serial"]]).hash()
	var spread := deg_to_rad(spec["spread"])
	var direction: Vector2 = shot["dir"]
	var speed := launch_speed(spec, shot["charge"]) * float(shot["speed_mult"])
	var velocities := PackedVector2Array()
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

static func hitscan(combat: CombatSimulator, shooter: Player, shot: Dictionary, spec: Dictionary) -> void:
	var points: PackedVector2Array = shot["vectors"]
	var block_walls: bool = spec["attack"] == WeaponRegistry.Attack.MELEE
	var damage := attack_damage(spec, shot["charge"])
	var space := combat.terrain.physics
	var contacts := space.corridor_contacts(points, spec["hit_radius"], CombatSimulator.ACTOR_LAYERS, [shooter.rid])
	for contact: Array in contacts:
		var target: ActorBody = contact[CollisionWorld.CorridorContact.TARGET]
		if block_walls and not combat.terrain.line_of_sight(points[0], target.position):
			continue
		var at: Vector2 = points[0] if block_walls else contact[CollisionWorld.CorridorContact.POINT]
		combat.resolve_hit(shooter, target, CombatProfiles.DIRECT, at, damage, spec["impact"],
				combat.hit_direction(at, target.position))

	if combat.predicting or block_walls:
		return
	var trace: Dictionary = shot["trace"]
	var terrain := combat.terrain
	var seen := {}
	var cells: Array = trace["contacts"]
	for index in cells.size():
		var cell: Vector2i = cells[index]
		var block := cell / Terrain.BEAM_BLOCK_SUBS
		if seen.has(block):
			continue
		var tex := terrain.material_at(cell)
		if TileDefs.explosion_destroyable(tex):
			seen[block] = true
			combat.tile_hit.emit(trace["hit_points"][index], tex)
			terrain.damage_beam(cell, spec["tile_chip"], shooter.role)

static func step_projectile(combat: CombatSimulator, bullet: BulletBody, delta: float) -> void:
	var advance := bullet.advance_physics(delta)
	match advance:
		BulletBody.AdvanceResult.TERRAIN_HIT, BulletBody.AdvanceResult.ACTOR_HIT:
			var response: Dictionary = bullet.definition["wall" if advance == BulletBody.AdvanceResult.TERRAIN_HIT else "actor"]
			var incoming := bullet.velocity
			if response["fuse"] > 0.0:
				bullet.start_fuse(response["fuse"])
			if response["bounce"]:
				bullet.bounce(bullet.impact_normal)
			match response["effect"]:
				CombatProfiles.ContactEffect.CHIP_SUB:
					if not combat.predicting:
						var tex := combat.terrain.damage_impact(bullet.impact_point, bullet.impact_normal,
								bullet.hit_damage, CombatSimulator.source_role(bullet.shooter))
						if tex != 0:
							combat.tile_hit.emit(bullet.impact_point, tex)
				CombatProfiles.ContactEffect.HIT:
					_projectile_hit(combat, bullet, incoming)
			if not response["bounce"]:
				combat.erase_projectile(bullet.entity_id)
				combat.projectile_ended.emit(bullet.entity_id)
		BulletBody.AdvanceResult.FUSE_END, BulletBody.AdvanceResult.RANGE_END:
			var blast: Dictionary = bullet.definition["blast"]
			combat.erase_projectile(bullet.entity_id)
			if blast.is_empty():
				combat.projectile_ended.emit(bullet.entity_id)
			else:
				combat.submit_blast(bullet.entity_id, bullet.position, bullet.type_id)

static func _projectile_hit(combat: CombatSimulator, bullet: BulletBody, incoming: Vector2) -> void:
	var target := bullet.impact_actor()
	var single_direct := bool(bullet.definition.get("single_direct", false))
	if single_direct and bullet.direct_hit:
		return
	var applied := combat.resolve_hit(bullet.shooter, target, bullet.definition["hit"],
			bullet.position, bullet.hit_damage, bullet.hit_impact, incoming)
	if applied and single_direct:
		bullet.direct_hit = true
	if applied and target is EnemyBase:
		combat.projectile_hit_npc.emit(bullet.type_id)
