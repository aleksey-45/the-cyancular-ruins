class_name CombatProfiles
extends RefCounted

enum Target { SELF = 1, ALLY = 2, OPPONENT = 4, NPC = 8 }
enum Water { NONE, BLAST, WET }
enum NpcImpulse { ADD, SET, DEFAULT }
enum ContactEffect { NONE, CHIP_SUB, HIT }
const BIRD_BOMB_TYPE := -1
const PLAYERS := Target.SELF | Target.ALLY | Target.OPPONENT
const FLY_BIRD_WET_MULT := 1.5

const DIRECT := {"targets": Target.OPPONENT | Target.NPC, "ignore_iframes": false,
	"water": Water.NONE, "npc_impulse": NpcImpulse.ADD}
const GRENADE_DIRECT := {"targets": Target.OPPONENT | Target.NPC, "ignore_iframes": false,
	"water": Water.NONE, "npc_impulse": NpcImpulse.DEFAULT}
const BLAST := {"targets": PLAYERS | Target.NPC, "ignore_iframes": true,
	"water": Water.BLAST, "npc_impulse": NpcImpulse.SET}
const ENEMY_HIT := {"targets": PLAYERS, "ignore_iframes": false, "water": Water.NONE}
const BIRD_BOMB_HIT := {"targets": PLAYERS, "ignore_iframes": false, "water": Water.WET}
const FLY_CHARGE := {"targets": PLAYERS, "ignore_iframes": true, "water": Water.WET}
const SMASH := {"targets": PLAYERS, "ignore_iframes": true, "water": Water.NONE}
const DROWN := {"targets": PLAYERS | Target.NPC, "ignore_iframes": true,
	"water": Water.NONE, "npc_impulse": NpcImpulse.ADD}

const ROUND := {
	"shape": Vector2(12, 6),
	"wall": {"bounce": false, "fuse": 0.0, "effect": ContactEffect.CHIP_SUB},
	"actor": {"bounce": false, "fuse": 0.0, "effect": ContactEffect.HIT},
	"hit": DIRECT,
	"blast": {},
}
const ARROW := {
	"shape": Vector2(20, 4),
	"wall": ROUND["wall"],
	"actor": ROUND["actor"],
	"hit": DIRECT,
	"blast": {},
}
const GRENADE := {
	"single_pvp_direct": true,
	"shape": Vector2(12, 8),
	"wall": {"bounce": true, "fuse": 0.3, "effect": ContactEffect.NONE},
	"actor": {"bounce": true, "fuse": 0.1, "effect": ContactEffect.HIT},
	"hit": GRENADE_DIRECT,
	"blast": {"radius": 350.0, "damage": 35, "impact": 3000.0},
}
const BIRD_BOMB := {
	"collision_layers": CollisionWorld.LAYER_TEAM_A,
	"shape": Vector2(10, 10),
	"wall": {"bounce": false, "fuse": 0.0, "effect": ContactEffect.NONE},
	"actor": {"bounce": false, "fuse": 0.0, "effect": ContactEffect.HIT},
	"hit": BIRD_BOMB_HIT,
	"blast": {},
}
