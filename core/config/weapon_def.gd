class_name WeaponDef
extends Resource

# 单个武器的完整定义(数值 + 弹道引用)。字段保持 Dictionary:
# 可选键(arc_time/charge_*/bounces/guide_length/draw_length/…)不强行补默认,
# 避免改变 definition().has() 的语义。运行时由 WeaponRegistry 转成只读 Dictionary。
@export var weapon_id: int = 0
@export var data: Dictionary = {}
