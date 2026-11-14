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
const BIRD_BOMB := {"projectile": CombatProfiles.BIRD_BOMB, "size": EnemyParams.FlyBird.bullet_size,
	"gravity": EnemyParams.FlyBird.bullet_gravity, "range": EnemyParams.FlyBird.bullet_range,
	"damage": EnemyParams.FlyBird.bullet_damage, "impact": -1.0, "npc_hit_sound": "",
	"projectile_region": Rect2(28, 1, 10, 9)}
const WEAPONS := {
	Type.PISTOL: {"name": "手枪", "tier": WeaponInventory.TIER_LIGHT,
		"region": Rect2(2, 1.85493, 17.1001, 12.347), "sprite_offset": Vector2(24, 5.6),
		"pickup_bounds": Rect2(-8.5, -5, 17, 11), "kick": 8.0, "shake": 2.0,
		"muzzle": Vector2(31.6, 2),
		"cooldown": 0.3, "speed": 1750.0, "range": 1400.0, "spread": 0.6,
		"damage": 10, "impact": 800.0, "recoil": 200.0, "pitch": 65.0, "mag": 12, "reload": 1.0},
	Type.RIFLE: {"name": "步枪", "tier": WeaponInventory.TIER_MEDIUM,
		"region": Rect2(108, 2, 55, 20), "sprite_offset": Vector2(12, 11),
		"pickup_bounds": Rect2(-27.5, -9, 55, 18), "kick": 6.0, "shake": 3.0, "shake_time": 0.12,
		"muzzle": Vector2(31, 6),
		"trigger": Trigger.AUTO, "penalty": Penalty.COOLDOWN, "move": Vector2(0.7, 0.8),
		"cooldown": 0.1, "speed": 2000.0, "range": 1600.0, "spread": 0.8,
		"damage": 4, "impact": 500.0, "recoil": 80.0, "pitch": 60.0, "mag": 30, "reload": 1.8},
	Type.M82: {"name": "重狙 M82A1", "tier": WeaponInventory.TIER_HEAVY,
		"region": Rect2(22, 0.351734, 84, 17.6483), "sprite_offset": Vector2(24, 9),
		"pickup_bounds": Rect2(-42, -7.5, 84, 16), "kick": 12.0, "shake": 8.0, "shake_time": 0.2,
		"muzzle": Vector2(54, 5),
		"trigger": Trigger.RELEASE, "penalty": Penalty.AIM_OR_COOLDOWN, "move": Vector2(0.5, 0.6), "shot_sound": "shoot_heavy",
		"cooldown": 1.2, "speed": 3750.0, "range": 2000.0, "size": 1.25,
		"damage": 30, "impact": 1800.0, "recoil": 1200.0, "pitch": 65.0, "mag": 5, "reload": 2.6},
	Type.S686: {"name": "霰弹 S686", "tier": WeaponInventory.TIER_LIGHT,
		"region": Rect2(3, 19, 59, 14), "sprite_offset": Vector2(24, 9),
		"pickup_bounds": Rect2(-29.5, -7, 59, 14), "kick": 11.0, "shake": 5.0,
		"muzzle": Vector2(46, 4),
		"penalty": Penalty.COOLDOWN, "move": Vector2(0.9, 1), "shot_sound": "shotgun",
		"cooldown": 0.75, "speed": 1375.0, "range": 1100.0, "size": 0.8, "count": 8, "spread": 3.0,
		"damage": 5, "impact": 200.0, "recoil": 900.0, "pitch": 55.0, "mag": 2, "reload": 2.2},
	Type.GRENADE: {"name": "榴弹发射器", "tier": WeaponInventory.TIER_HEAVY,
		"region": Rect2(3, 35, 51, 21), "sprite_offset": Vector2(11, 8),
		"pickup_bounds": Rect2(-25.5, -10.5, 51, 21), "kick": 16.0, "shake": 14.0, "shake_time": 0.3, "arc_time": 3.0,
		"muzzle": Vector2(31, 8),
		"trigger": Trigger.RELEASE, "penalty": Penalty.AIM_OR_COOLDOWN, "move": Vector2(0.5, 0.8),
		"cooldown": 1.4, "speed": 1375.0, "range": 2500.0, "size": 1.5, "gravity": 0.45,
		"projectile": CombatProfiles.GRENADE, "live_cap": 3, "shot_sound": "shoot_heavy",
		"npc_hit_sound": "", "projectile_region": Rect2(2, 9, 12, 6),
		"damage": 5, "impact": 10.0, "recoil": 1100.0, "pitch": 60.0, "mag": 6, "reload": 2.8},
	Type.LASER: {"name": "激光枪", "tier": WeaponInventory.TIER_MEDIUM,
		"region": Rect2(65, 20.341309, 53, 17.658691), "sprite_offset": Vector2(12, 9),
		"pickup_bounds": Rect2(-26.5, -8.5, 52, 17), "kick": 10.0, "shake": 5.0,
		"muzzle": Vector2(30, 5),
		"trigger": Trigger.AUTO, "penalty": Penalty.COOLDOWN, "move": Vector2(0.8, 0.8),
		"attack": Attack.BEAM, "bounces": 5, "hit_radius": 3.5, "tile_chip": 8,
		"cooldown": 0.5, "range": 2000.0,
		"damage": 6, "impact": 350.0, "recoil": 400.0, "pitch": 65.0, "mag": 12, "reload": 1.2},
	Type.COMPOUND_BOW: {"name": "复合弓", "tier": WeaponInventory.TIER_MEDIUM,
		"region": Rect2(4, 60, 20, 44), "sprite_offset": Vector2(10, 10),
		"pickup_bounds": Rect2(-10, -22, 20, 44), "kick": 2.0, "shake": 1.5, "arc_time": 2.0, "guide_color": Color(0.42, 0.92, 0.82, 0.7),
		"muzzle": Vector2(24, 7),
		"trigger": Trigger.CHARGE_RELEASE, "charge_time": 0.8, "shot_sound": "bow",
		"penalty": Penalty.AIM_OR_COOLDOWN, "move": Vector2(0.65, 0.85),
		"cooldown": 0.25, "min_speed": 500.0, "speed": 1500.0, "range": 1800.0, "gravity": 0.45,
		"projectile": CombatProfiles.ARROW, "projectile_region": Rect2(17, 13, 45, 6),
		"min_damage": 4, "damage": 35,
		"impact": 650.0, "recoil": 0.0, "pitch": 65.0, "mag": 1, "reload": 0.45},
	Type.M249: {"name": "机枪 M249", "tier": WeaponInventory.TIER_HEAVY,
		"region": Rect2(62, 40, 74, 26), "sprite_offset": Vector2(16, 10),
		"pickup_bounds": Rect2(-37, -13, 74, 26), "kick": 4.0, "shake": 2.5, "shake_time": 0.08,
		"muzzle": Vector2(52, 6),
		"trigger": Trigger.AUTO, "trigger_delay": 0.3, "penalty": Penalty.COOLDOWN, "move": Vector2(0.62, 0.75),
		"cooldown": 0.08, "speed": 2150.0, "range": 1700.0, "spread": 1.6,
		"damage": 3, "impact": 450.0, "recoil": 65.0, "pitch": 60.0, "mag": 100, "reload": 3.2},
}

static var _definitions := _load_definitions()

static func _load_definitions() -> Dictionary:
	var result := {}
	for id in WEAPONS:
		var spec := DEFAULTS.merged(WEAPONS[id], true)
		spec.make_read_only()
		result[id] = spec
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
