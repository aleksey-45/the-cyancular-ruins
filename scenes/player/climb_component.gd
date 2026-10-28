class_name ClimbComponent
extends Node

# 场景兼容接口；攀爬判定和状态更新由 NativeActorBody 的共享运动核执行。
var _latched: bool:
	get: return (get_parent() as NativeActorBody).climb_latched
	set(value): (get_parent() as NativeActorBody).climb_latched = value

func is_latched() -> bool:
	return _latched
