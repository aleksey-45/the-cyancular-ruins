class_name GunBody
extends RefCounted

const StateSlot := PlayerStateSchema.Equipment

var type_id: int
var definition: Dictionary

var _inventory: WeaponInventory
var slot: int
var carried: int:
	get: return _inventory.carried_at(slot)
	set(value): _inventory.set_carried(slot, value)

var fire_cd_timer: float
var reload_left := 0.0
var reloading: bool:
	get: return reload_left > 0.0
var aiming := false
var fire_buffered := false
var shot_facing := 1
var hold_elapsed := 0.0

func _init(inventory: WeaponInventory, index: int) -> void:
	_inventory = inventory
	type_id = inventory.type_at(index)
	definition = WeaponRegistry.definition(type_id)
	bind_slot(index)

func bind_slot(index: int) -> void:
	slot = index
	if carried == WeaponInventory.DEFAULT_CARRIED and has_magazine():
		carried = definition["mag"]

func has_magazine() -> bool:
	return definition.has("mag")

func cancel_aim() -> void:
	aiming = false
	hold_elapsed = 0.0

func start_reload(actor: ActorBody) -> void:
	if not has_magazine() or reloading or carried >= definition["mag"]:
		return
	reload_left = definition["reload"]
	actor.step_actions.append({"kind": "sound", "sound": "reload"})

func reload_progress() -> float:
	return 1.0 - reload_left / float(definition["reload"]) if reloading else -1.0

static func aim_transform(direction: Vector2, facing: int, limit: float) -> Transform2D:
	var local := Vector2(direction.x * facing, direction.y)
	var angle := clampf(local.angle(), -deg_to_rad(limit), deg_to_rad(limit)) * facing
	return Transform2D(angle, Vector2(facing, 1.0), 0.0, Vector2.ZERO)

func muzzle_pose(actor: ActorBody, aim: Vector2) -> Transform2D:
	var direction := aim if aim != Vector2.ZERO else Vector2(actor.facing_direction, 0)
	var pose := aim_transform(direction, shot_facing, definition["pitch"])
	pose.origin = actor.to_global(pose * (definition["muzzle"] as Vector2))
	return pose

func charge_ratio() -> float:
	return hold_elapsed / float(definition["charge_time"]) \
			if definition["trigger"] == WeaponRegistry.Trigger.CHARGE_RELEASE else 1.0

func step(actor: ActorBody, input: ActorInput, delta: float) -> Vector2:
	if input.pressed & ActorInput.BIT_RELOAD:
		start_reload(actor)
	fire_cd_timer = maxf(fire_cd_timer - delta, 0.0)
	if reloading:
		reload_left -= delta
		if not reloading:
			carried = definition["mag"]
			actor.step_actions.append({"kind": "sound", "sound": "switch"})
	aim_at(actor, input.aim)
	if actor._controls_locked:
		fire_buffered = false
	if fire_buffered and fire_cd_timer == 0.0:
		fire_buffered = false
		_fire(actor, input.aim)
	var held := (input.held & ActorInput.BIT_ATTACK) != 0
	var pressed := (input.pressed & ActorInput.BIT_ATTACK) != 0
	var released := (input.released & ActorInput.BIT_ATTACK) != 0
	match definition["trigger"]:
		WeaponRegistry.Trigger.RELEASE:
			if pressed:
				aiming = true
			if released:
				aiming = false
				_try_fire(actor, input.aim)
			if not held and not pressed:
				aiming = false
		WeaponRegistry.Trigger.CHARGE_RELEASE:
			if reloading:
				cancel_aim()
			elif released:
				if (aiming or pressed) and fire_cd_timer == 0.0:
					_fire(actor, input.aim)
				cancel_aim()
			elif held or pressed:
				aiming = true
				hold_elapsed = minf(hold_elapsed + delta, definition["charge_time"])
			else:
				cancel_aim()
		WeaponRegistry.Trigger.AUTO:
			var delay: float = definition["trigger_delay"]
			if released or not (held or pressed):
				hold_elapsed = 0.0
			if (held or pressed) and (not released or delay == 0.0):
				hold_elapsed = minf(hold_elapsed + delta, delay)
				if hold_elapsed >= delay:
					_try_fire(actor, input.aim)
		WeaponRegistry.Trigger.PRESS:
			if pressed:
				_try_fire(actor, input.aim)
	var penalty: int = definition["penalty"]
	var slowed := penalty != WeaponRegistry.Penalty.NONE and fire_cd_timer > 0.0 \
			or penalty == WeaponRegistry.Penalty.AIM_OR_COOLDOWN and aiming
	return definition["move"] if slowed else Vector2.ONE

func aim_at(actor: ActorBody, input_aim: Vector2) -> void:
	if absf(input_aim.x) > 0.1:
		shot_facing = 1 if input_aim.x > 0.0 else -1
		if not actor.is_charge:
			actor.facing_direction = shot_facing
	elif input_aim == Vector2.ZERO:
		shot_facing = actor.facing_direction

func _try_fire(actor: ActorBody, aim: Vector2) -> void:
	var cooldown: float = definition["cooldown"]
	if fire_cd_timer > 0.0:
		if cooldown > 0.5 and fire_cd_timer <= cooldown * 0.2:
			fire_buffered = true
		return
	_fire(actor, aim)

func _fire(actor: ActorBody, aim: Vector2) -> void:
	if reloading:
		return
	if has_magazine() and carried == 0:
		start_reload(actor)
		return
	var cap: int = definition["live_cap"]
	# 活弹上限使用当前模拟中的弹丸。
	if cap > 0 and actor.projectile_count.is_valid() and actor.projectile_count.call(type_id) >= cap:
		return
	fire_cd_timer = definition["cooldown"]
	var pose := muzzle_pose(actor, aim)
	actor.shot_serial += 1
	actor.step_actions.append({"kind": "fire", "type_id": type_id, "serial": actor.shot_serial,
		"pos": pose.origin, "dir": pose.x, "charge": charge_ratio(), "speed_mult": actor.pvp_haste_mult})
	if has_magazine():
		carried -= 1
		if carried == 0:
			start_reload(actor)
	actor.apply_recoil(definition["recoil"])

func state_values() -> Array:
	# 协议 19 保留两份朝向和装填标记，运行状态只持有朝向和剩余时间。
	return [fire_cd_timer, aiming, fire_buffered, shot_facing, shot_facing, reloading, reload_left, hold_elapsed]

func restore_state_values(values: Array) -> void:
	fire_cd_timer = values[StateSlot.COOLDOWN]
	aiming = values[StateSlot.AIMING]
	fire_buffered = values[StateSlot.BUFFERED]
	shot_facing = values[StateSlot.SHOT_FACING]
	reload_left = values[StateSlot.RELOAD_LEFT]
	hold_elapsed = values[StateSlot.HOLD]
