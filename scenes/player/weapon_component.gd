class_name WeaponComponent
extends Node

# 武器子系统:注册表 / 背包 / 换枪 / 移动惩罚 / 后坐。枪实例挂在 body.weapon_slot 下。
# 由根 player.gd 驱动(equip 在 _ready/换枪输入,movement_multiplier 每物理帧,
# apply_recoil 由 weapon_base 经根转发)。
#
# ★ 2026-09-15 起是**背包模型**:玩家有 8 格容量预算(轻2/中3/重4)与 4 把上限
#   (两条独立闸门,见 WeaponInventory)。此前是"按类型 id 1-6 直接切枪、无条件持有全部"。
#
# ★ `_current_slot` 刻意**仍是武器类型 id**(1-6),不是背包位置:快照的 weapon 字段
#   (match_snapshot)、capture_state 的 wslot、PlayerReplica._swap_weapon 全按类型 id 走
#   —— 协议与副本因此零改动。背包位置只用于本地按键/滚轮。

const WEAPONS: Dictionary = {
	"1": "res://scenes/weapons/pistol_test.tscn",
	"2": "res://scenes/weapons/rifle_test.tscn",
	"3": "res://scenes/weapons/m82a1.tscn",
	"4": "res://scenes/weapons/s686.tscn",
	"5": "res://scenes/weapons/grenade_launcher.tscn",
	"6": "res://scenes/weapons/laser_gun.tscn",
}

# 武器显示名(菜单选择栏 / HUD 左下角共用,单一来源)
const DISPLAY_NAMES: Dictionary = {1: "手枪", 2: "步枪", 3: "重狙 M82A1", 4: "霰弹 S686", 5: "榴弹发射器", 6: "激光枪"}

# 武器重量档(轻/中/重),决定占几格容量(见 WeaponInventory.SLOT_COST:轻2/中3/重4)。
# ★ 与各 .tscn 的 `tier =` export **刻意重复** —— 这份表让"这枪多重"不必实例化武器场景
#   就能问(实例化会连带 preload bullet.tscn)。漂移由 enemy_logic_smoke 的
#   `_phase_weapon_registry` 逐条钉住(键集 / tscn export / 枚举数值三样都比)。
# ★ 加新武器时**这里也要加一行** —— 漏了的表现是**容量算错**(轻武器被当成重武器,
#   8 格只能带两把),而且完全不报错,是三条注册表里最难发现的一条。
const TIERS: Dictionary = {
	1: WeaponBase.Tier.LIGHT,    # 手枪
	2: WeaponBase.Tier.MEDIUM,   # 步枪
	3: WeaponBase.Tier.HEAVY,    # 重狙 M82A1
	4: WeaponBase.Tier.LIGHT,    # 霰弹 S686
	5: WeaponBase.Tier.HEAVY,    # 榴弹发射器
	6: WeaponBase.Tier.MEDIUM,   # 激光枪
}

signal weapon_changed(slot: int)    # equip 成功后发射(菜单图标/HUD 武器显示跟随);0 = 空手
signal inventory_changed()          # 背包内容变化(格子 UI 跟随)

# 当前手持的**类型 id**(1-6);0 = 空手(背包为空)。
var _current_slot: int = 0
var _current_index: int = -1        # 在 inventory.held 里的下标;-1 = 空手
var _weapon: WeaponBase = null
var inventory: WeaponInventory
var body: CharacterBody2D

# 启用的武器槽位(1-6)。单机由 Level0 按 RunOptions 设置;PvP 由客户端按服务器
# 下发的 match_options 设置。数字键/滚轮切枪都会跳过禁用槽位。
var enabled_slots: Array = [1, 2, 3, 4, 5, 6]

# ★ 武器**图标与选择格**(silhouette / make_weapon_check)不在这里 —— 它们是纯 UI,
#   2026-09-15 阶段 4.1 搬去了 `ui/weapon_icons.gd`(WeaponIcons)。
#   本文件只留武器子系统本身:注册表 / 背包 / 换枪 / 移动惩罚 / 后坐。


func _init() -> void:
	# 在 _init 而不是 _ready 建:探针会 new() 出组件直接调方法,不一定入树。
	inventory = WeaponInventory.new(TIERS)


func _ready() -> void:
	body = get_parent() as CharacterBody2D


func set_enabled_slots(disabled: Array[int]) -> void:
	enabled_slots = [1, 2, 3, 4, 5, 6].filter(func(s: int) -> bool: return not disabled.has(s))
	if enabled_slots.is_empty():
		enabled_slots = [1]   # 不允许全禁:至少留手枪
	# 当前拿着的枪被禁 → 切到背包里第一把没被禁的;没有就空手
	if _current_slot > 0 and not is_slot_enabled(_current_slot):
		var fallback := _first_enabled_index()
		if fallback >= 0:
			_equip_index(fallback)
		else:
			_unequip()


func is_slot_enabled(slot: int) -> bool:
	return enabled_slots.has(slot)


func _first_enabled_index() -> int:
	for i in inventory.held.size():
		if is_slot_enabled(int(inventory.held[i]["type"])):
			return i
	return -1


# 默认槽位 = 最小的启用槽位(出生/复活用它,防止出生武器被禁后空手)。
func default_slot() -> String:
	return str(enabled_slots[0]) if enabled_slots.size() > 0 else "1"


# ── 初始背包 ──
# 由调用方决定:单机 = 空表(开局空手,枪散落在地图上);联机 = 一条随机武器。
# ★ 必须排在 _ready(Player 会在这里调它)里的任何 equip 之前。
func set_initial_inventory(types: Array) -> void:
	inventory.clear()
	_unequip()
	for t in types:
		if is_slot_enabled(int(t)):
			inventory.add(int(t), WeaponInventory.MAG_FULL)
	inventory_changed.emit()
	var idx := _first_enabled_index()
	if idx >= 0:
		_equip_index(idx)


# ── 切枪 ──
# 滚轮/数字键都走背包**位置**,不再走"启用槽位表"。
func cycle_slot(dir: int) -> void:
	var next := _peek_cycle(dir)
	if next < 0 or next == _current_index:
		# 无槽可切(只有一把 / 目标即当前):早退。与 request_net_cycle 同形;
		# 否则会白重建一次武器实例 + 响一声 switch(equip 每次都 instantiate)。
		return
	_equip_index(next)


# 计算滚轮方向的目标**背包位置**(不切换)。
func _peek_cycle(dir: int) -> int:
	var n := inventory.held.size()
	if n == 0:
		return -1
	var order: Array[int] = []
	for i in n:
		if is_slot_enabled(int(inventory.held[i]["type"])):
			order.append(i)
	if order.is_empty():
		return -1
	var idx := order.find(_current_index)
	if idx < 0:
		idx = 0
	return order[(idx + dir + order.size() * 2) % order.size()]


# ── PvP 滚轮切枪:本地立即切(即时反馈),目标**背包位置**打包进输入包由服务器权威同步 ──
# (滚轮事件不在输入包协议里,只本地切会被快照的防脱同步切回旧槽位 →「只有音效」)
# ★ 上行的是**背包位置(1-based)**,与数字键同一个量纲 —— 消费端
#   `player.gd` 读的是 `weapons.equip_index(wslot - 1)`(按位置)。这里曾经发
#   `inventory.held[next]["type"]`(类型 id 1-6):背包 `[步枪2, 手枪1]` 从步枪滚一下 → 发 1
#   → 服务器 `equip_index(0)` 切回**步枪**(等于没切);`[手枪1, 重狙3]` → 发 3 →
#   `equip_index(2)` **越界早退**,服务器压根没切。随后权威 `wslot` 经 `sync_soft_state`
#   把客户端拉回原枪 → 「滚轮切不动」。★ 它只在背包 ≥2 把时才现形(数字键那条两边同量纲、
#   一直是对的)—— 也就是"捡起武器之后"才看得出来。
var _net_slot := 0   # 待发切枪的**背包位置**(1-based;>0 = 待发,打包后清零)

func request_net_cycle(dir: int) -> void:
	var next := _peek_cycle(dir)
	if next < 0 or next == _current_index:
		return
	push_net_slot(next + 1)
	_equip_index(next)


# 入参 = 背包位置(1-based);由 `pvp_match_client` 的组包处取走塞进输入包的 weapon 字段。
func push_net_slot(slot: int) -> void:
	_net_slot = slot


func consume_net_slot() -> int:
	var v := _net_slot
	_net_slot = 0
	return v


# 按**类型 id**切枪(网络包 / rollback 走这条)。
# ★ 背包里没有这个类型就**加入** —— 这不是便利,是必需:联机不做客户端预测时,
#   服务器说"你现在有重狙"而客户端背包里可能还没有它;restore_state 重放 wslot
#   会走到这条路径。容量不足时也照加:权威说有什么就是什么,超容由服务器负责。
func equip(slot: String) -> void:
	var type_id := int(slot)
	if not is_slot_enabled(type_id):
		Sfx.play("deny")
		return
	var idx := inventory.first_index_of_type(type_id)
	if idx < 0:
		idx = inventory.held.size()
		inventory.add(type_id, WeaponInventory.MAG_FULL)
		inventory_changed.emit()
	_equip_index(idx)


# 按背包位置切枪(数字键 / 滚轮走这条)。
func equip_index(i: int) -> void:
	_equip_index(i)


func _equip_index(index: int) -> void:
	if index < 0 or index >= inventory.held.size():
		return
	# 切枪继承旧武器剩余冷却:后摇不能被切枪取消(queue_free 前先捕获)
	var inherit_cd := 0.0
	if _weapon != null and is_instance_valid(_weapon):
		inherit_cd = _weapon.fire_cd_timer
		# 残弹写回条目。只认**已入树**的枪:同帧第二次切枪时,上一把枪还是 call_deferred
		# 未入树(其 _ready 未跑 → mag_ammo 仍是 0),照记会把残弹永久抹成 0。
		# 真机可达:滚轮走 _unhandled_input,一帧内缓冲的 OS 事件会一次性泵完。
		# 守卫只加在这里,不外扩:fire_cd_timer 由本函数同步写入(未入树也有效),
		# 而 queue_free 必须照跑,否则未入树的旧枪实例泄漏。
		if _weapon.is_inside_tree() and _current_index >= 0 and _current_index < inventory.held.size():
			inventory.held[_current_index]["mag"] = _weapon.mag_ammo
		_weapon.queue_free()
		_weapon = null
	var type_id := int(inventory.held[index]["type"])
	var scene: PackedScene = load(WEAPONS.get(str(type_id), ""))
	if scene == null:
		push_error("weapon scene not found: " + str(WEAPONS.get(str(type_id), "<无此槽>")))
		return
	if body == null or body.weapon_slot == null:
		push_error("weapon_slot not assigned")
		return
	_current_index = index
	_current_slot = type_id
	_weapon = scene.instantiate() as WeaponBase
	body.weapon_slot.call_deferred("add_child", _weapon)
	_weapon.equip(body, inherit_cd)
	var mag := int(inventory.held[index]["mag"])
	if mag != WeaponInventory.MAG_FULL:
		# 武器 _ready(入树时)会把 mag_ammo 重置为满:恢复必须排在 deferred add 之后
		_restore_mag.call_deferred(_weapon, clampi(mag, 0, _weapon.mag_size))
	Sfx.play("switch")
	weapon_changed.emit(type_id)
	inventory_changed.emit()


# 空手:背包为空 / 当前那把被禁且没有别的可选。
func _unequip() -> void:
	if _weapon != null and is_instance_valid(_weapon):
		if _weapon.is_inside_tree() and _current_index >= 0 and _current_index < inventory.held.size():
			inventory.held[_current_index]["mag"] = _weapon.mag_ammo
		_weapon.queue_free()
	_weapon = null
	_current_index = -1
	_current_slot = 0
	weapon_changed.emit(0)
	inventory_changed.emit()


func _restore_mag(w: WeaponBase, ammo: int) -> void:
	if is_instance_valid(w):
		w.mag_ammo = ammo


# ── 拾取 / 丢弃 ──

# pick_up() 换下的那把枪的残弹(返回值只带得回类型 id,残弹走这里)。
var _last_dropped: Dictionary = {}


# 拾取一把类型为 type_id、残弹为 mag 的枪。
# 返回值:被**替换掉**的类型 id(>0 = 有替换);0 = 捡成功且没有替换;**-1 = 被拒绝,没捡成**。
# ★ -1 必须与 0 分开:调用方(Level0.try_pickup_for)在捡成功后会把地面那件删掉 ——
#   若"被闸门拒绝"也返回 0,地面那把会被**直接抹掉而玩家什么都没拿到**(静默丢枪)。
# ★ 替换规则(用户 2026-09-15 裁定):放不下(容量或 4 把上限)时替换**手上当前那把**,
#   被换下的那把的 {type, mag} 由调用方经 take_last_dropped() 取走,用来生成掉落物。
const PICKUP_DENIED := -1

func pick_up(type_id: int, mag: int) -> int:
	if not is_slot_enabled(type_id):
		Sfx.play("deny")
		return PICKUP_DENIED
	if inventory.can_hold(type_id):
		inventory.add(type_id, mag)
		inventory_changed.emit()
		_equip_index(inventory.held.size() - 1)
		return 0
	# 放不下 → 与手上那把交换。
	# 手上空着(背包空)时容量必然够(空背包 used_slots()=0,任何 cost ≤ 4 ≤ 8),
	# 所以这条分支只在"背包非空但全被禁用 → _current_index < 0"时才可能走到,直接拒绝。
	if _current_index < 0:
		Sfx.play("deny")
		return PICKUP_DENIED
	var entry: Dictionary = inventory.held[_current_index]
	var dropped := int(entry["type"])
	var dropped_mag := int(entry["mag"])
	if _weapon != null and is_instance_valid(_weapon) and _weapon.is_inside_tree():
		dropped_mag = _weapon.mag_ammo
	# 原位换类型,保留 inst(这把"位置"没变,换的是枪)
	inventory.held[_current_index] = {"type": type_id, "inst": int(entry["inst"]), "mag": mag}
	_equip_index(_current_index)
	_last_dropped = {"type": dropped, "mag": dropped_mag}
	return dropped


func take_last_dropped() -> Dictionary:
	var d := _last_dropped
	_last_dropped = {}
	return d


# 丢下手上当前那把。返回 {type, mag};空手时返回 {}。
func drop_current() -> Dictionary:
	if _current_index < 0:
		return {}
	var e: Dictionary = inventory.held[_current_index]
	var mag := int(e["mag"])
	if _weapon != null and is_instance_valid(_weapon) and _weapon.is_inside_tree():
		mag = _weapon.mag_ammo
	var out := {"type": int(e["type"]), "mag": mag}
	inventory.remove_at(_current_index)
	_weapon.queue_free()
	_weapon = null
	_current_index = -1
	_current_slot = 0
	inventory_changed.emit()
	# 手上那把没了 → 自动拿背包里第一把(丢完就空手站着很怪);背包空则彻底空手。
	var idx := _first_enabled_index()
	if idx >= 0:
		_equip_index(idx)
	else:
		weapon_changed.emit(0)
	return out


# 复活用:从背包**随机**保留一条,返回其余(供调用方在死亡点生成掉落物)。
# 背包为空时返回空表(也就没有"保留的那把")。
func random_keep_one() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if inventory.held.is_empty():
		return out
	var keep := randi() % inventory.held.size()
	var keep_entry: Dictionary = inventory.held[keep]
	for i in range(0, inventory.held.size()):
		if i != keep:
			out.append(inventory.held[i].duplicate())
	var kept: Array[Dictionary] = [keep_entry]
	inventory.held = kept
	_equip_index(0)
	return out


# ── 快照 / 恢复(rollback 用)──
# ★ 与 mag_ammo/_reloading/_reload_t 同口径:进 capture/restore,
#   **不进** _close_enough 的比对(否则每帧判分歧,变成无限回滚循环)。

# 把当前武器的残弹同步进条目,再吐出整份背包(含 inst 与残弹)。
func snapshot_inventory() -> Array:
	_flush_current_mag()
	return inventory.snapshot()


# 用权威整态重建背包。**必须先于 equip(wslot)** —— 否则重放时可能切到客户端
# 背包里没有的类型,走到 equip() 的"没有就加"分支,凭空造出一把服务器没有的枪。
func restore_inventory(entries: Array) -> void:
	# ★ **类型还在就保持手持那把不重建**:`restore_state` 每次 reconcile 都会调到这里,
	#   而无脑重建 = 每帧 queue_free 旧枪 + 新建一把 + deferred 入树 —— 入树前那一帧
	#   `tick()`/`fire()` 全是空转(该帧的开火边沿直接丢掉),而且白烧一次 instantiate。
	#   只在"权威说的东西变了"时才动武器实例。
	var keep_type := _current_slot
	inventory.restore(entries)
	var idx := inventory.first_index_of_type(keep_type) if keep_type > 0 else -1
	if idx >= 0:
		_current_index = idx
		_current_slot = keep_type
		var mag := int(inventory.held[idx]["mag"])
		if mag != WeaponInventory.MAG_FULL and _weapon != null and is_instance_valid(_weapon):
			_restore_mag.call_deferred(_weapon, clampi(mag, 0, _weapon.mag_size))
		inventory_changed.emit()
		return
	# 权威说手上那把没了(或本来空手)→ 清空手持,让调用方按 wslot 重新 equip
	# ★ 武器实例也要放掉:只清索引的话 `_weapon` 还活着,而 `tick()`/`fire()` 只判
	#   `_player_ok()`(player 非空且没倒地)、**不看索引** → 手上留着一把索引 -1 却照常
	#   开火的**幽灵枪**。早先这条路径要等一次回滚才走得到,软回灌之后是常路。
	if _weapon != null and is_instance_valid(_weapon):
		_weapon.queue_free()
	_weapon = null
	_current_index = -1
	_current_slot = 0
	inventory_changed.emit()


func _flush_current_mag() -> void:
	if _weapon == null or not is_instance_valid(_weapon) or not _weapon.is_inside_tree():
		return
	if _current_index >= 0 and _current_index < inventory.held.size():
		inventory.held[_current_index]["mag"] = _weapon.mag_ammo


# ── 其余 ──

# 把当前武器的残弹同步进背包条目。
# (旧的 _mag_state 残弹记忆表已删 —— 残弹现在直接存在背包条目里,没有独立的表可清。
#  保留本方法是为了调用方 player.restart_at 的边界不变。)
func reset_mag_state() -> void:
	_flush_current_mag()


# 复活/重启用:把当前武器的弹夹补满。
# 必须 call_deferred —— equip() 排下的 _restore_mag 会在帧末把旧残弹写回,
# 同帧同步写会被它覆盖(复活了却只有 3 发,且无报错)。本调用排在 _restore_mag 之后
# 入 defer 队列 → 帧末后写者胜 = 满弹。
func refill_current_weapon() -> void:
	var w := _weapon
	if w != null:
		_refill_mag.call_deferred(w)


func _refill_mag(w: WeaponBase) -> void:
	if is_instance_valid(w):
		w.mag_ammo = w.mag_size
	if _current_index >= 0 and _current_index < inventory.held.size():
		inventory.held[_current_index]["mag"] = WeaponInventory.MAG_FULL


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
