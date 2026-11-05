extends RefCounted

var failures: Array[String] = []
var checks := 0
var _worlds: Array[Node] = []
var _space := RID()

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
	var subs: Array[Array] = []
	for y in rows:
		var row: Array = []
		for x in columns:
			var texture: int = walls.get(Vector2i(x, y), 0)
			row.append(MapFormat.pack(texture, 15) if texture != 0 else 0)
		grid.append(row)
	for y in rows * 4:
		var row: Array = []
		for x in columns * 4: row.append(int(walls.get(Vector2i(x / 4, y / 4), 0)))
		subs.append(row)
	return _install_world(tree, columns, rows, grid, subs)

## 用 16px 子格判定构造测试地形；solid 接收子格坐标并返回是否实心。
func world_from_solid(tree: SceneTree, columns: int, rows: int, solid: Callable) -> Node2D:
	TileDefs.load_defs()
	var texture := wall_texture(false)
	var grid: Array[Array] = []
	var subs: Array[Array] = []
	for y in rows:
		var row: Array = []
		for x in columns:
			row.append(0)
		grid.append(row)
	for y in rows * 4:
		var row: Array = []
		for x in columns * 4:
			var filled: bool = solid.call(x, y)
			row.append(texture if filled else 0)
			if filled:
				grid[y / 4][x / 4] = MapFormat.pack(texture, 15)
		subs.append(row)
	return _install_world(tree, columns, rows, grid, subs)

## 把测试网格装入当前物理空间，供两套地图构造共用。
func _install_world(tree: SceneTree, columns: int, rows: int, grid: Array[Array], subs: Array[Array]) -> Node2D:
	TileDefs.load_terrain(grid, subs)
	GameParameters.MAP_WIDTH = columns * 64
	GameParameters.MAP_HEIGHT = rows * 64
	Level0.pvp_mode = true
	CombatComponent.pvp_arena = true
	var node := Node2D.new()
	tree.root.add_child(node)
	_space = node.get_world_2d().space
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

## 释放本用例创建的场景与空间登记；不清理其它用例仍在使用的空间。
func cleanup() -> void:
	for node in _worlds: node.free()
	_worlds.clear()
	CollisionWorld.release_space(_space)
	_space = RID()
