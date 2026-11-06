class_name ClientState
extends RefCounted


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
