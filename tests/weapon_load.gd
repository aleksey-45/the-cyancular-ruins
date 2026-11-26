extends RefCounted

# 单独预载手枪可检测武器资源与战斗模拟之间的循环依赖。
const PISTOL: WeaponDef = preload("res://data/weapons/weapon_01.tres")
