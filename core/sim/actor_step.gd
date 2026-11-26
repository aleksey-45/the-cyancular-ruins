class_name ActorStep
extends RefCounted
const DT := 1.0 / 60.0

static func step(actor: Player, record: Array, delta: float = DT) -> void:
	actor.step_input.prepare(record, actor._controls_locked)
	actor.combat_requests = []
	var field := actor.time_field
	if actor.rewinding or (field != null and field.is_rewinding()):
		return
	if not actor.sim_downed:
		if not actor._controls_locked:
			actor.combat.ground.handle_actions(actor, record)
		var winst := actor.step_input.weapon_inst
		if winst > 0 and not actor.weapons.equip_inst(winst):
			actor.step_input.pressed &= ~(ActorInput.BIT_ATTACK | ActorInput.BIT_RELOAD)
			actor.step_input.released &= ~ActorInput.BIT_ATTACK
			actor.step_input.held &= ~ActorInput.BIT_ATTACK
	var tm: float = field.player_speed_mult() if field != null else actor.personal_haste_mult
	actor.step_actor(delta, tm)
