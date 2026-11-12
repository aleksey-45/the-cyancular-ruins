extends RefCounted

var failures: Array[String] = []
var checks := 0
var _worlds: Array[Node] = []
var _terrain: Terrain

## 角色就是自己的碰撞体：把真实体放到指定层，测试之间无需清理物理代理。
func collider(owner: ActorBody, layer: int) -> ActorBody:
	owner.collision_layer = layer
	owner._apply_layers()
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

func world(tree: SceneTree) -> Node2D:
	var walls := {}
	var texture := wall_texture()
	for x in 8: walls[Vector2i(x, 3)] = texture
	return world_with_walls(tree, 8, 4, walls)

func world_with_walls(tree: SceneTree, columns: int, rows: int, walls: Dictionary) -> Node2D:
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

## 用 16px 子格判定构造测试地形；solid 接收子格坐标并返回是否实心。
func world_from_solid(tree: SceneTree, columns: int, rows: int, solid: Callable) -> Node2D:
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

## 把测试网格装入当前物理空间，供两套地图构造共用。
func _install_world(tree: SceneTree, grid: Array[Array], descriptors: PackedInt32Array) -> Node2D:
	_terrain = Terrain.new(grid, descriptors)
	var viewport := SubViewport.new()
	viewport.world_2d = World2D.new()
	tree.root.add_child(viewport)
	var node := Node2D.new()
	viewport.add_child(node)
	_terrain.attach(node)
	_worlds.append(viewport)
	return node

func player(parent: Node, role: int = 1) -> Player:
	var actor: Player = preload("res://scenes/player/player.tscn").instantiate()
	actor.role = role
	actor.position = Vector2(96 + role * 64, 128)
	parent.add_child(actor)
	actor.enable_manual_simulation()
	actor.weapons.set_initial_inventory([WeaponRegistry.all_ids()[0]])
	return actor

## 释放本用例创建的场景与空间登记；不清理其它用例仍在使用的空间。
func cleanup() -> void:
	for node in _worlds: node.free()
	_worlds.clear()
	_terrain = null
