class_name ClientPorts
extends RefCounted

# PvP 对局客户端的端口(C 方案 S5,对齐服务端 MatchPorts):Node/场景/网络等效果一律走 Callable,组件不持宿主引用。

var add_child: Callable
var get_tree: Callable
var multiplayer: Callable
var apply_tint: Callable
var time_fx_rewind_off: Callable
var all_replicas: Callable
var build_result_payload: Callable
var leave_scene: Callable
var set_status: Callable
var pull_resync: Callable
