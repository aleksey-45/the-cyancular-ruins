class_name PredictionFrame
extends RefCounted

# 世界 tick 结束时的检查点。发布后只读，恢复覆盖全部角色与玩法预测域。

var tick := 0
var player: Array = []
var cursor: Array = []
var remote: Dictionary = {}
var layers: Dictionary = {}
var time: Dictionary = {}
var projectiles: ProjectileSnapshot
var terrain_generation := 0
var rewinding := false
var respawn_tick := 0
