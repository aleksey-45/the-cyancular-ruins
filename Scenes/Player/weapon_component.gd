class_name WeaponComponent
extends Node

# 武器子系统:注册表/换枪/移动惩罚/后坐。枪实例挂在 body.weapon_slot 下。
# 由根 player.gd 驱动(equip 在 _ready/换枪输入,movement_multiplier 每物理帧,
# apply_recoil 由 weapon_base 经根转发)。

const WEAPONS: Dictionary = {
	"1": "res://Scenes/Weapons/pistol_test.tscn",
	"2": "res://Scenes/Weapons/rifle_test.tscn",
	"3": "res://Scenes/Weapons/m82a1.tscn",
	"4": "res://Scenes/Weapons/s686.tscn",
	"5": "res://Scenes/Weapons/grenade_launcher.tscn",
}

var _weapon: WeaponBase = null
var _current_slot: int = 1
var body: CharacterBody2D

# 启用的武器槽位(1-5)。单机由 Level0 按 RunOptions 设置;PvP 由 pvp_client 按服务器
# 下发的 match_options 设置。数字键/滚轮切枪都会跳过禁用槽位。
var enabled_slots: Array = [1, 2, 3, 4, 5]

func _ready() -> void:
	body = get_parent() as CharacterBody2D

func set_enabled_slots(disabled: Array[int]) -> void:
	enabled_slots = [1, 2, 3, 4, 5].filter(func(s: int) -> bool: return not disabled.has(s))
	if enabled_slots.is_empty():
		enabled_slots = [1]   # 不允许全禁:至少留手枪
	# 当前拿着的枪被禁 → 切到第一个启用的
	if not is_slot_enabled(_current_slot):
		equip(default_slot())

func is_slot_enabled(slot: int) -> bool:
	return enabled_slots.has(slot)

# 默认槽位 = 最小的启用槽位(出生/复活用它,防止出生武器被禁后空手)。
func default_slot() -> String:
	return str(enabled_slots[0]) if enabled_slots.size() > 0 else "1"

# 滚轮切枪:沿 dir 方向循环到下一个启用槽位(禁用的直接跳过)。
func cycle_slot(dir: int) -> void:
	var order: Array = enabled_slots.duplicate()
	order.sort()
	if order.is_empty():
		return
	var idx := order.find(_current_slot)
	if idx < 0:
		idx = 0
	var next: int = order[(idx + dir + order.size() * 2) % order.size()]
	if next != _current_slot:
		equip(str(next))

func equip(slot: String) -> void:
	# 禁用槽位拒绝切换(提示音),防止数字键/网络包绕过
	if not is_slot_enabled(int(slot)):
		Sfx.play("deny")
		return
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
	Sfx.play("switch")

func current_weapon() -> WeaponBase:
	return _weapon

func current_slot_int() -> int:
	return _current_slot

func movement_multiplier() -> Vector2:
	if _weapon == null:
		return Vector2.ONE
	return _weapon.get_movement_multiplier()

func apply_recoil(push: float, is_squat: bool, is_latched: bool) -> void:
	if is_squat:
		return
	if is_latched:
		push *= 0.1  # 攀爬时后坐力降到 0.1(在梯/锁链上开火基本不后推)
	body.velocity.x -= body.facing_direction * push

func cancel_aim() -> void:
	if _weapon != null:
		_weapon.cancel_aim()
