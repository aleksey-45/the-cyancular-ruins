class_name WeaponRegistry
extends RefCounted

enum Type { PISTOL = 1, RIFLE = 2, M82 = 3, S686 = 4, GRENADE = 5, LASER = 6, COMPOUND_BOW = 7, M249 = 8 }
enum Trigger { PRESS, AUTO, RELEASE, CHARGE_RELEASE }
enum Penalty { NONE, COOLDOWN, AIM_OR_COOLDOWN }
enum Attack { PROJECTILE, BEAM, MELEE }

const DEFAULTS := {"trigger": Trigger.PRESS, "trigger_delay": 0.0, "penalty": Penalty.NONE, "move": Vector2.ONE,
	"attack": Attack.PROJECTILE, "projectile": CombatProfiles.ROUND,
	"muzzle": Vector2.ZERO, "pitch": 90.0, "recoil": 0.0,
	"size": 1.0, "gravity": 0.0, "count": 1, "spread": 0.0, "live_cap": 0,
	"shot_sound": "shoot", "npc_hit_sound": "hit", "projectile_region": Rect2(2, 1, 11, 4)}
static var BIRD_BOMB := {"projectile": CombatProfiles.BIRD_BOMB, "size": EnemyParams.FlyBird.bullet_size,
	"gravity": EnemyParams.FlyBird.bullet_gravity, "range": EnemyParams.FlyBird.bullet_range,
	"damage": EnemyParams.FlyBird.bullet_damage, "impact": -1.0, "npc_hit_sound": "",
	"projectile_region": Rect2(28, 1, 10, 9)}
const WEAPON_COUNT := 8
# 武器数值的唯一来源：data/weapons/*.tres + catalog.tres（见 WeaponDef）。
const CATALOG := preload("res://data/weapons/catalog.tres")

static var _definitions := _load_definitions()

static func _load_definitions() -> Dictionary:
	var result := {}
	for def: WeaponDef in CATALOG.weapons:
		if def == null or def.weapon_id <= 0 or def.data.is_empty():
			push_error("WeaponCatalog: 无效的武器条目")
			continue
		var spec: Dictionary = def.data.duplicate(true)
		spec.make_read_only()
		result[def.weapon_id] = spec
	if result.size() != WEAPON_COUNT:
		push_error("WeaponCatalog: 期望 %d 种武器,实际 %d 种" % [WEAPON_COUNT, result.size()])
	return result

static func projectile_definition(type_id: int) -> Dictionary:
	return BIRD_BOMB if type_id == CombatProfiles.BIRD_BOMB_TYPE else _definitions[type_id]

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
