class_name WeaponDef
extends Resource

enum Trigger { PRESS, AUTO, RELEASE, CHARGE_RELEASE }
enum Penalty { NONE, COOLDOWN, AIM_OR_COOLDOWN }
enum Attack { PROJECTILE, BEAM, MELEE }

@export var weapon_id: int
@export var trigger: Trigger = Trigger.PRESS
@export var penalty: Penalty = Penalty.NONE
@export var attack: Attack = Attack.PROJECTILE
@export var projectile: ProjectileDef
@export var data: Dictionary = {}
