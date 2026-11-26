class_name CombatProfiles
extends RefCounted

enum Target { SELF = 1, ALLY = 2, OPPONENT = 4, NPC = 8 }
enum Water { NONE, BLAST, WET }
enum NpcImpulse { ADD, SET, DEFAULT }
enum ContactEffect { NONE, CHIP_SUB, HIT }
const BIRD_BOMB_TYPE := -1
const PLAYERS := Target.SELF | Target.ALLY | Target.OPPONENT
const FLY_BIRD_WET_MULT := 1.5

const DIRECT := {"targets": Target.OPPONENT | Target.NPC,
	"water": Water.NONE, "npc_impulse": NpcImpulse.ADD}
const BLAST := {"targets": PLAYERS | Target.NPC,
	"water": Water.BLAST, "npc_impulse": NpcImpulse.SET}
const ENEMY_HIT := {"targets": PLAYERS, "respects_iframes": true, "water": Water.NONE}
const BIRD_BOMB_HIT := {"targets": PLAYERS, "respects_iframes": true, "water": Water.WET}
const FLY_CHARGE := {"targets": PLAYERS, "water": Water.WET}
const SMASH := {"targets": PLAYERS, "water": Water.NONE}
const DROWN := {"targets": PLAYERS | Target.NPC,
	"water": Water.NONE, "npc_impulse": NpcImpulse.ADD}

const BIRD_BOMB := {
	"collision_layers": CollisionWorld.LAYER_TEAM_A,
	"shape": Vector2(10, 10),
	"wall": {"bounce": false, "fuse": 0.0, "effect": ContactEffect.NONE},
	"actor": {"bounce": false, "fuse": 0.0, "effect": ContactEffect.HIT},
	"hit": BIRD_BOMB_HIT,
	"blast": {},
}
