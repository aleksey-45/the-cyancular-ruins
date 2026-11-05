class_name SnapshotSystem
extends RefCounted

# 快照广播系统(C 方案 S1):只依赖 state + ports。tick 域 = 60Hz 物理 tick,每 tick 一包。
# 世界/本人包都是全量、每包自包含(v7 起无 DELTA)。

var _state: MatchState = null
var _ports: MatchPorts = null

# 诊断(--diag,默认关):快照发出侧计数(客户端 snap_gap 只能证明"没收到")。
var _tx_at := 0
var _tx_world := 0
var _tx_world_skip := 0
var _tx_world_bytes := 0
var _tx_own: Dictionary = {}        # role -> 包数
var _tx_own_bytes: Dictionary = {}  # role -> 字节数


func bind(state: MatchState, ports: MatchPorts) -> void:
	_state = state
	_ports = ports


func broadcast() -> void:
	# tick 是 60Hz 物理 tick 时间轴上的时间戳,不是包序号。
	_state._snap_tick = _state._srv_tick
	var snap := {"tick": _state._snap_tick, "players": {}}
	for role in _state.players:
		var p: Node2D = _state.players[role]
		# 是否正在预瞄(heavy_aim 蓄力):服务端仍带此字段,客户端刻意不消费(只有使用者本人可见)。
		var previewing := false
		if p.weapons != null and p.weapons.current_weapon() != null:
			previewing = p.weapons.current_weapon().is_previewing()
		snap["players"][str(role)] = {
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
			# Beta 时间玩法:该 role 当前是否加速(客户端副本视效用;倍率由规则同源推出)
			"haste": p.pvp_haste_mult > 1.0,
			# 回溯:该 role 是否在回溯 + 轨迹点(每 3 帧一个)
			"rewind": bool(_state._rw_on.get(int(role), false)),
			"trail": (_state._rw_trail.get(int(role), []) as Array).duplicate(),
		}
	# ★ 一次 rpc():ENet 层单次序列化 + 广播。逐 rpc_id 循环会把 O(N²) 加回来。
	if not bool(_ports.net_peers_sendable.call()):
		# 整发跳过:一个 peer 处于拆链路窗口 ⇒ 这一帧所有端都没世界包。
		_tx_world_skip += 1
		return
	var wbytes := NetCodec.encode_world(snap)
	_ports.net_broadcast.call("snapshot_world", [wbytes])
	_tx_world += 1
	_tx_world_bytes += wbytes.size()


func send_own() -> void:
	for role in _state.peer_by_role.keys():
		var p: Node2D = _state.players.get(role)
		if p == null:
			continue
		var c2 := {}
		if p.has_method("capture_state"):
			c2 = p.capture_state()
		# `q` = 本 role 此刻已到达但还没被消费的输入**记录**数(判据与口径见 docs/eng/netcode-snapshots.md §6)。
		var q: Array = _state._pending_input.get(role, [])
		var obytes := NetCodec.encode_own({
			"ack_seq": _state._ack_seq.get(role, 0), "q": q.size(), "c2": c2, "tick": _state._srv_tick,
		})
		_ports.net_rpc_role.call(int(role), "snapshot_own", [obytes])
		_tx_own[role] = int(_tx_own.get(role, 0)) + 1
		_tx_own_bytes[role] = int(_tx_own_bytes.get(role, 0)) + obytes.size()
	_snapshot_tx_diag()


func _snapshot_tx_diag() -> void:
	if not NetDiag.enabled():
		return
	var now := Time.get_ticks_msec()
	if _tx_at == 0:
		_tx_at = now
		return
	if now - _tx_at < 1000:
		return
	var own := {}
	for role in _tx_own:
		own[int(role)] = {"msgs": int(_tx_own[role]), "bytes": int(_tx_own_bytes.get(role, 0))}
	NetDiag.log_metric("snapshot_tx", {
		"interval_ms": now - _tx_at,
		"world_msgs": _tx_world,
		"world_bytes": _tx_world_bytes,
		"world_skipped": _tx_world_skip,
		"own": own,
		"peers": int(_ports.net_peer_count.call()),
	})
	_tx_at = now
	_tx_world = 0
	_tx_world_skip = 0
	_tx_world_bytes = 0
	_tx_own.clear()
	_tx_own_bytes.clear()
