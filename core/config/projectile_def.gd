class_name ProjectileDef
extends Resource

@export var shape := Vector2(12, 6)
@export var wall_effect: CombatProfiles.ContactEffect = CombatProfiles.ContactEffect.CHIP_SUB
@export var wall_bounce := false
@export var wall_fuse := 0.0
@export var actor_bounce := false
@export var actor_fuse := 0.0
@export var npc_impulse: CombatProfiles.NpcImpulse = CombatProfiles.NpcImpulse.ADD
@export var single_direct := false
@export var blast: Dictionary = {}

func definition() -> Dictionary:
	var spec := {
		"shape": shape,
		"wall": {"bounce": wall_bounce, "fuse": wall_fuse, "effect": wall_effect},
		"actor": {"bounce": actor_bounce, "fuse": actor_fuse, "effect": CombatProfiles.ContactEffect.HIT},
		"hit": CombatProfiles.DIRECT.merged({"npc_impulse": npc_impulse}, true),
		"blast": blast.duplicate(),
	}
	if single_direct:
		spec["single_direct"] = true
	for section: Dictionary in [spec["wall"], spec["actor"], spec["hit"], spec["blast"]]:
		section.make_read_only()
	spec.make_read_only()
	return spec
