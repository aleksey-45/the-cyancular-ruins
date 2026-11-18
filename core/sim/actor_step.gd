class_name ActorStep
extends RefCounted
const DT := 1.0 / 60.0

## 取出本帧可以模拟的玩家输入。预测窗口以外的远端角色等待服务器快照。
static func buffered_inputs(players: Dictionary, tick: int, local: Player = null, predict_remotes := true) -> Dictionary:
	var inputs := {}
	for role: int in players:
		var player: Player = players[role]
		if local != null and player != local and (not predict_remotes or (player.respawn_tick > 0 and tick > player.respawn_tick)):
			continue
		inputs[role] = player.input_buffer.take(tick)
	return inputs

static func step(actor: Player, record: Array, delta: float = DT) -> Array:
	actor.step_input.prepare(record, actor._controls_locked)
	actor.combat_requests = []
	actor.presentation_events = []
	var field := actor.time_field
	if actor.rewinding or (field != null and field.is_rewinding()):
		return actor.combat_requests
	if not actor.sim_downed:
		if not actor._controls_locked and not actor.combat.predicting:
			actor.combat.ground.handle_actions(actor, record)
		var winst := actor.step_input.weapon_inst
		if winst > 0:
			actor.weapons.equip_inst(winst)
			if actor.weapons.current_inst() != winst:
				actor.step_input.pressed &= ~(ActorInput.BIT_ATTACK | ActorInput.BIT_RELOAD)
				actor.step_input.released &= ~ActorInput.BIT_ATTACK
				actor.step_input.held &= ~ActorInput.BIT_ATTACK
	var tm: float = field.player_speed_mult() if field != null else actor.personal_haste_mult
	actor.step_actor(delta, tm)
	return actor.combat_requests
