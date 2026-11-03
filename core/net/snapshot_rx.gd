class_name SnapshotRx
extends RefCounted
# 下行接收侧的纯逻辑(S-03):解码 → tick 去重 → 坏包只警告一次 → 丢包/诊断计数。

const SNAP_GAP_MS := 150   # 相邻世界包到达间隔超过它 ⇒ NetBus 记一条 snap_gap(--diag)

var _last_world_tick := -1
var _last_own_tick := -1
var _snap_warned := false
var _input_warned := false

# ── 下行丢包估计(tick 缺口;口径 = NetMetrics.snapshot_loss)──
var _snap_step := 1      # 学到的"无丢包时相邻快照的 tick 步长"(只在没记丢包的那一步学)
var _own_step := 1
var _rx_world := 0       # 累计收世界包数
var _rx_world_lost := 0
var _rx_world_win := 0   # 本 1Hz 汇总窗口
var _rx_world_lost_win := 0
var _rx_own := 0
var _rx_own_lost := 0
var _rx_own_win := 0
var _rx_own_lost_win := 0

# ── 1Hz 诊断窗口(--diag 默认关;计数始终在跑)──
var _diag_rx := 0
var _diag_rx_at := 0
var _diag_prev_us := 0


## 世界包:成功返回 {tick, players, lost, gap_ms}(gap_ms = 与上一世界包的到达间隔;0 = 首个包)。
## `lost` / 窗口计数本函数已记账,take_diag() 只负责取读数。
func accept_world(payload: PackedByteArray, now_us: int) -> Dictionary:
	var pkt := NetCodec.decode_world(payload)
	if pkt.is_empty():
		return {}
	var tick := int(pkt.get("tick", 0))
	if tick <= _last_world_tick:
		return {}   # 乱序/重复旧包:丢弃,不动任何计数(迟到包不算丢、也不更新基线)
	# 丢包估计先于基线更新:用**上一包学到的**步长算缺口,算完才允许学新步长(顺序反了会把缺口学成步长 ⇒ 永远 0 丢包)。
	var lost := NetMetrics.snapshot_loss(_last_world_tick, tick, _snap_step)
	if lost == 0:
		var d := tick - _last_world_tick
		if d > 0 and d <= 8:
			_snap_step = d
	_last_world_tick = tick
	_rx_world += 1
	_rx_world_lost += lost
	_rx_world_win += 1
	_rx_world_lost_win += lost
	var gap_ms := 0
	if _diag_prev_us > 0:
		gap_ms = int((now_us - _diag_prev_us) / 1000)
	_diag_prev_us = now_us
	_diag_rx += 1
	if _diag_rx_at == 0:
		_diag_rx_at = now_us
	return {"tick": tick, "players": pkt.get("players", {}), "lost": lost, "gap_ms": gap_ms}


## 本人包:成功返回 {ack_seq, q, c2, lost}(下游 emit 形状与全量时代逐字一致,rollback 锚点/软同步零改动)。
func accept_own(payload: PackedByteArray) -> Dictionary:
	var pkt := NetCodec.decode_own(payload)
	if pkt.is_empty():
		return {}
	var tick := int(pkt.get("tick", 0))
	if tick <= _last_own_tick:
		return {}   # 旧包
	var lost := NetMetrics.snapshot_loss(_last_own_tick, tick, _own_step)
	if lost == 0:
		var d := tick - _last_own_tick
		if d > 0 and d <= 8:
			_own_step = d
	_last_own_tick = tick
	_rx_own += 1
	_rx_own_lost += lost
	_rx_own_win += 1
	_rx_own_lost_win += lost
	return {"ack_seq": int(pkt.get("ack_seq", 0)), "q": int(pkt.get("q", 0)),
			"c2": pkt.get("c2", {}), "lost": lost}


## 输入包:成功返回解码后的记录字典(形状 = NetCodec.decode_input),失败返回 {}。
func accept_input(payload: PackedByteArray) -> Dictionary:
	return NetCodec.decode_input(payload)


## 坏快照(世界/本人共用一面旗:两端版本不一致是**一次性条件**)。首次返回 true ⇒ NetBus 打一条 push_error。
func warn_snapshot_once() -> bool:
	if _snap_warned:
		return false
	_snap_warned = true
	return true


## 坏输入包同理(输入包 30Hz 不间断,否则每包一条)。
func warn_input_once() -> bool:
	if _input_warned:
		return false
	_input_warned = true
	return true


## 重连/换局:清 tick 去重锚点与步长(不清会把新纪元的包全当旧包丢掉,或把纪元跳变记成假丢包)。
## 累计计数(_rx_*_lost)不清 —— 那是整场对局的账,`--netstat` 看的就是它。
func reset() -> void:
	_last_world_tick = -1
	_last_own_tick = -1
	_snap_step = 1
	_own_step = 1


## 1Hz 窗口读数:未到 1s 返回 {}(--diag 口径:与服务器 snapshot_tx 的 world_msgs 按同一秒对账)。
func take_diag(now_us: int) -> Dictionary:
	if _diag_rx_at == 0 or now_us - _diag_rx_at < 1000000:
		return {}
	var out := {
		"interval_ms": int((now_us - _diag_rx_at) / 1000),
		"world_msgs": _rx_world_win,
		"world_lost": _rx_world_lost_win,
		"world_loss_pct": NetMetrics.loss_pct(_rx_world_win, _rx_world_lost_win),
		"own_msgs": _rx_own_win,
		"own_lost": _rx_own_lost_win,
		"own_loss_pct": NetMetrics.loss_pct(_rx_own_win, _rx_own_lost_win),
		"step": _snap_step,
	}
	_diag_rx_at = now_us
	_diag_rx = 0
	_rx_world_win = 0
	_rx_world_lost_win = 0
	_rx_own_win = 0
	_rx_own_lost_win = 0
	return out


## `--netstat` 用的累计读数(形状与旧 NetBus.snap_stats() 逐字一致)。
func stats() -> Dictionary:
	return {
		"world_rx": _rx_world, "world_lost": _rx_world_lost,
		"own_rx": _rx_own, "own_lost": _rx_own_lost, "step": _snap_step,
	}


func world_tick() -> int:
	return _last_world_tick


