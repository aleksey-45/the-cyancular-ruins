class_name MatchSnapshot
extends MatchGround

# 30Hz 快照广播域(阶段 5.6 拆自 server/match_host.gd)。★ tick 域仍是 60Hz 物理 tick(每包 +SNAPSHOT_STRIDE),发包 30Hz。

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

# ── 增量/差分发送状态(2026-10-26 P1.5,PROTO_VERSION 6)──
# 世界包:上次已发状态 = 下一包 DELTA 的基准;滚动关键帧游标;"要全量"请求 → 下一包 FULL。
var _world_state: Dictionary = {}     # {"tick": int, "players": {...}}
var _world_kf_cursor := 0             # 滚动关键帧游标(每包推进 k 人)
var _need_full_world := false
# 本人包:role -> 上次已发 {"tick", "c2"}(DELTA 基准);role -> true = 下一发 FULL。
var _own_sent: Dictionary = {}
var _need_full_own: Dictionary = {}
var _sent_round_state := -1           # 回合态变化 ⇒ 清基准 + 强制 FULL(换局/复活/重连锚点重置)


func _broadcast_snapshot() -> void:
	# tick 是「60Hz 物理 tick 时间轴」上的时间戳,不是包序号:30Hz 发包时每包跨 2 tick(客户端 playout/历史环按它插值)。
	# ★ S1(2026-10-24):本函数**只发世界包**;本人包(ack+c2)由 MatchHost 在玩家步进之后 call_deferred 调,不再等 30Hz 广播。
	# ★ 时间域对齐:直接取 _srv_tick(广播相位仍每 2 tick,数值序列不变)⇒ 客户端输入包的 st 与服务器 tick 同刻度。
	# ★ P1.5:世界包可能是 DELTA(基准 = _world_state);每人每 ≤60 tick 被滚动关键帧绝对刷新一次;FULL 只由请求/换局/名单变化触发。
	_snap_tick = _srv_tick
	if _round_state != _sent_round_state:
		_sent_round_state = _round_state
		_world_state = {}
		_own_sent.clear()
		_need_full_world = true
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
	var full := _need_full_world or _world_state.is_empty() or _roster_changed(state)
	var keyframes: Array = [] if full else _next_keyframes(_state_roles(state))
	if NetBus.all_peers_sendable():
		var wbytes := NetCodec.encode_world(state, full, _world_state, keyframes)
		NetBus.rpc("snapshot_world", wbytes)
		_tx_world += 1
		_tx_world_bytes += wbytes.size()
		# ★ 只有真发出去才推进基准:没发出去却更新 _world_state ⇒ 下一包 DELTA 的 base_tick 指向客户端从未收到的包。
		_world_state = state
		_need_full_world = false
	else:
		# 整发跳过:一个 peer 处于拆链路窗口 ⇒ 这一帧**所有端**都没世界包。客户端侧的 snap_gap
		# 分不出这一种与"发了没收到";这里的计数就是用来把它分出来的。基准不推进(下一包仍 FULL/DELTA 自洽)。
		_tx_world_skip += 1


func _state_roles(state: Dictionary) -> Array:
	var roles: Array = []
	for k in (state.get("players", {}) as Dictionary):
		roles.append(int(k))
	roles.sort()
	return roles


func _roster_changed(state: Dictionary) -> bool:
	var cur := _state_roles(state)
	var prev: Array = []
	for k in (_world_state.get("players", {}) as Dictionary):
		prev.append(int(k))
	prev.sort()
	if cur.size() != prev.size():
		return true
	for i in cur.size():
		if cur[i] != prev[i]:
			return true
	return false


# 滚动关键帧:本包把 k 个玩家整份刷新(k = world_keyframe_quota;N=16 时 k=1,每人在 32 tick 内被刷一次)。
# ★ 与"整包 FULL 每 60 tick"不同:这是**逐玩家、错峰**的绝对刷新,包体积平滑、不会在 60 tick 边界出现尖峰。
func _next_keyframes(roles: Array) -> Array:
	var out: Array = []
	if roles.is_empty():
		return out
	var k := NetCodec.world_keyframe_quota(roles.size(), SNAPSHOT_STRIDE)
	for j in k:
		out.append(roles[_world_kf_cursor % roles.size()])
		_world_kf_cursor = (_world_kf_cursor + 1) % roles.size()
	return out


# ── 本人包(2026-10-24 S1):**只能在玩家步进之后调用** ──
# 各自的 ack + 权威整态 c2 —— 只有本人需要(客户端 rollback 拿它锚定/重放)。逐 peer 定向(体积小,不构成 O(N²))。
# ★ 调用时机由 MatchHost 的 `_flush_own_snapshots()`(call_deferred)保证:此刻 Player 子节点已步进完 ⇒
#   c2 是"本 tick 消费的输入已经生效"的权威态,`_ack_seq` 也是本 tick 刚消费的 seq ⇒ 状态与 ack 同拍且都是最新。
#   ★ 别把它挪回 `_broadcast_snapshot()`:那会退回"状态/ack 都落后一拍 + 等下一次广播"的旧时序(S1 就是为了消掉它)。
# ★ 仍判 live peer:避免给正在断开的客户端发 —— 这是全项目**最频繁**的一处定向发送(30Hz × 每个 role),
#   所以判据必须不滞后:用 `NetBus.is_peer_live`(读 ENet peer 自己的 state),不是 `get_peers()`。
#   (本条走 unreliable → 通道 1,报出来会是 "channel **1**" 那一版;用户看到的那条 "channel 0" 只可能来自
#   **reliable** 的定向包,见 NetBus.is_peer_live 的注释。)
func send_own_snapshots() -> void:
	var roles: Array = peer_by_role.keys()
	roles.sort()
	var n := roles.size()
	var idx := 0
	for role in roles:
		idx += 1
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
		var prev: Dictionary = _own_sent.get(int(role), {})
		# 发 FULL 的四种情形:请求位 / 首次 / 武器块存在性变化(差分表达不了"字段消失")/ 本 role 的 60 tick 周期到点(错峰)。
		var want_full: bool = _need_full_own.has(int(role)) or prev.is_empty() \
				or _weapon_block_changed(prev.get("c2", {}), c2) \
				or _srv_tick % NetCodec.OWN_FULL_PERIOD == NetCodec.own_full_phase(idx - 1, n, SNAPSHOT_STRIDE)
		var obytes := NetCodec.encode_own({
			"ack_seq": _ack_seq.get(role, 0), "q": q.size(), "c2": c2, "tick": _srv_tick,
		}, want_full, prev)
		NetBus.rpc_id(peer_by_role[role], "snapshot_own", obytes)
		_own_sent[int(role)] = {"tick": _srv_tick, "c2": c2}
		_need_full_own.erase(int(role))
		_tx_own[role] = int(_tx_own.get(role, 0)) + 1
		_tx_own_bytes[role] = int(_tx_own_bytes.get(role, 0)) + obytes.size()
	_snapshot_tx_diag()


# 武器块是"整体存在/整体缺席"(capture_state 里 w != null 才加那 8 个字段)⇒ 存在性一变就必须发 FULL:
# 差分包只携带"变化字段",表达不了"这些字段从今往后没了",客户端会留下陈旧的武器块。
func _weapon_block_changed(prev_c2: Dictionary, cur_c2: Dictionary) -> bool:
	return prev_c2.has("fire_cd") != cur_c2.has("fire_cd")


# 1Hz 汇总一次"发给谁多少"(--diag)。★ 只统计**尝试发送**(rpc/rpc_id 都过判活闸),
# 所以 `own[role].msgs` 恒等于"服务器认为该 role 连通时的发送次数"。
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
