extends RefCounted

var failures: Array[String] = []
var _worlds: Array[Node] = []

func expect(condition: bool, message: String) -> void:
	if not condition: failures.append(message)

func world(tree: SceneTree) -> Node2D:
	TileDefs.load_defs()
	var texture := 0
	for key in TileDefs._defs["tiles"]:
		var material: Dictionary = TileDefs._defs["tiles"][key]
		if material["type"] == "wall" and material["hp"] > 1 and material["explosion_destroyable"] and not material["elastic"]:
			texture = int(key)
			break
	assert(texture > 0, "fixture needs a destructible, nonelastic wall with residual HP")
	var grid: Array[Array] = []
	var subs: Array[Array] = []
	for y in 4:
		var row: Array = []
		for x in 8: row.append(MapFormat.pack(texture, 15) if y == 3 else 0)
		grid.append(row)
	for y in 16:
		var row: Array = []
		for x in 32: row.append(texture if y >= 12 else 0)
		subs.append(row)
	TileDefs.load_terrain(grid, subs)
	GameParameters.MAP_WIDTH = 512
	GameParameters.MAP_HEIGHT = 256
	Level0.pvp_mode = true
	CombatComponent.pvp_arena = true
	var node := Node2D.new()
	tree.root.add_child(node)
	TileDefs.terrain.attach(node)
	_worlds.append(node)
	return node

func player(parent: Node, role: int = 1) -> Player:
	var actor: Player = preload("res://scenes/player/player.tscn").instantiate()
	actor.role = role
	actor.set_input_source(PacketInputSource.new())
	parent.add_child(actor)
	actor.enable_manual_simulation()
	actor.position = Vector2(96 + role * 64, 128)
	actor.weapons.set_initial_inventory([WeaponRegistry.all_ids()[0]])
	return actor

func cleanup() -> void:
	for node in _worlds: node.free()
	_worlds.clear()
