class_name SnapshotRx
extends RefCounted

const SNAP_GAP_MS := 150

var _last_world_tick := -1
var _last_own_tick := -1
var _snap_warned := false
var _input_warned := false

var _snap_step := 1
var _own_step := 1
var _rx_world := 0
var _rx_world_lost := 0
var _rx_world_win := 0
var _rx_world_lost_win := 0
var _rx_own := 0
var _rx_own_lost := 0
var _rx_own_win := 0
var _rx_own_lost_win := 0

var _diag_rx := 0
var _diag_rx_at := 0
var _diag_prev_us := 0


func accept_world(payload: PackedByteArray, now_us: int) -> Dictionary:
	var pkt := NetCodec.decode_world(payload)
	if pkt.is_empty():
		return {}
	var tick := int(pkt.get("tick", 0))
	if tick <= _last_world_tick:
		return {}
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


func accept_own(payload: PackedByteArray) -> Dictionary:
	var pkt := NetCodec.decode_own(payload)
	if pkt.is_empty():
		return {}
	var tick := int(pkt.get("tick", 0))
	if tick <= _last_own_tick:
		return {}
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


func accept_input(payload: PackedByteArray) -> Dictionary:
	return NetCodec.decode_input(payload)


func warn_snapshot_once() -> bool:
	if _snap_warned:
		return false
	_snap_warned = true
	return true


func warn_input_once() -> bool:
	if _input_warned:
		return false
	_input_warned = true
	return true


func reset() -> void:
	_last_world_tick = -1
	_last_own_tick = -1
	_snap_step = 1
	_own_step = 1


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


func stats() -> Dictionary:
	return {
		"world_rx": _rx_world, "world_lost": _rx_world_lost,
		"own_rx": _rx_own, "own_lost": _rx_own_lost, "step": _snap_step,
	}


func world_tick() -> int:
	return _last_world_tick


