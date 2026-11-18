extends RefCounted

class TestWorld extends Node2D:
	var combat: CombatSimulator

	func _exit_tree() -> void:
		combat.close()

var failures: Array[String] = []
var checks := 0
var _worlds: Array[Node] = []
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
	TileDefs.load_defs()
	var grid: Array[Array] = []
	var descriptors := PackedInt32Array()
	descriptors.resize(columns * rows * 16)
	for y in rows:
		var row: Array = []
		for x in columns:
			var texture: int = walls.get(Vector2i(x, y), 0)
			row.append(MapFormat.pack(texture, 15) if texture != 0 else 0)
		grid.append(row)
	for y in rows * 4:
		for x in columns * 4:
			var texture: int = walls.get(Vector2i(x / 4, y / 4), 0)
			if texture != 0:
				descriptors[y * columns * 4 + x] = (texture << MapFormatV4.TEXTURE_SHIFT) | MapFormatV4.NEUTRAL_TINT
	return _install_world(tree, grid, descriptors)

## 按子格生成测试用的墙体。solid(x, y) 返回 true 时，该子格填入墙体纹理。
func world_from_solid(tree: SceneTree, columns: int, rows: int, solid: Callable) -> TestWorld:
	TileDefs.load_defs()
	var texture := wall_texture(false)
	var grid: Array[Array] = []
	var descriptors := PackedInt32Array()
	descriptors.resize(columns * rows * 16)
	for y in rows:
		var row: Array = []
		for x in columns:
			row.append(0)
		grid.append(row)
	for y in rows * 4:
		for x in columns * 4:
			if solid.call(x, y):
				descriptors[y * columns * 4 + x] = (texture << MapFormatV4.TEXTURE_SHIFT) | MapFormatV4.NEUTRAL_TINT
				grid[y / 4][x / 4] = MapFormat.pack(texture, 15)
	return _install_world(tree, grid, descriptors)

## 为测试创建 SubViewport 和单独的 World2D，使地形碰撞不影响其他测试场景。
func _install_world(tree: SceneTree, grid: Array[Array], descriptors: PackedInt32Array) -> TestWorld:
	_terrain = Terrain.new(grid, descriptors)
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

func detached_client() -> PvpMatchClient:
	var client := PvpMatchClient.new()
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
		if not points.has(cell) or used.has(cell) or at != authority.terrain.cell_center(cell):
			return false
		used[cell] = true
	return true

## 释放测试创建的视口及其子节点，并清空地形引用。
func cleanup() -> void:
	for node in _worlds: node.free()
	_worlds.clear()
	_terrain = null
