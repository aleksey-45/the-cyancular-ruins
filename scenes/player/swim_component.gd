class_name SwimComponent
extends Node

# 场景兼容接口；水体运动由 NativeActorBody 的共享运动核执行。
var in_water: bool:
	get: return (get_parent() as NativeActorBody).in_water
	set(value): (get_parent() as NativeActorBody).in_water = value
