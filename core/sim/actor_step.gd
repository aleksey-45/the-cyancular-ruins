class_name ActorStep
extends RefCounted
const DT := 1.0 / 60.0


static func step(actor: Player, record: Dictionary, delta: float = DT) -> Array:
	actor.actor_queries.clear()
	actor.step_input.prepare(record, actor._controls_locked)
	actor.input_seq = record["seq"]
	actor.view_tick = record["view_tick"]
	actor.input_epoch = actor.input_buffer.epoch
	actor.step_actions.clear()
	actor.stepping = true
	simulate(actor, delta)
	actor.stepping = false
	return actor.step_actions.duplicate()


static func simulate(actor: Player, delta: float) -> void:
	if actor.rewinding:
		return
	if TimeField.current != null and TimeField.current.is_rewinding():
		return
	if not actor.sim_downed:
		var winst := actor.step_input.weapon_inst
		if winst > 0:
			actor.weapons.equip_inst(winst)
			if actor.weapons.current_inst() != winst:
				actor.step_input.pressed &= ~(ActorInput.BIT_ATTACK | ActorInput.BIT_RELOAD)
				actor.step_input.released &= ~ActorInput.BIT_ATTACK
				actor.step_input.held &= ~ActorInput.BIT_ATTACK
				actor.step_input.raw_held &= ~ActorInput.BIT_ATTACK
	var tm: float = TimeField.player_speed_mult() if TimeField.current != null else actor.pvp_haste_mult
	var geometry := TileDefs.terrain
	actor.native_step_actor(delta, tm, Level0.pvp_mode, geometry)

# 运动状态、游泳、攀爬和碰撞循环全部在原生基类执行；不回调脚本读取成员。
static func simulate_motion(actor: Player, delta: float, mult: Vector2, motion_only: bool = false) -> void:
	if actor.rewinding: return
	var tm: float = TimeField.player_speed_mult() if TimeField.current != null else actor.pvp_haste_mult
	var geometry := TileDefs.terrain
	actor.native_simulate_motion(delta, mult, tm, motion_only, Level0.pvp_mode,
			geometry)

static func move_by(actor: Player, motion: Vector2) -> Vector2:
	return actor.native_move_by(motion, CollisionBuilder.geometry_revision)

static func _move(actor: Player, delta: float) -> void:
	actor.native_move_actor(delta, CollisionBuilder.geometry_revision)
