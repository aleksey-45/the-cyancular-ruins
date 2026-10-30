class_name MatchSnapshot
extends MatchGround

# 快照广播域(阶段 5.6 拆自 server/match_host.gd)。★ tick 域始终是 60Hz 物理 tick;
# 2026-10-30 起**所有人数**都每 tick 一包(60Hz,stride=1)—— 副本插值样本间隔 16.7ms。

# ── 结构化诊断(--diag,默认关):快照**发出侧**计数 ──
# 客户端 `snap_gap`(net_bus)只能证明"没收到";这里补"服务器到底发没发、给谁发了多少、
# 哪一拍因为某个 peer 不可发而**整发跳过**"。两边按 1Hz 对账即可分开「没发出 / 发了没收到」——
# 那正是大乱斗 C3(单 peer 快照饥饿)下一步要的证据。默认关时下面每处计数都是 0 开销(一个 bool)。
var _tx_at := 0
var _tx_world := 0
var _tx_world_skip := 0
var _tx_world_bytes := 0
var _tx_own: Dictionary = {}        # role -> 包数
var _tx_own_bytes: Dictionary = {}  # role -> 字节数

# ── 全量快照(2026-10-28 放弃增量:世界/本人包恢复每包自包含)──
# ★ 为什么回退:DELTA 依赖 base_tick 链,unreliable 通道乱序/丢包时恢复代价是 RTT 级冻结
#   (用户实测"联机对手显示卡");v0.5.1 就是全量,实测不卡 —— 带宽换稳定。


func _broadcast_snapshot() -> void:
	# tick 是「60Hz 物理 tick 时间轴」上的时间戳,不是包序号:60Hz 发包时每包跨 1 tick(客户端 playout/历史环按它插值)。
	# ★ S1(2026-10-24):本函数**只发世界包**;本人包(ack+c2)由 MatchHost 在玩家步进之后 call_deferred 调,不再等广播。
	# ★ 时间域对齐:直接取 _srv_tick(广播相位仍每 2 tick,数值序列不变)⇒ 客户端输入包的 st 与服务器 tick 同刻度。
	# ★ 2026-10-28:增量已放弃 —— 世界包每包全量(自包含),乱序/丢包只损失那一帧;DELTA 能力留在编解码里不再上线。
	_snap_tick = _srv_tick
	var state := {"tick": _snap_tick, "players": {}}
	for role in players:
		var p: Node2D = players[role]
		# 是否正在预瞄(heavy_aim 蓄力):给对手副本画预瞄红线/弧(所有有预瞄的武器)。
		# ★ 服务端仍带此字段,但客户端刻意**不消费**(用户裁定 2026-09-11:预瞄线只有使用者本人可见;
		#   见 player_replica._previewing 的注释)—— 留着是给日后换成音效/轮廓等提示形式的接点。
		var previewing := false
		if p.weapons != null and p.weapons.current_weapon() != null:
			previewing = p.weapons.current_weapon().is_previewing()
		state["players"][str(role)] = {
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
			# Beta 时间玩法:该 role 当前是否加速(客户端副本的视效用;倍率由规则同源推出)
			"haste": p.pvp_haste_mult > 1.0,
			# 回溯:该 role 是否在回溯(自身底片色 + 轨迹残像用)+ 轨迹点(每 3 帧一个)
			"rewind": bool(_rw_on.get(int(role), false)),
			"trail": (_rw_trail.get(int(role), []) as Array).duplicate(),
		}
	# ★ 一次 rpc():ENet 层单次序列化 + 广播。逐 rpc_id 循环会把 O(N²) 加回来(那正是拆包要治的)。
	# ★★ 判据必须是「**表里每一个** peer 都能收包」(`NetBus.all_peers_sendable`),不能是老的
	#    `not get_peers().is_empty()`:广播在 ENet 层是**逐 peer** 发包,表里只要还剩一个
	#    处于"队列已拆、API 还没忘掉"窗口的 peer(典型:本帧刚被 `disconnect_peer` 踢掉的那个),
	#    这一发就会打 `Unable to send packet on channel 0/1, max channels: 0`。
	#    2026-09-21 实测(未改之前,reconnect_probe 的 worker 日志):每拒绝一次错的 reclaim,
	#    有一帧**同时**报 channel 0 与 channel 1,backtrace 两行都指向本行 —— 老判据拦不住它
	#    (`get_peers()` 滞后,正是 `NetBus.is_peer_live` 那段注释里说过的那件事)。
	#    代价只有"那一帧不发世界包":它本来就是 unreliable,少一帧无后果。
	if NetBus.all_peers_sendable():
		var wbytes := NetCodec.encode_world(state)   # 全量:每包自包含,乱序/丢包只损失那一帧
		NetBus.rpc("snapshot_world", wbytes)
		_tx_world += 1
		_tx_world_bytes += wbytes.size()
	else:
		# 整发跳过:一个 peer 处于拆链路窗口 ⇒ 这一帧**所有端**都没世界包。
		_tx_world_skip += 1


func send_own_snapshots() -> void:
	var roles: Array = peer_by_role.keys()
	for role in roles:
		if not NetBus.is_peer_live(peer_by_role[role]):
			continue
		var p: Node2D = players.get(role)
		if p == null:
			continue
		var c2 := {}
		if p.has_method("capture_state"):
			c2 = p.capture_state()
		# ★ `q` = 本 role 此刻**已到达但还没被消费**的输入**记录**数(不是包数:30Hz 一包 2 条记录;判据用,见
		#   docs/eng/netcode-snapshots.md §6:客户端拿它把"在路上"与"堆在服务器"分开)。
		var q: Array = _pending_input.get(role, [])
		var obytes := NetCodec.encode_own({
			"ack_seq": _ack_seq.get(role, 0), "q": q.size(), "c2": c2, "tick": _srv_tick,
		}, true)
		NetBus.rpc_id(peer_by_role[role], "snapshot_own", obytes)
		_tx_own[role] = int(_tx_own.get(role, 0)) + 1
		_tx_own_bytes[role] = int(_tx_own_bytes.get(role, 0)) + obytes.size()
	_snapshot_tx_diag()


# 武器块是"整体存在/整体缺席"(capture_state 里 w != null 才加那 8 个字段)⇒ 存在性一变就必须发 FULL:
# 差分包只携带"变化字段",表达不了"这些字段从今往后没了",客户端会留下陈旧的武器块。
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
	NetDiag.log_event("snapshot_tx", {
		"interval_ms": now - _tx_at,
		"world_msgs": _tx_world,
		"world_bytes": _tx_world_bytes,
		"world_skipped": _tx_world_skip,
		"own": own,
		"peers": multiplayer.get_peers().size(),
	})
	_tx_at = now
	_tx_world = 0
	_tx_world_skip = 0
	_tx_world_bytes = 0
	_tx_own.clear()
	_tx_own_bytes.clear()

# 子弹裁决:遍历 bullet 组。新子弹广播给非射手客户端;命中判定 = 子弹上一位置→当前位置线段 vs 玩家受击面(core/sim/hit_shape.gd)。
