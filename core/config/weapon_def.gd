class_name WeaponDef
extends Resource

# 单个武器的完整定义(数值 + 弹道引用)。字段保持 Dictionary,原样对应
# WeaponRegistry.definition() 的形状:可选键(arc_time/charge_*/bounces/…)不强行补默认,
# 避免"存在性"语义被改写。运行时由 WeaponRegistry 转成只读 Dictionary。
@export var weapon_id: int = 0
@export var data: Dictionary = {}
