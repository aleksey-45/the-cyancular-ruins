class_name ActorStep
extends RefCounted
const DT := 1.0 / 60.0

## 联机角色按 ID 推进。客户端在预测范围内推进远端角色。
static func step_players(players: Dictionary, tick: int, economy: TimeEconomy, local: Player = null,
		predict_remotes := true) -> Array[Player]:
	var roles := players.keys()
	roles.sort()
	var stepped: Array[Player] = []
	for role: int in roles:
		var player: Player = players[role]
		if local != null and player != local \
				and (not predict_remotes or (player.respawn_tick > 0 and tick > player.respawn_tick)):
			continue
		var record := player.input_buffer.take(tick)
		if economy != null:
			economy.step_haste(player, record, DT)
		step(player, record)
		stepped.append(player)
	return stepped

static func step(actor: Player, record: Array, delta: float = DT) -> Array:
	actor.step_input.prepare(record, actor._controls_locked)
	actor.step_actions = []
	var field := actor.time_field
	if actor.rewinding or (field != null and field.is_rewinding()):
		return actor.step_actions
	if not actor.sim_downed:
		if not actor._controls_locked and actor.ground_actions.is_valid():
			actor.ground_actions.call(actor, record)
		var winst := actor.step_input.weapon_inst
		if winst > 0:
			actor.weapons.equip_inst(winst)
			if actor.weapons.current_inst() != winst:
				actor.step_input.pressed &= ~(ActorInput.BIT_ATTACK | ActorInput.BIT_RELOAD)
				actor.step_input.released &= ~ActorInput.BIT_ATTACK
				actor.step_input.held &= ~ActorInput.BIT_ATTACK
	var tm: float = field.player_speed_mult() if field != null else actor.pvp_haste_mult
	actor.step_actor(delta, tm)
	return actor.step_actions
