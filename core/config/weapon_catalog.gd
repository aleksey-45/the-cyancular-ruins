class_name WeaponCatalog
extends Resource

# 武器目录：唯一来源。每个 WeaponDef 一个 .tres，目录只负责顺序与完整性。
@export var weapons: Array[WeaponDef] = []
