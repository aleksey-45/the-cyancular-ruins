class_name WeaponComponent
extends Node

# 武器子系统:注册表/换枪/移动惩罚/后坐。枪实例挂在 body.weapon_slot 下。
# 由根 player.gd 驱动(equip 在 _ready/换枪输入,movement_multiplier 每物理帧,
# apply_recoil 由 weapon_base 经根转发)。

const WEAPONS: Dictionary = {
	"1": "res://scenes/Weapons/pistol_test.tscn",
	"2": "res://scenes/Weapons/rifle_test.tscn",
	"3": "res://scenes/Weapons/m82a1.tscn",
	"4": "res://scenes/Weapons/s686.tscn",
	"5": "res://scenes/Weapons/grenade_launcher.tscn",
}

var _weapon: WeaponBase = null
var _current_slot: int = 1
var body: CharacterBody2D

func _ready() -> void:
	body = get_parent() as CharacterBody2D

func equip(slot: String) -> void:
	# 切枪继承旧武器剩余冷却:后摇不能被切枪取消(queue_free 前先捕获)
	var inherit_cd := 0.0
	_current_slot = int(slot)
	if _weapon != null:
		inherit_cd = _weapon.fire_cd_timer
		_weapon.queue_free()
	var scene: PackedScene = load(WEAPONS[slot])
	if scene == null:
		push_error("weapon scene not found: " + str(WEAPONS[slot]))
		return
	if body.weapon_slot == null:
		push_error("weapon_slot not assigned")
		return
	_weapon = scene.instantiate() as WeaponBase
	body.weapon_slot.call_deferred("add_child", _weapon)
	_weapon.equip(body, inherit_cd)

func current_weapon() -> WeaponBase:
	return _weapon

func current_slot_int() -> int:
	return _current_slot

func movement_multiplier() -> Vector2:
	if _weapon == null:
		return Vector2.ONE
	return _weapon.get_movement_multiplier()

# 武器帧逻辑(冷却/缓冲开火/预瞄/后坐)由根每物理帧显式驱动:
# 保证与 body 跑在同一个固定 tick 上(rollback 重放需要确定性),不再依赖 idle _process。
func tick(delta: float) -> void:
	if _weapon != null:
		_weapon.tick(delta)

func apply_recoil(push: float, is_squat: bool, is_latched: bool) -> void:
	if is_squat:
		return
	if is_latched:
		push *= 0.1  # 攀爬时后坐力降到 0.1(在梯/锁链上开火基本不后推)
	body.velocity.x -= body.facing_direction * push

func cancel_aim() -> void:
	if _weapon != null:
		_weapon.cancel_aim()
