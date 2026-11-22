extends RefCounted

class TestWorld extends Node2D:
	var combat: CombatSimulator

	func _exit_tree() -> void:
		combat.close()

var failures: Array[String] = []
var checks := 0
var _worlds: Array[Node] = []
var _document: Dictionary
var _terrain: Terrain

## 测试角色使用指定的碰撞层。设置会立即应用到物理服务器中的物理体。
func collider(owner: Player, layer: int) -> Player:
	owner.collision_layer = layer
	return owner

func expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition: failures.append(message)

func wall_texture(elastic: bool = false) -> int:
	TileDefs.load_defs()
	for key in TileDefs._defs["tiles"]:
		var material: Dictionary = TileDefs._defs["tiles"][key]
		if material["type"] == "wall" and material["hp"] > 1 and material["bullet_destroyable"] \
				and material["explosion_destroyable"] and bool(material["elastic"]) == elastic:
			return int(key)
	assert(false, "fixture needs a destructible wall with the requested elasticity")
	return 0

func world(tree: SceneTree) -> TestWorld:
	var walls := {}
	var texture := wall_texture()
	for x in 8: walls[Vector2i(x, 3)] = texture
	return world_with_walls(tree, 8, 4, walls)

func world_with_walls(tree: SceneTree, columns: int, rows: int, walls: Dictionary) -> TestWorld:
	var map := CyrmMap.create(Vector2i(columns, rows) * 4)
	var cells: PackedInt32Array = map.layers[CyrmMap.SCENE]
	for tile: Vector2i in walls:
		var value := CyrmMap.tile_value(walls[tile])
		for y in 4:
			for x in 4: cells[(tile.y * 4 + y) * map.size.x + tile.x * 4 + x] = value
	return _install_world(tree, map)

func world_from_solid(tree: SceneTree, columns: int, rows: int, solid: Callable) -> TestWorld:
	var map := CyrmMap.create(Vector2i(columns, rows) * 4)
	var cells: PackedInt32Array = map.layers[CyrmMap.SCENE]
	var value := CyrmMap.tile_value(wall_texture())
	for y in map.size.y:
		for x in map.size.x:
			if solid.call(x, y): cells[y * map.size.x + x] = value
	return _install_world(tree, map)

func block_hp(terrain: Terrain, block: Vector2i) -> PackedInt32Array:
	var result := PackedInt32Array()
	for y in 4:
		for x in 4: result.append(terrain.get_hp(block * 4 + Vector2i(x, y)))
	return result

func _install_world(tree: SceneTree, map: Dictionary) -> TestWorld:
	_document = map
	_terrain = Terrain.new(map)
	var viewport := SubViewport.new()
	viewport.world_2d = _terrain.physics.world
	tree.root.add_child(viewport)
	var node := TestWorld.new()
	node.combat = CombatSimulator.new(_terrain)
	viewport.add_child(node)
	_worlds.append(viewport)
	return node

func canvas_for(parent: Node) -> WorldCanvas:
	var canvas := WorldCanvas.new()
	parent.add_child(canvas)
	return canvas

func detached_client(actor: Player) -> PvpMatchClient:
	var client := PvpMatchClient.new()
	client.player = actor
	client.combat_rules = actor.combat
	client.terrain = actor.terrain
	client._rollback.bind(actor)
	client._playback.map_px = actor.terrain.map_size
	client._camera = MatchCamera.new()
	client.add_child(client._camera)
	return client

func player(parent: TestWorld, role: int = 1) -> Player:
	var actor := parent.combat.add_player(role)
	actor.position = Vector2(96 + role * 64, 128)
	actor.sync_collision_geometry()
	actor.weapons.set_initial_inventory([WeaponRegistry.all_ids()[0]])
	return actor

func players_on_map_points(authority: AuthorityWorld, roles: Array, points: Array) -> bool:
	var used := {}
	for role: int in roles:
		var at: Vector2 = authority.players[role].position
		var cell := authority.terrain.cell(at)
		if not points.has(cell) or used.has(cell) or at != CyrmMap.world_position(cell):
			return false
		used[cell] = true
	return true

## 释放测试创建的视口及其子节点，并清空地形引用。
func cleanup() -> void:
	for node in _worlds: node.free()
	_worlds.clear()
	_terrain = null
	_document = {}
