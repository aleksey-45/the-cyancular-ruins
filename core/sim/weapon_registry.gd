class_name WeaponRegistry
extends RefCounted

const ECFG: EnemyConfig = preload("res://core/config/enemy_config.tres")
const CATALOG: WeaponCatalog = preload("res://data/weapons/catalog.tres")

static var _bird_bomb := {"projectile": CombatProfiles.BIRD_BOMB, "size": ECFG.fly_bird_bullet_size,
	"gravity": ECFG.fly_bird_bullet_gravity, "range": ECFG.fly_bird_bullet_range,
	"damage": ECFG.fly_bird_bullet_damage, "impact": -1.0,
	"projectile_region": Rect2(28, 1, 10, 9)}
static var _definitions := _load_definitions(CATALOG.weapons)

static func _load_definitions(weapons: Array[WeaponDef]) -> Dictionary:
	var result := {}
	var projectiles: Dictionary[ProjectileDef, Dictionary] = {}
	for weapon: WeaponDef in weapons:
		var spec := {"trigger_delay": 0.0, "move": Vector2.ONE, "live_cap": 0,
			"shot_sound": "shoot"}.merged(weapon.data, true)
		spec["trigger"] = weapon.trigger
		spec["penalty"] = weapon.penalty
		spec["attack"] = weapon.attack
		if weapon.attack == WeaponDef.Attack.PROJECTILE:
			var projectile := weapon.projectile
			if not projectiles.has(projectile):
				projectiles[projectile] = projectile.definition()
			spec["projectile"] = projectiles[projectile]
			spec.merge({"size": 1.0, "gravity": 0.0, "count": 1, "spread": 0.0,
				"projectile_region": Rect2(2, 1, 11, 4)})
		spec.make_read_only()
		result[weapon.weapon_id] = spec
	return result

static func projectile_definition(type_id: int) -> Dictionary:
	return _bird_bomb if type_id == CombatProfiles.BIRD_BOMB_TYPE else _definitions[type_id]

static func blast_definition(type_id: int) -> Dictionary:
	return projectile_definition(type_id)["projectile"]["blast"]

static func definition(type_id: int) -> Dictionary:
	return _definitions[type_id]

static func all_ids() -> Array[int]:
	var ids: Array[int] = []
	ids.assign(_definitions.keys())
	return ids

static func enabled_ids(disabled: Array) -> Array[int]:
	var enabled: Array[int] = []
	for id: int in _definitions:
		if not disabled.has(id):
			enabled.append(id)
	return enabled

static func name_of(type_id: int) -> String:
	return definition(type_id)["name"]
