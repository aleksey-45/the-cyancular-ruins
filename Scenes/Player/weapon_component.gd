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
	"6": "res://Scenes/Weapons/laser_gun.tscn",
	"7": "res://Scenes/Weapons/minigun.tscn",
	"8": "res://Scenes/Weapons/prop_knockback.tscn",
	"9": "res://Scenes/Weapons/prop_attraction.tscn",
	"10": "res://Scenes/Weapons/prop_smoke.tscn",
}

# 武器显示名(菜单选择栏 / HUD 左下角共用,单一来源)
const DISPLAY_NAMES: Dictionary = {1: "手枪", 2: "步枪", 3: "重狙 M82A1", 4: "霰弹 S686", 5: "榴弹发射器", 6: "激光枪", 7: "加特林",
	8: "击退炮", 9: "吸力炮", 10: "烟雾弹"}

# 道具槽位(T 键道具模式专用;不在 enabled_slots 里,普通切枪/数字键不会误选):
# 8=击退炮 9=吸力炮 10=烟雾弹。道具不受「禁武器」影响;每命携带数=各道具 mag_size。
const PROP_SLOTS: Array = [8, 9, 10]

signal weapon_changed(slot: int)   # equip 成功后发射(菜单图标/HUD 武器显示跟随)

var _weapon: WeaponBase = null
var _current_slot: int = 1
var _mag_state: Dictionary = {}   # 换弹玩法:各槽位残弹记忆(切枪不回满弹)
var body: CharacterBody2D

# 纯白像素剪影缓存(slot → Texture2D):从武器场景的 Sprite2D 图集切片,
# 全像素刷白保留 alpha,3× 最近邻放大(与瓦片/8bit 音效同风格,零美术素材)。
static var _silhouette_cache: Dictionary = {}

static func silhouette(slot: int) -> Texture2D:
	if _silhouette_cache.has(slot):
		return _silhouette_cache[slot]
	var tex: Texture2D = null
	var scene: PackedScene = load(WEAPONS.get(str(slot), "")) if WEAPONS.has(str(slot)) else null
	if scene != null:
		var inst := scene.instantiate()
		var sprites := inst.find_children("*", "Sprite2D", true, false)
		if not sprites.is_empty():
			var spr: Sprite2D = sprites[0]
			if spr.region_enabled and spr.texture != null:
				var atlas := spr.texture.get_image()
				if atlas != null:
					if atlas.is_compressed():
						atlas.decompress()
					var r: Rect2 = spr.region_rect
					var img := atlas.get_region(Rect2i(r.position, r.size))
					for y in img.get_height():
						for x in img.get_width():
							if img.get_pixel(x, y).a > 0.05:
								img.set_pixel(x, y, Color.WHITE)
					img.resize(img.get_width() * 3, img.get_height() * 3, Image.INTERPOLATE_NEAREST)
					tex = ImageTexture.create_from_image(img)
		inst.free()
	_silhouette_cache[slot] = tex
	return tex

# 武器选择格(共用):勾选框 + 固定尺寸白剪影 + 名称。
# 剪影原始宽度可达 252px,直接挂 CheckButton.icon 会把横排面板撑出屏幕(实测),
# 这里用固定尺寸 TextureRect 约束。CheckButton 引用存 meta("cb") 供调用方读取状态。
static func make_weapon_check(slot: int, checked: bool, font_size: int, on_toggle: Callable) -> HBoxContainer:
	var cell := HBoxContainer.new()
	cell.add_theme_constant_override("separation", 6)
	var cb := CheckButton.new()
	cb.button_pressed = checked
	cb.toggled.connect(func(on: bool) -> void: on_toggle.call(on))
	cell.set_meta("cb", cb)   # 挂 cell 上(调用方统一 cell.get_meta("cb") 取勾选框)
	cell.add_child(cb)
	var icon := TextureRect.new()
	icon.texture = silhouette(slot)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.custom_minimum_size = Vector2(96, 30)
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	cell.add_child(icon)
	var l := Label.new()
	l.text = "%d %s" % [slot, DISPLAY_NAMES[slot]]
	l.add_theme_font_size_override("font_size", font_size)
	cell.add_child(l)
	return cell

# 启用的武器槽位(1-5)。单机由 Level0 按 RunOptions 设置;PvP 由 pvp_client 按服务器
# 下发的 match_options 设置。数字键/滚轮切枪都会跳过禁用槽位。
var enabled_slots: Array = [1, 2, 3, 4, 5, 6, 7]

func _ready() -> void:
	body = get_parent() as CharacterBody2D

func set_enabled_slots(disabled: Array[int]) -> void:
	enabled_slots = [1, 2, 3, 4, 5, 6, 7].filter(func(s: int) -> bool: return not disabled.has(s))
	if enabled_slots.is_empty():
		enabled_slots = [1]   # 不允许全禁:至少留手枪
	# 当前拿着的枪被禁 → 切到第一个启用的
	if not is_slot_enabled(_current_slot) and not is_prop_slot(_current_slot):
		equip(default_slot())

func is_slot_enabled(slot: int) -> bool:
	return enabled_slots.has(slot)

# 默认槽位 = 最小的启用槽位(出生/复活用它,防止出生武器被禁后空手)。
func default_slot() -> String:
	return str(enabled_slots[0]) if enabled_slots.size() > 0 else "1"

# 滚轮切枪:沿 dir 方向循环到下一个启用槽位(禁用的直接跳过)。
func cycle_slot(dir: int) -> void:
	equip(str(_peek_cycle(dir)))

# 计算滚轮方向的目标槽位(不切换)
func _peek_cycle(dir: int) -> int:
	var order: Array = enabled_slots.duplicate()
	order.sort()
	if order.is_empty():
		return _current_slot
	var idx := order.find(_current_slot)
	if idx < 0:
		idx = 0
	return order[(idx + dir + order.size() * 2) % order.size()]

# ── PvP 滚轮切枪:本地立即切(即时反馈),目标槽位打包进输入包由服务器权威同步 ──
# (滚轮事件不在输入包协议里,只本地切会被快照的防脱同步切回旧槽位 →「只有音效」)
var _net_slot := 0   # 待发切枪槽位(>0 = 待发;打包后清零)

func request_net_cycle(dir: int) -> void:
	var next := _peek_cycle(dir)
	if next == _current_slot:
		return
	push_net_slot(next)
	equip(str(next))

func push_net_slot(slot: int) -> void:
	_net_slot = slot

func consume_net_slot() -> int:
	var v := _net_slot
	_net_slot = 0
	return v

func equip(slot: String) -> void:
	# 禁用槽位拒绝切换(提示音),防止数字键/网络包绕过
	if not is_slot_enabled(int(slot)) and not is_prop_slot(int(slot)):
		Sfx.play("deny")
		return
	# 切枪继承旧武器剩余冷却:后摇不能被切枪取消(queue_free 前先捕获)
	var inherit_cd := 0.0
	# 换弹玩法:记住旧枪残弹(防"切枪回满弹"漏洞),新枪按槽位恢复
	var old_slot := _current_slot
	if _weapon != null and is_instance_valid(_weapon):
		inherit_cd = _weapon.fire_cd_timer
		if _weapon.reload_active():
			_mag_state[old_slot] = _weapon.mag_ammo
		_weapon.queue_free()
	_current_slot = int(slot)
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
	if _weapon.reload_active() and _mag_state.has(_current_slot):
		# 武器 _ready(入树时)会把 mag_ammo 重置为满:恢复必须排在 deferred add 之后
		var restored_slot := _current_slot
		var restored_ammo := int(clampi(_mag_state[restored_slot], 0, _weapon.mag_size))
		_restore_mag.call_deferred(_weapon, restored_ammo)
	Sfx.play("switch")
	weapon_changed.emit(int(slot))

func _restore_mag(w: WeaponBase, ammo: int) -> void:
	if is_instance_valid(w):
		w.mag_ammo = ammo

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


# ── 道具模式(T 键开关):道具借道隐藏槽位 8/9/10,与武器槽位共用输入包同步 ──
# 进入 = 记住当前武器槽 → equip 道具槽(PvP 同时 push_net_slot,服务器权威跟随);
# 退出 = 回到进入前的武器槽。prop_mode 以"当前槽位是否道具槽"推导,天然与快照 wslot 一致。

var _pre_prop_slot := "1"

func is_prop_slot(slot: int) -> bool:
	return PROP_SLOTS.has(slot)

func is_prop_mode() -> bool:
	return is_prop_slot(_current_slot)

func owned_prop_slots() -> Array:
	return PROP_SLOTS.filter(func(s: int) -> bool: return WEAPONS.has(str(s)))

func enter_prop_mode() -> void:
	var owned := owned_prop_slots()
	if owned.is_empty() or is_prop_mode():
		return
	_pre_prop_slot = str(_current_slot)
	_equip_and_sync(int(owned[0]))

func exit_prop_mode() -> void:
	if not is_prop_mode():
		return
	var back := _pre_prop_slot
	if back.is_empty() or (not is_slot_enabled(int(back)) and is_prop_slot(int(back))):
		back = default_slot()
	_equip_and_sync(int(back))

## 道具模式内:滚轮循环切换道具
func cycle_prop(dir: int) -> void:
	var owned := owned_prop_slots()
	if owned.is_empty():
		return
	var idx := owned.find(_current_slot)
	if idx < 0:
		idx = 0
	else:
		idx = (idx + dir + owned.size() * 2) % owned.size()
	_equip_and_sync(int(owned[idx]))

## 道具模式内:数字 1/2/3 直选第 i 个道具
func select_prop_index(i: int) -> void:
	var owned := owned_prop_slots()
	if i < 0 or i >= owned.size():
		return
	_equip_and_sync(int(owned[i]))

func _equip_and_sync(slot: int) -> void:
	equip(str(slot))
	if Level0.pvp_mode:
		push_net_slot(slot)   # 服务器权威跟随(复用武器槽位同步通道)

## 复活回满所有道具/武器弹夹(击退炮"每次复活只能携带两枚"由此保证)
func refill_all() -> void:
	for c in get_children():
		if c is WeaponBase:
			(c as WeaponBase).mag_ammo = (c as WeaponBase).mag_size
