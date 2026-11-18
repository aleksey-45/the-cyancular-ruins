class_name Player
extends ActorBody

var combat_rules: CombatSimulator
var time_field: TimeField:
	get: return combat_rules.time_field if combat_rules != null else null
var ground_actions: Callable
var input_buffer := InputBuffer.new()
var respawn_tick := 0
var last_attacker := 0
var last_hit_tick := 0

# 记录决定下一物理帧模拟所需的全部关键变量，用于服务端权威快照生成与客户端预测回滚重放。
func capture_state() -> Dictionary:
	var actor := capture_actor_state()
	actor[PlayerStateSchema.WEAPON_INST] = weapons.current_inst()
	actor[PlayerStateSchema.INVENTORY] = weapons.snapshot()
	return {"actor": actor,
		"equipment": equipped.state_values() if equipped != null else []}

func restore_state(snapshot: Dictionary, rewinding_inventory := false) -> void:
	var actor: Array = snapshot["actor"]
	var serial := shot_serial
	restore_logic_state(actor)
	if rewinding_inventory:
		shot_serial = serial
	weapons.restore(actor[PlayerStateSchema.WEAPON_INST], actor[PlayerStateSchema.INVENTORY],
			snapshot["equipment"], rewinding_inventory)

func capture_network_state() -> Dictionary:
	return {"state": capture_state(), "input": input_buffer._last, "aim": step_input.aim,
			"epoch": input_buffer.epoch, "action_ack": input_buffer.action_ack,
			"rewind": rewinding, "respawn_tick": respawn_tick}

func restore_network_state(snapshot: Dictionary) -> void:
	restore_state(snapshot["state"])
	rewinding = snapshot["rewind"]
	respawn_tick = snapshot["respawn_tick"]
	step_input.aim = snapshot["aim"]
	input_buffer.restore_authority(snapshot["epoch"], snapshot["action_ack"], snapshot["input"])
	if collision_layer == 0:
		collision_layer = CollisionWorld.team_layer(team)
		_apply_layers()

func spawn_at(spawn_cell: Vector2i, heal := true) -> void:
	global_position = terrain.cell_center(spawn_cell)
	reset_motion()
	if heal:
		apply_authoritative_state(sim_max_hp, max_waterproof, false)
	else:
		sync_collision_geometry()

enum RewindSlot { POS, VEL, FACING, HP, DOWNED, INSTANCE, INVENTORY, EQUIPMENT }

func capture_rewind_state() -> Array:
	return [global_position, velocity, facing_direction, sim_hp, sim_downed, weapons.current_inst(),
			weapons.snapshot(), equipped.state_values() if equipped != null else []]

func rewind_restore(values: Array) -> void:
	global_position = values[RewindSlot.POS]
	_grounded = false
	velocity = values[RewindSlot.VEL]
	motion_knock_velocity = Vector2.ZERO
	facing_direction = values[RewindSlot.FACING]
	var restored_hp := clampi(values[RewindSlot.HP], 0, sim_max_hp)
	var downed: bool = values[RewindSlot.DOWNED]
	var entered_downed := downed and not sim_downed
	weapons.restore(values[RewindSlot.INSTANCE], values[RewindSlot.INVENTORY], values[RewindSlot.EQUIPMENT], true)
	apply_authoritative_state(restored_hp, waterproof, downed)
	if entered_downed and equipped != null:
		equipped.cancel_aim()
