extends "res://tests/case.gd"

# 副本滞后差分实验：判定 ≥10px 位置校正的成因归属（纯预测位置差 vs 逻辑/时序/判定问题）。
# 结构与线上完全同构：server 空间逐拍权威步进；client 空间由 PredictionRollback 预测，
# 每 snap_every 拍收到一次权威快照，快照之间 _step_remote 用冻结输入推演远端角色。
# 本地输入经 rollback.capture() 入队（与 advance 相同管线），重演路径因此带完整输入。
#
#   阶段 1（press，快照每 2 拍）：两角色贴身同速同行，远端输入全程无变化
#       —— 预测 vs 权威逐拍位差必须 < 0.5px：输入一致时推进、接触恢复、阻挡判定逐位一致，
#         不存在独立的逻辑/时序/判定误差。
#   阶段 2（turn，快照每 2 拍）：贴身同行中领头者（远端）在第 15 拍调头压向跟随者。
#       陈旧副本继续以全速"逃离"，预测端跟随者全速追入缺口（未被阻挡）；
#       权威端真身回头压住跟随者（被阻挡、速度清零、原地不动）。
#       每陈旧一拍分歧增长 ≈ 700/60 = 11.67px，2 拍快照下尖峰 ≈ 21px（对应线上 12~22px 簇）。
#   阶段 3（turn，快照每 1 拍）：同一剧本，滞后 1 拍 —— 尖峰减半 ≈ 9px。
#       尖峰幅度只由"快照节奏 × 移动速度"决定，与判定逻辑无关。
#
# 关键抵消机制（实验中实证）：陈旧输入若把副本"压向"本地角色，接触阻挡会吸收它（零位移）；
# 只有陈旧输入让副本"远离"本地角色时，预测端追入缺口才产生分歧——这正是线上
# 校正集中在贴身追停/调头时刻、且幅度量子化为 11.67px 整数倍的原因。

const TICKS := 32
const LEAD := 4          # 预测钟超前权威的拍数（对齐线上 lag ≈ -2 ~ -4）
const TURN_TICK := 15    # 领头者调头拍
const SHOOT_TICKS := 240  # 射击破墙阶段时长（足够打穿低耐久墙）

var _views: Array[SubViewport] = []
var _terrains: Array[Terrain] = []

func run(tree: SceneTree) -> void:
	var press := _run(tree, 2, "press")
	var turn2 := _run(tree, 2, "turn")
	var turn1 := _run(tree, 1, "turn")
	var shoot := _run(tree, 2, "shoot")
	print("replicalag press snap=2 max=%.2fpx" % press["max_d"])
	print("replicalag turn  snap=2 max=%.2fpx (tick %d) heal=%.2fpx" % [
			turn2["max_d"], turn2["spike_tick"], turn2["heal_d"]])
	print("replicalag turn  snap=1 max=%.2fpx (tick %d) heal=%.2fpx" % [
			turn1["max_d"], turn1["spike_tick"], turn1["heal_d"]])
	print("replicalag shoot snap=2 max=%.2fpx wallgen srv=%d cli=%d" % [
			shoot["max_d"], shoot["srv_gen"], shoot["cli_gen"]])
	for row: Array in turn2["series"]:
		if row[0] >= 14 and row[0] <= 17:
			print("replicalag t=%s d=%s rerr=%s pred1x=%s auth1x=%s repl2x=%s real2x=%s pv1=%s av1=%s" % [
					row[0], row[1], row[2], row[3], row[4], row[5], row[6], row[7], row[8]])
	expect(press["max_d"] < 0.5, "阶段1 恒定输入含贴身同行：预测与权威逐拍位差 < 0.5px（实测 %.2f）——推进/接触/阻挡判定确定" % press["max_d"])
	expect(turn2["max_d"] >= 6.0 and turn2["max_d"] <= 24.0,
			"阶段2 贴身同行+领头者调头+2拍快照：陈旧副本逃离 vs 真身回头压住，尖峰 ≈ 1~2×11.67px（实测 %.2f）" % turn2["max_d"])
	expect(turn2["heal_d"] < 0.5, "阶段2 携带调头的快照到达后自愈（实测 %.2f）" % turn2["heal_d"])
	expect(turn1["max_d"] < turn2["max_d"] and turn1["max_d"] < 5.0,
			"阶段3 1拍快照无陈旧窗口：分歧随之消失（实测 %.2f < %.2f）" % [turn1["max_d"], turn2["max_d"]])
	expect(shoot["srv_hp"] == shoot["cli_hp"],
			"阶段4 连续射击破墙：两端墙格 hp 账本逐位一致（srv=%s cli=%s）" % [shoot["srv_hp"], shoot["cli_hp"]])
	expect(shoot["max_d"] < 0.5, "阶段4 边走边射+顶墙+地形逐拍破坏：预测与权威位差 < 0.5px（实测 %.2f）——弹道/命中/地形变异时序确定" % shoot["max_d"])

# 一轮实验：snap_every=快照节奏拍数；mode="press" 恒定输入 / "turn" 领头者中途调头 /
# "shoot" 边走边射可破坏墙（检验弹道、命中与地形变异时序的确定性）。
func _run(tree: SceneTree, snap_every: int, mode: String) -> Dictionary:
	cleanup()
	var walls := {}
	if mode == "shoot":
		var tex := wall_texture(false)
		walls = {Vector2i(13, 3): tex, Vector2i(13, 4): tex}
	var server := _flat_world(tree, walls)
	var client := _flat_world(tree, walls)
	var floor_y: float = server["floor_y"]
	var ticks := SHOOT_TICKS if mode == "shoot" else TICKS
	# ── 权威侧：a1 为本地角色（跟随者），a2 为远端（领头者），贴身同行 ──
	TileDefs.terrain = server["terrain"]
	var a1 := player(server["view"], 1)
	var a2 := player(server["view"], 2)
	a1.team = 1
	a2.team = 2
	if mode != "shoot":
		for body: Player in [a1, a2]:
			body.weapons.set_initial_inventory([])
	if mode == "shoot":
		a1.global_position = Vector2(500, floor_y - 57.08)
		a2.global_position = Vector2(1300, floor_y - 57.08)
	else:
		a1.global_position = Vector2(619.92, floor_y - 57.08)
		a2.global_position = Vector2(700.0, floor_y - 57.08)
	a1._grounded = true
	a2._grounded = true
	a1.collision_layer = CollisionWorld.team_layer(1)
	a1.collision_mask = 1 | CollisionWorld.team_layer(2)
	a2.collision_layer = CollisionWorld.team_layer(2)
	a2.collision_mask = 1 | CollisionWorld.team_layer(1)
	a1._apply_layers()
	a2._apply_layers()
	a1.sync_collision_geometry()
	a2.sync_collision_geometry()
	# ── 客户端预测侧 ──
	TileDefs.terrain = client["terrain"]
	var local := player(client["view"], 1)
	local.team = a1.team
	local.weapons.set_initial_inventory([])
	local.global_position = a1.global_position
	local._grounded = true
	local.collision_layer = a1.collision_layer
	local.collision_mask = a1.collision_mask
	local._apply_layers()
	local.sync_collision_geometry()
	var rollback := PredictionRollback.new()
	rollback.bind(local)
	rollback.terrain = client["terrain"]
	rollback.world.ensure_actor(2, a2.team)
	rollback.reset(1, 0, 0, 0)
	# 预热 step_input：第 0 拍快照携带第 1 拍的输入轴，避免副本启动期人为停滞。
	a1.step_input.prepare(_move_record(1.0), false)
	a2.step_input.prepare(_move_record(_leader_axis(1, mode)), false)
	rollback.world.restore_authority(_frame(0, {1: a1, 2: a2}))
	var source := PacketInputSource.new()
	var series: Array = []
	var max_d := 0.0
	var spike_tick := -1
	var local_held := ActorInput.BIT_ATTACK if mode == "shoot" else 0
	for at in range(1, ticks + 1):
		# 权威步进：跟随者恒速右行；领头者按剧本（press 恒右行 / turn 第 15 拍调头左行 /
		# shoot 远端原地，本地边走边射）。
		TileDefs.terrain = server["terrain"]
		ActorStep.step(a1, _move_record(1.0, local_held))
		ActorStep.step(a2, _move_record(0.0 if mode == "shoot" else _leader_axis(at, mode)))
		# 客户端预测：本地输入经 capture 入队（与 advance 同管线）。
		# capture 前把钟拨到 at-1，使记录 target=at，与服务端应用拍一致；
		# 随后钟跳到 at+LEAD 推满预测窗。
		TileDefs.terrain = client["terrain"]
		source.apply_packet({"seq": at, "ax": 1.0, "held": local_held, "pressed": 0,
				"released": 0, "winst": 0, "aim": Vector2.RIGHT})
		rollback._clock = at - 1
		rollback.capture(source, Vector2.RIGHT, 0)
		rollback._clock = at + LEAD
		if rollback.world.tick < int(rollback._clock):
			rollback._input.push(rollback.packet(), rollback.world.tick)
		while rollback.world.tick < int(rollback._clock):
			rollback._player.begin_visual_step()
			rollback._step(rollback._input.take(rollback.world.tick + 1), true)
		# reconcile 之前测位差（与线上 corr 的 d 同口径）；副本误差取同拍快照。
		var predicted: Vector2 = rollback._states[at].player[PlayerStateSchema.slot("pos")]
		var authoritative: Vector2 = a1.capture_state()[PlayerStateSchema.slot("pos")]
		var d: float = predicted.distance_to(authoritative)
		var replica_pos: Vector2 = rollback._states[at].remote[2][0]
		var replica_err: float = replica_pos.distance_to(a2.global_position)
		series.append([at, snappedf(d, 2), snappedf(replica_err, 2),
				snappedf(predicted.x, 1), snappedf(authoritative.x, 1),
				snappedf(replica_pos.x, 1), snappedf(a2.global_position.x, 1),
				snappedf((rollback._states[at].player[PlayerStateSchema.slot("vel")] as Vector2).x, 1),
				snappedf((a1.capture_state()[PlayerStateSchema.slot("vel")] as Vector2).x, 1)])
		if d > max_d:
			max_d = d
			spike_tick = at
		if at % snap_every == 0:
			rollback.reconcile(_frame(at, {1: a1, 2: a2}), 0, false)
	var heal_index: int = mini(spike_tick + 2, ticks) - 1
	var heal_d: float = series[heal_index][1] if not series.is_empty() else 0.0
	var srv_gen: int = server["terrain"].generation
	var cli_gen: int = client["terrain"].generation
	# 墙格伤害账本与存留状态逐位比对（generation 只是预测簿记，两端语义不同）。
	var wall_cells: Array = walls.keys()
	var srv_hp := {}
	var cli_hp := {}
	for cell: Vector2i in wall_cells:
		srv_hp[cell] = server["terrain"].get_hp(cell)
		cli_hp[cell] = client["terrain"].get_hp(cell)
	rollback.combat_prediction.clear()
	cleanup()
	return {"max_d": max_d, "spike_tick": spike_tick, "heal_d": heal_d, "series": series,
			"srv_gen": srv_gen, "cli_gen": cli_gen, "srv_hp": srv_hp, "cli_hp": cli_hp}

func _leader_axis(at: int, mode: String) -> float:
	if mode == "press" or at < TURN_TICK:
		return 1.0
	return -1.0

func _move_record(ax: float, held: int = 0) -> Dictionary:
	return {"seq": 0, "epoch": 1, "target_tick": 0, "ax": ax, "held": held,
			"pressed": 0, "released": 0, "winst": 0, "aim": Vector2.RIGHT}

# 权威广播记录：capture_state 前缀 + 远端表现槽（与 authority_world.world_state 同构）。
func _authority_record(body: Player) -> Array:
	var values := body.capture_state()
	values.resize(PlayerStateSchema.ACTOR_SIZE)
	values[PlayerStateSchema.slot("locked")] = false
	values[PlayerStateSchema.slot("aim")] = Vector2.RIGHT
	values[PlayerStateSchema.slot("type_id")] = body.weapons.current_type_id()
	values[PlayerStateSchema.slot("epoch")] = 1
	values[PlayerStateSchema.slot("previewing")] = false
	values[PlayerStateSchema.slot("haste")] = false
	values[PlayerStateSchema.slot("rewind")] = body.rewinding
	values[PlayerStateSchema.slot("axis")] = body.step_input.axis
	values[PlayerStateSchema.slot("held")] = body.step_input.held
	values[PlayerStateSchema.slot("move_mult")] = body.weapons.movement_multiplier()
	values[PlayerStateSchema.slot("respawn_tick")] = 0
	values[PlayerStateSchema.slot("rewind_path")] = []
	return values

func _frame(at: int, authority: Dictionary) -> Dictionary:
	var records := {}
	for role in authority:
		records[role] = _authority_record(authority[role])
	return {"tick": at, "map_revision": 0,
		"own": {"state": authority[1].capture_state(), "epoch": 1,
			"ack": 0, "action_ack": 0, "timing_seq": 0, "lead": 2,
			"input": InputBuffer.neutral(), "rewind": authority[1].rewinding},
		"world": {"players": records, "projectiles": {}}, "time": {}}

# 独立 SubViewport 物理空间 + 平地（底行整行墙体），真正的"两个空间"。
# walls：额外放置的可破坏墙瓦片（shoot 模式用于地形变异确定性检验）。
func _flat_world(tree: SceneTree, walls: Dictionary = {}) -> Dictionary:
	TileDefs.load_defs()
	var columns := 24
	var rows := 6
	var texture := wall_texture(false)
	var grid: Array[Array] = []
	var subs: Array[Array] = []
	for y in rows:
		var row := []
		for x in columns:
			row.append(MapFormat.pack(texture, 15) if y == rows - 1 else 0)
		grid.append(row)
	for y in rows * 4:
		var row := []
		for x in columns * 4:
			var cell := Vector2i(x / 4, y / 4)
			row.append(walls.get(cell, texture if y >= (rows - 1) * 4 else 0))
		subs.append(row)
	var view := SubViewport.new()
	view.world_2d = World2D.new()
	view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	tree.root.add_child(view)
	_views.append(view)
	var geometry := Terrain.new()
	geometry.configure(grid, subs, TileDefs._defs,
			{"tile_size": Terrain.TILE_SIZE, "sub_size": Terrain.SUB_SIZE,
			"chunk_cells": Terrain.CHUNK_CELLS, "cache_states": Terrain.CACHE_STATES,
			"wall_type": TileDefs.TYPE_WALL, "liquid_type": TileDefs.TYPE_LIQUID,
			"ledge_thickness": Terrain.LEDGE_THICKNESS, "blast_inner": TileDefs.BLAST_INNER_FRACTION})
	geometry.attach(view)
	geometry.flush_collisions()
	_terrains.append(geometry)
	GameParameters.MAP_WIDTH = columns * 64
	GameParameters.MAP_HEIGHT = rows * 64
	Level0.pvp_mode = true
	CombatComponent.pvp_arena = true
	return {"view": view, "terrain": geometry, "floor_y": float((rows - 1) * 64)}

func cleanup() -> void:
	for geometry in _terrains: geometry.close()
	_terrains.clear()
	for view in _views:
		CollisionWorld.release_space(view.world_2d.space)
		view.free()
	_views.clear()
	super()
