class_name MatchHost
extends RefCounted

class RemoteSeat extends InputScheduler:
	var life: int
	var rewinding: bool

	func sync(player: Player) -> void:
		if life != player.life or (rewinding and not player.rewinding):
			reset(epoch + 1)
		life = player.life
		rewinding = player.rewinding

var world: MatchWorld
var remote: Dictionary[int, RemoteSeat] = {}
var _commands: Array = []

func _init(spec: WorldSpec, local_role := 0) -> void:
	world = MatchWorld.new(spec)
	for id: int in spec.roles:
		if id != local_role:
			remote[id] = RemoteSeat.new()
			remote[id].life = world.players[id].life

func enqueue(command: int, seat := 0) -> void:
	_commands.append([command, seat])

func accept_input(id: int, packet: Array, received_us: int) -> void:
	var seat := remote[id]
	if not world.finished and not seat.submit(packet, world.tick, received_us):
		seat.reset(seat.epoch + 1)

func packet(grace: Dictionary) -> Dictionary:
	var inputs := {}
	for id: int in world.players:
		if remote.has(id):
			inputs[id] = remote[id].confirmed()
		else:
			# 本地席位当帧生效。其他客户端仅用其持续输入来外推移动。
			var input := world.players[id].step_input
			inputs[id] = [1, 0, world.tick, 1, world.tick, input.axis, input.held, input.aim]
	return {"checkpoint": world.capture(), "inputs": inputs, "grace": grace, "input_feedback": PackedByteArray()}

func fixed_step(direct: Dictionary = {}) -> void:
	var inputs := {}
	for id: int in remote:
		inputs[id] = remote[id].take(world.tick + 1)
	inputs.merge(direct, true)
	world.advance(inputs, _commands)
	_commands.clear()
	for id: int in remote.keys():
		if world.players.has(id):
			remote[id].sync(world.players[id])
		else:
			remote.erase(id)
