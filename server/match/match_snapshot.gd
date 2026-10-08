class_name MatchSnapshot
extends MatchGround

# 60Hz 权威状态快照广播模块。

func _broadcast_snapshot() -> void:
	_snap_tick += 1
	# 1. 世界状态包：包含全部角色的渲染与物理状态（副本坐标、速度、朝向、姿态、手持武器、生命值等）。
	# 全局单次组包并广播给所有客户端。
	var world := {"tick": _snap_tick, "players": {}}
	for role in players:
		var p: Node2D = players[role]
		# 预瞄蓄力状态检测
		var previewing := false
		if p.weapons != null and p.weapons.current_weapon() != null:
			previewing = p.weapons.current_weapon().is_previewing()
		world["players"][str(role)] = {
			"pos": p.global_position,
			"vel": p.velocity,
			"facing": p.get_facing(),
			"pose": p.state,
			"type_id": p.weapons.current_type_id(),
			"hp": p.hp,
			"waterproof": p.waterproof,
			"downed": p.is_downed(),
			"aim": p.get_current_aim_dir(),
			"previewing": previewing,
			# 时间机制状态同步：角色是否处于时间加速或回溯状态
			"haste": p.pvp_haste_mult > 1.0,
			"rewind": bool(_rw_on.get(int(role), false)),
			"trail": (_rw_trail.get(int(role), []) as Array).duplicate(),
		}
	# 世界状态包不可靠广播：必须校验所有在线 peer 均处于可发送状态，避免向正在断开的连接发送导致通道错误
	if NetBus.all_peers_sendable():
		NetBus.rpc("snapshot_world", world)
	# 2. 本人权威状态包：向各客户端定向同步其自身最新的输入确认号 ack_seq 与权威物理完整快照 c2。
	# 客户端根据此包进行预测回滚校正。
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

# 子弹命中判定与物理模拟由 MatchCombat 模块管理。
