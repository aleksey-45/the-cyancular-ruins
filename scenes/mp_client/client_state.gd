class_name ClientState
extends RefCounted

# PvP 对局客户端的共享状态(C 方案 S5,对齐服务端 MatchState):纯数据;宿主持有(state),六件套只读。

var _local: Node2D = null
var _world: Node = null
var _level0: Node = null
var _replicas: Dictionary = {}
var _names: Dictionary = {}
var _last_snap_tick := 0
var _match_ended := false
var _menu_open := false
var _round_locked := false
var _rollback = null
var _time_haste_mult := 3.0
