class_name MatchSnapshot
extends MatchGround

# 60Hz 快照广播域(阶段 5.6 拆自 server/match_host.gd)。

func _broadcast_snapshot() -> void:
	_snap_tick += 1
	# ① **世界包**:全部玩家的渲染字段(副本位置/姿态/朝向/武器/血条用)。构造一次、广播一次。
	var world := {"tick": _snap_tick, "players": {}}
	for role in players:
		var p: Node2D = players[role]
		# 是否正在预瞄(heavy_aim 蓄力):给对手副本画预瞄红线/弧(所有有预瞄的武器)。
		# ★ 服务端仍带此字段,但客户端刻意**不消费**(用户裁定 2026-09-11:预瞄线只有使用者本人可见;
		#   见 player_replica._previewing 的注释)—— 留着是给日后换成音效/轮廓等提示形式的接点。
		var previewing := false
		if p.weapons != null and p.weapons.current_weapon() != null:
			previewing = p.weapons.current_weapon().is_previewing()
		world["players"][str(role)] = {
			"pos": p.global_position,
			"vel": p.velocity,
			"facing": p.get_facing(),
			"pose": p.state,
			"weapon": p.weapons.current_slot_int(),
			"hp": p.hp,
			"waterproof": p.waterproof,
			"downed": p.is_downed(),
			"aim": p.get_current_aim_dir(),
			"previewing": previewing,
		}
	# ★ 一次 rpc():ENet 层单次序列化 + 广播。逐 rpc_id 循环会把 O(N²) 加回来(那正是拆包要治的)。
	# 这条守卫只是为了"一个 peer 都没有时别发包"(原实现逐 peer 判 live_peers 的作用);
	# 拆成广播后无法再逐 peer 判,代价是"刚断开"窗口里会多一条 channel 错误 —— 可接受,且丢失无后果。
	if not multiplayer.get_peers().is_empty():
		NetBus.rpc("snapshot_world", world)
	# ② **本人包**:各自的 ack + 权威整态 c2 —— 只有本人需要(客户端 rollback 拿它锚定/重放)。
	# 逐 peer 定向(体积小,不构成 O(N²))。仍判 live peer:避免给正在断开的客户端发 ——
	# ★ 这是全项目**最频繁**的一处定向发送(60Hz × 每个 role),所以判据必须不滞后:用
	#   `NetBus.is_peer_live`(读 ENet peer 自己的 state),不是 `get_peers()`。
	#   (本条走 unreliable → 通道 1,报出来会是 "channel **1**" 那一版;用户看到的那条
	#    "channel 0" 只可能来自 **reliable** 的定向包,见 NetBus.is_peer_live 的注释。)
	for role in peer_by_role:
		if not NetBus.is_peer_live(peer_by_role[role]):
			continue
		var p: Node2D = players.get(role)
		if p == null:
			continue
		var c2 := {}
		if p.has_method("capture_state"):
			c2 = p.capture_state()
		NetBus.rpc_id(peer_by_role[role], "snapshot_own",
				{"ack_seq": _ack_seq.get(role, 0), "c2": c2})

# 子弹裁决:遍历 bullet 组。新子弹广播给非射手客户端;命中判定 = 与对手玩家的 toroidal 距离 < HIT_RADIUS。
