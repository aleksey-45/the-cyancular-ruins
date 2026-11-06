class_name MatchPorts
extends RefCounted


var net_rpc_role: Callable
var net_rpc_role_all: Callable
var net_broadcast: Callable
var net_peers_sendable: Callable
var net_peer_count: Callable
var scene_bullets: Callable
var scene_add_child: Callable
var scene_rebuild_chunk: Callable
var send_round_state: Callable

var on_bullet_hit: Callable
var broadcast_round_state: Callable
var match_winner: Callable
var spawn_cell: Callable
var respawn_player: Callable
var down_killer_of: Callable
var award_down: Callable
var finish_match: Callable
var start_next_round: Callable
var reset_time_rewind_state: Callable


func is_ready() -> bool:
	var required := [net_rpc_role, net_rpc_role_all, net_broadcast, net_peers_sendable, net_peer_count,
			scene_bullets, scene_add_child, scene_rebuild_chunk, send_round_state, on_bullet_hit,
			broadcast_round_state, match_winner, spawn_cell, respawn_player, down_killer_of,
			award_down, finish_match, start_next_round, reset_time_rewind_state]
	for c in required:
		if not (c as Callable).is_valid():
			return false
	return true
