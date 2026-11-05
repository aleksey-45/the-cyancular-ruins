class_name MatchPorts
extends RefCounted

# C 方案(S0.5):系统 → 宿主/网络 的唯一通道。全部是 Callable,由 MatchHost 绑定。
# 约定:系统不持有宿主引用;需要宿主行为(网络效果 / 模式钩子)时只许走这里。

var net_rpc_role: Callable          # (role: int, method: String, args: Array, via_ext: bool) → void
var net_rpc_role_all: Callable      # (method: String, args: Array, except_role: int, live_only: bool, via_ext: bool) → void
var net_broadcast: Callable         # (method: String, args: Array) → void
var net_peers_sendable: Callable    # () → bool
var net_peer_count: Callable        # () → int
var send_round_state: Callable      # (data: Dictionary) → void

var on_bullet_hit: Callable         # (bullet, victim, victim_role) → void
var broadcast_round_state: Callable # () → void
var match_winner: Callable          # () → int
var spawn_cell: Callable            # (role: int) → Vector2i
var respawn_player: Callable        # (role: int) → void
var down_killer_of: Callable        # (role: int) → int
var award_down: Callable            # (victim_role: int, killer_role: int) → void
var finish_match: Callable          # () → void
var start_next_round: Callable      # () → void
var reset_time_rewind_state: Callable  # () → void


func is_ready() -> bool:
	var required := [net_rpc_role, net_rpc_role_all, net_broadcast, net_peers_sendable, net_peer_count,
			send_round_state, on_bullet_hit, broadcast_round_state, match_winner, spawn_cell,
			respawn_player, down_killer_of, award_down, finish_match, start_next_round,
			reset_time_rewind_state]
	for c in required:
		if not (c as Callable).is_valid():
			return false
	return true
