extends "res://tests/case.gd"

# 四角色接触差分实验：登记序作为唯一变量下的状态一致性（复刻对照实验矩阵）。
# 场景：平地四个贴合站立的角色，地板由两块相邻板拼成、接缝压在中间两个角色的
# 贴合边上——复刻真实对局"站在矩形边界上恢复多触点平局"的敏感形态。
# 注意：根视口下所有 Node2D 共享同一个 World2D，"两个空间"必须改为
# 同一空间内先后两次独立构建运行（先清场再重建），跨运行逐 tick 对比采样——
# 这也是双进程对照实验的等价形式。
#   自检：同序两次独立构建运行 → 期望零分歧（装置确定性）；
#   行 1（当前流程）：升序构建 vs 本地优先构建 → 期望分歧 > 0；
#   行 3（双方重登、乙仍本地优先序）→ 期望分歧 > 0；
#   行 4（双方重登、同 role 升序，保留原 RID）→ 期望零分歧。
# 行 4 即登记序统一修复所依赖的条件：客户端 apply_baseline 已实现，
# 服务器侧（authority_world）按本实验结论补齐。

const TICKS := 120
const BODY_LAYER := 2
const ROLES := [1, 2, 3, 4]
const ASC := [1, 2, 3, 4]
const LOCAL_FIRST := [4, 1, 2, 3]

var _box_bodies: Array[RID] = []

func run(tree: SceneTree) -> void:
	_contact_order(tree)
	for rid in _box_bodies:
		PhysicsServer2D.free_rid(rid)
	_box_bodies.clear()

func _contact_order(tree: SceneTree) -> void:
	_flat_map()
	# 自检：同序两次独立构建运行必须零分歧，否则装置本身不确定。
	var control := _diff(_run_once(tree, ASC, []), _run_once(tree, ASC, []))
	print("regorder 自检（同序两次独立运行）分歧采样: %d/%d" % [control, TICKS])
	expect(control == 0, "自检：同序两次独立运行应零分歧（装置确定性）")

	# 行 1：当前创建/登记流程——升序 vs 本地优先，无重登。
	var row1 := _diff(_run_once(tree, ASC, []), _run_once(tree, LOCAL_FIRST, []))
	print("regorder 行 1（升序 vs 本地优先）分歧采样: %d/%d" % [row1, TICKS])
	expect(row1 > 0, "行 1：不同登记序应产生分歧采样（复现顺序敏感）")

	# 行 3：双方重登，但乙保留 local-first 的不同登记顺序。
	var row3 := _diff(_run_once(tree, ASC, ASC), _run_once(tree, LOCAL_FIRST, LOCAL_FIRST))
	print("regorder 行 3（双方重登、乙仍本地优先）分歧采样: %d/%d" % [row3, TICKS])
	expect(row3 > 0, "行 3：重登顺序不一致应仍然分歧")

	# 行 4：双方重登、同 role 升序（保留原 RID）。
	var row4 := _diff(_run_once(tree, ASC, ASC), _run_once(tree, LOCAL_FIRST, ASC))
	print("regorder 行 4（双方重登、同序）分歧采样: %d/%d" % [row4, TICKS])
	expect(row4 == 0, "行 4：双方同序重登应零分歧（登记序统一条件成立）")

	# 行 5：全量重登——地形板与玩家体都按同一规范序（板→role 升序）移出重挂，
	# 完全抹掉骨架插入历史，等价于两端按同一全序全新构建。
	var row5 := _diff(_run_once(tree, ASC, ASC, true), _run_once(tree, LOCAL_FIRST, ASC, true))
	print("regorder 行 5（全量重登：地形+玩家同序）分歧采样: %d/%d" % [row5, TICKS])
	expect(row5 == 0, "行 5：全量同序重登应零分歧（地形骨架历史被抹平）")

func _diff(samples_a: Array, samples_b: Array) -> int:
	var divergent := 0
	for tick in samples_a.size():
		var sa: Dictionary = samples_a[tick]
		var sb: Dictionary = samples_b[tick]
		var hit := false
		for role in ROLES:
			if sa[role] != sb[role]:
				hit = true
				if divergent == 0:
					_dump_divergence(tick, role, sa[role], sb[role])
		if hit: divergent += 1
	return divergent

func _dump_divergence(tick: int, role: int, sa: Array, sb: Array) -> void:
	var pos := PlayerStateSchema.slot("pos")
	print("regorder 首次分歧 tick=%d role=%d pos=%s/%s" % [tick, role, sa[pos], sb[pos]])

## 在共享视口空间里独立地构建、步进、采样、清场一次。
## build_order 决定体的登记序（add_child 顺序）；reregister_order 非空时
## 在步进前按该顺序把全部玩家体移出并重挂空间（保留原 RID）；
## reregister_terrain 时连地形板一并先于玩家重挂（先板后玩家，同序）。
func _run_once(tree: SceneTree, build_order: Array, reregister_order: Array,
		reregister_terrain := false) -> Array:
	var node := Node2D.new()
	tree.root.add_child(node)
	_worlds.append(node)
	_space = node.get_world_2d().space
	_build_slabs()
	var actors := {}
	for role in build_order:
		actors[role] = player(node, role)
	var width: float = (actors[build_order[0]] as ActorBody).collision_rect().size.x
	# 间距恰为一个体宽（碰撞矩形贴合）；接缝压在 role2/role3 的贴合边上。
	# 碰撞矩形相对节点原点带偏移，落地高度按实际 rect 校正：底边贴在地板顶上 1px。
	for i in ROLES.size():
		var actor: ActorBody = actors[ROLES[i]]
		actor.collision_layer = BODY_LAYER
		actor.collision_mask = 1 | BODY_LAYER
		actor._apply_layers()
		actor.position = Vector2(196 + i * width, 100.0)
		actor.position.y += 191.0 - actor.collision_rect().end.y
	for role in build_order:
		var actor: ActorBody = actors[role]
		CollisionWorld.sync_body_pose(actor.get_rid(), actor.global_transform)
	if reregister_terrain:
		# 全量重登：先板后玩家，同一全序——移出时树被清空，重挂即全新同构骨架。
		_reregister_bodies(_box_bodies)
	if not reregister_order.is_empty():
		_reregister(actors, reregister_order)
	var samples: Array = []
	for tick in TICKS:
		for role in ROLES:
			ActorStep.step(actors[role], InputBuffer.neutral())
		var snapshot := {}
		for role in ROLES:
			snapshot[role] = (actors[role] as ActorBody).capture_state()
		samples.append(snapshot)
	node.free()
	_worlds.pop_back()
	for rid in _box_bodies:
		PhysicsServer2D.free_rid(rid)
	_box_bodies.clear()
	return samples

func _build_slabs() -> void:
	# 两块相邻地板（接缝 x=271），按固定数据序创建——对应真实对局里确定性的地形登记。
	var specs := [
		[Vector2(183.5, 200), Vector2(175, 16)],
		[Vector2(358.5, 200), Vector2(175, 16)],
	]
	for spec in specs:
		var body := PhysicsServer2D.body_create()
		PhysicsServer2D.body_set_mode(body, PhysicsServer2D.BODY_MODE_STATIC)
		PhysicsServer2D.body_set_collision_layer(body, 1)
		PhysicsServer2D.body_set_collision_mask(body, 0)
		var shape := RectangleShape2D.new()
		shape.size = spec[1]
		PhysicsServer2D.body_add_shape(body, shape)
		PhysicsServer2D.body_set_state(body, PhysicsServer2D.BODY_STATE_TRANSFORM,
				Transform2D(0.0, spec[0]))
		PhysicsServer2D.body_set_space(body, _space)
		_box_bodies.append(body)

func _reregister(actors: Dictionary, order: Array) -> void:
	# 保留原 RID：仅从物理空间移出再按给定顺序重新挂入。
	for role in order:
		var rid: RID = (actors[role] as ActorBody).get_rid()
		PhysicsServer2D.body_set_space(rid, RID())
		PhysicsServer2D.body_set_space(rid, _space)

func _reregister_bodies(bodies: Array[RID]) -> void:
	for rid in bodies:
		PhysicsServer2D.body_set_space(rid, RID())
		PhysicsServer2D.body_set_space(rid, _space)

func _capture(actors: Dictionary) -> Dictionary:
	var states := {}
	for role in ROLES: states[role] = (actors[role] as ActorBody).capture_state()
	return states

func _flat_map() -> void:
	# 空地图数据：只供水体/缠绕判定使用；几何由裸 RID 板提供，块体不入空间。
	var grid: Array[Array] = []
	var subs: Array[Array] = []
	for y in 4:
		var row := []
		for x in 8: row.append(0)
		grid.append(row)
	for y in 16:
		var row := []
		for x in 32: row.append(0)
		subs.append(row)
	TileDefs.load_terrain(grid, subs)
	GameParameters.MAP_WIDTH = 512
	GameParameters.MAP_HEIGHT = 256
	Level0.pvp_mode = true
	CombatComponent.pvp_arena = true
