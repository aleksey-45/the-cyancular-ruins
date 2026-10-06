class_name WeaponComponent
extends Node

# 武器子系统:注册表 / 背包 / 换枪 / 移动惩罚 / 后坐。枪实例挂在 body.weapon_slot 下。
# 由根 player.gd 驱动(equip_type 在 _ready/换枪输入,movement_multiplier 每物理帧,
# apply_recoil 由 weapon_base 经根转发)。
#
# ★ 2026-09-15 起是**背包模型**:玩家有 8 格容量预算(轻2/中3/重4)与 4 把上限
#   (两条独立闸门,见 WeaponInventory)。此前是"按类型 id 1-6 直接切枪、无条件持有全部"。
#
# ★ `_current_type` 刻意**仍是武器类型 id**(1-6),不是背包位置:快照的 weapon 字段
#   (match_snapshot)、capture_state 的 wslot、PlayerReplica._swap_weapon 全按类型 id 走
#   —— 协议与副本因此零改动。背包位置只用于本地按键/滚轮。

# ★★ 本文件从前有三张 GDScript 常量表(场景路径 / 显示名 / 重量档),2026-09-26 已**整体删除**
#   —— 它们现在只在 `data/weapons.json` 里,唯一来源是 `core/sim/weapon_registry.gd`
#   (`WeaponRegistry`)。这里**不留任何一份副本**:留一张就会与 json 分家,而"加第 7 把枪
#   只改一个 json"正是本计划要买到的东西(守卫 = enemy_logic_smoke 的 ⑤b)。

signal weapon_changed(type_id: int)    # equip_type 成功后发射(菜单图标/HUD 武器显示跟随);0 = 空手
signal inventory_changed()          # 背包内容变化(格子 UI 跟随)

# 当前手持的**类型 id**(1-6);0 = 空手(背包为空)。
var _current_type: int = 0
var _current_index: int = -1        # 在 inventory.held 里的下标;-1 = 空手
var _weapon: WeaponBase = null
var inventory: WeaponInventory
var body: CharacterBody2D

# 启用的武器**类型 id**。默认全开 = 注册表里全部 id(**在 `_init` 里赋值** —— 不在这里);
# 单机由 Level0 按 RunOptions 设置;PvP 由客户端按服务器下发的 match_options 设置。
# 数字键/滚轮切枪都会跳过被禁的类型。
# ★ 从前这里是硬编码的 `[1, 2, 3, 4, 5, 6]`:加第 7 把枪时漏改它,新枪**永远拿不到也开不了**,
#   且**完全不报错**。赋值搬进 `_init` 不是风格偏好 —— `ScanUtil.func_body` 断言不了
#   class 级的 `var`,只有把它放进函数体, ⑥ 那条守卫才存在。
var enabled_types: Array = []

# ★ 武器**图标与选择格**(silhouette / make_weapon_check)不在这里 —— 它们是纯 UI,
#   2026-09-15 阶段 4.1 搬去了 `ui/weapon_icons.gd`(WeaponIcons)。
#   本文件只留武器子系统本身:注册表 / 背包 / 换枪 / 移动惩罚 / 后坐。


func _init() -> void:
	# 在 _init 而不是 _ready 建:探针会 new() 出组件直接调方法,不一定入树。
	inventory = WeaponInventory.new(WeaponRegistry.tiers_map())
	# ★★ **默认启用表必须在构造期就填好,且必须走 `all_ids()`** —— 两件事都只在这一行成立:
	#   ① ⑦(`comp.enabled_types == registry.all_ids()`)读的是**刚 new() 出来**的组件;
	#   ② Task 1 的 ⑥ 锚在**函数体**上:`ScanUtil.func_body` 表达不了 class 级的 `var`,
	#      所以上面那条 `var enabled_types: Array = [...]` 必须**先是空表**,
	#      再由这一行填 —— 只把那条 var 改成 `all_ids()` 会让 ⑤ 绿、⑥ 红。
	enabled_types = WeaponRegistry.all_ids()


func _ready() -> void:
	body = get_parent() as CharacterBody2D


func set_enabled_types(disabled: Array[int]) -> void:
	enabled_types = WeaponRegistry.all_ids().filter(func(t: int) -> bool: return not disabled.has(t))
	if enabled_types.is_empty():
		# 不允许全禁:至少留**注册表里的第一把**(今天 = 1 号手枪)。
		# ★ 这里从前写死 `[1]`。注册表化之后"手枪"这个概念只活在 json 的顺序里,
		#   写死一个 id 会在将来重排 json / 删号时**静默**指到别的枪。
		var ids := WeaponRegistry.all_ids()
		enabled_types = [ids[0]] if not ids.is_empty() else []
	# 当前拿着的枪被禁 → 切到背包里第一把没被禁的;没有就空手
	if _current_type > 0 and not is_type_enabled(_current_type):
		var fallback := _first_enabled_index()
		if fallback >= 0:
			_equip_index(fallback)
		else:
			_unequip()


func is_type_enabled(type_id: int) -> bool:
	return enabled_types.has(type_id)


func _first_enabled_index() -> int:
	for i in inventory.held.size():
		if is_type_enabled(int(inventory.held[i]["type"])):
			return i
	return -1


# 默认槽位 = 最小的启用槽位(出生/复活用它,防止出生武器被禁后空手)。
func default_type() -> String:
	return str(enabled_types[0]) if enabled_types.size() > 0 else "1"


# ── 初始背包 ──
# 由调用方决定:单机 = 空表(开局空手,枪散落在地图上);联机 = 一条随机武器。
# ★ 必须排在 _ready(Player 会在这里调它)里的任何 equip_type 之前。
func set_initial_inventory(types: Array) -> void:
	inventory.clear()
	_unequip()
	for t in types:
		if is_type_enabled(int(t)):
			inventory.add(int(t), WeaponInventory.MAG_FULL)
	inventory_changed.emit()
	var idx := _first_enabled_index()
	if idx >= 0:
		_equip_index(idx)


# ── 切枪 ──
# 滚轮/数字键都走背包**位置**,不再走"启用槽位表"。
func cycle_index(dir: int) -> void:
	var next := _peek_cycle(dir)
	if next < 0 or next == _current_index:
		# 无槽可切(只有一把 / 目标即当前):早退。与 request_net_cycle 同形;
		# 否则会白重建一次武器实例 + 响一声 switch(equip_type 每次都 instantiate)。
		return
	_equip_index(next)


# 计算滚轮方向的目标**背包位置**(不切换)。
func _peek_cycle(dir: int) -> int:
	var n := inventory.held.size()
	if n == 0:
		return -1
	var order: Array[int] = []
	for i in n:
		if is_type_enabled(int(inventory.held[i]["type"])):
			order.append(i)
	if order.is_empty():
		return -1
	var idx := order.find(_current_index)
	if idx < 0:
		idx = 0
	return order[(idx + dir + order.size() * 2) % order.size()]


# ── PvP 切枪:本地立即切(即时反馈),再把**目标那一把的 inst** 打包进输入包由服务器权威同步 ──
# (滚轮事件不在输入包协议里,只本地切会被快照的防脱同步切回旧槽位 →「只有音效」)
# ★★ 上行的是 **inst**,不是背包位置 —— 这是本设计最要紧的一处(§4.1):
#   "第 N 把"的含义由**本端背包**决定,而拾取/丢弃是服务器裁决、客户端**不预测**;
#   那 ≈1 RTT 的窗口里,同一个下标在两端解出**不同的枪**(滚轮切不动 / 切到另一把的结构性来源)。
#   `inst` 逐把唯一,与两端 `held` 的**顺序**无关。
#   历史代价(留档):这里曾经发 `inventory.held[next]["type"]`(类型id)、而消费端按位置读 ——
#   背包 `[步枪2, 手枪1]` 从步枪滚一下发 1 → 服务器切回步枪(等于没切);`[手枪1, 重狙3]` 发 3
#   → 越界早退(压根没切)。两条都只表现为「滚轮切不动」,而代码里没有任何一处会红。
var _switch_inst := 0   # 待发切枪的目标 **inst**(>0 = 待发,打包后清零)

func request_net_cycle(dir: int) -> void:
	var next := _peek_cycle(dir)
	if next < 0 or next == _current_index:
		return
	push_switch_inst(inst_at_index(next))
	_equip_index(next)


# 入参 = 目标那一把的 **inst**;由 `pvp_match_client` 的组包处取走塞进输入包的 winst 字段。
func push_switch_inst(inst: int) -> void:
	_switch_inst = inst


func consume_switch_inst() -> int:
	var v := _switch_inst
	_switch_inst = 0
	return v


# 客户端上行前把"玩家想切到**哪一把**"解析成 inst(§4.1:上行传解析结果,不传寻址方式)。
# 两条来源都是**本地交互**,只有客户端知道玩家点的是第几个:
#   · 数字键 → `key_index`(1-based 背包位置)→ 查那一把的 inst
#   · 滚轮   → `request_net_cycle` 已本地切好并 push_switch_inst(目标 inst)
# 数字键优先;滚轮那条无论如何**都取走**(读一次即清 —— 别让它漏到下一帧变成一次迟到的切枪)。
# 返回 0 = 本次没有切枪请求。
func take_uplink_switch(key_index: int) -> int:
	var wheel_inst := consume_switch_inst()
	if key_index > 0:
		var inst := inst_at_index(key_index - 1)
		if inst > 0:
			return inst
	return wheel_inst


# 第 index 条(0-based)的 inst;越界返回 0。数字键上行解析用。
func inst_at_index(index: int) -> int:
	if index < 0 or index >= inventory.held.size():
		return 0
	return int(inventory.held[index]["inst"])


# 按**类型 id**切枪(rollback / 权威兜底走这条)。
# ★ 背包里没有这个类型 = **异常**,不再"顺手造一把"(§4.5,2026-09-25 改)。
#   旧实现有一条"没有就加"(注释写着"这不是便利,是必需…服务器说'你现在有重狙'而客户端背包里
#   可能还没有它")。§4.1 落地后这条兜底**不再需要**:客户端背包只从权威态(`inv`)重建,
#   而 `restore_inventory` 先跑、`_apply_weapon_state` 的 `by_inst` 再判重建落点
#   ⇒ "权威说的那把不在本地表里"只可能是**真异常**。
#   ★ 更要紧的是:它会**静默改变背包长度**,而那正是"两端 held 不同序"的另一条产生源
#   (§4.1 要消灭的东西)。所以这里降级成 push_error + **不加入**。
#   ★ 单机不受影响:`pick_up` 走 `WeaponInventory.add`,不经过本函数。
func equip_type(type_id: int) -> void:
	if not is_type_enabled(type_id):
		Sfx.play("deny")
		return
	var idx := inventory.first_index_of_type(type_id)
	if idx < 0:
		push_error("equip_type: 背包里没有类型 %d —— 不再凭空加入(§4.5;见本函数注释)" % type_id)
		return
	_equip_index(idx)


# 按 **inst** 切枪(网络上行 / 权威落点走这条)。
# ★ 找不到那把时**静默不动** —— 语义比"下标越界"准确:`inst` 逐把唯一,服务器手里没有它
#   只可能是那一把已经不在了(被丢/被换),此时切到别的枪是**错的**。
#   (旧路径 `equip_index(wslot - 1)` 在那种情况下会越界早退,或更糟:切到位置上的另一把。)
func equip_inst(inst: int) -> void:
	if inst <= 0:
		return
	var idx := inventory.index_of_inst(inst)
	if idx < 0:
		return
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
	var scene_path := WeaponRegistry.scene_of(type_id)
	var scene: PackedScene = load(scene_path) if not scene_path.is_empty() else null
	if scene == null:
		push_error("weapon scene not found: id=%d(%s)" % [type_id, scene_path])
		return
	if body == null or body.weapon_slot == null:
		push_error("weapon_slot not assigned")
		return
	_current_index = index
	_current_type = type_id
	_weapon = scene.instantiate() as WeaponBase
	# ★ 必须在 add_child **之前**:add_child 是 deferred 的,而 `_ready` 会把 mag_ammo 重置为满
	#   ⇒ 入树后再同步写会晚于 `_ready`?不会 —— 但入树前写**根本无效**(会被 `_ready` 冲掉)。
	#   故这里直接把条目残弹塞进 pending_mag,由 `_ready` 消费。
	#   MAG_FULL(-1)语义是"满弹",交给 `_ready` 的 mag_size 即可,不设 pending。
	if int(inventory.held[index]["mag"]) != WeaponInventory.MAG_FULL:
		_weapon.pending_mag = clampi(int(inventory.held[index]["mag"]), 0, _weapon.mag_size)
	body.weapon_slot.call_deferred("add_child", _weapon)
	_weapon.equip(body, inherit_cd)
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
	_current_type = 0
	weapon_changed.emit(0)
	inventory_changed.emit()


# 把一个权威/条目里的弹数写到武器实例上。**同步**,不再排 deferred。
# ★ 分支只有一条判据 —— `is_inside_tree()`:
#   · 已入树:`_ready` 早已跑过(mag_ammo 被设成 mag_size),同步写就是终值;
#   · 未入树:本帧刚 `instantiate` 出来,`_ready` 还没跑,直接写会被它冲掉 ⇒ 交给 pending_mag。
#   这个判据与 `_equip_index` 里那处"残弹写回只认已入树的枪"是同一条(那里防的是读未 _ready 的 0)。
static func apply_mag(w: WeaponBase, mag: int) -> void:
	if w == null or not is_instance_valid(w):
		return
	if w.is_inside_tree():
		w.mag_ammo = clampi(mag, 0, w.mag_size)
	else:
		w.pending_mag = clampi(mag, 0, w.mag_size)


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
	if not is_type_enabled(type_id):
		Sfx.play("deny")
		return PICKUP_DENIED
	if inventory.can_hold(type_id):
		inventory.add(type_id, mag)
		inventory_changed.emit()
		_equip_index(inventory.held.size() - 1)
		return 0
	# 放不下 → 与手上那把交换。
	# 手上空着(背包空)时容量必然够(空背包 used_cell_count()=0,任何 cost ≤ 4 ≤ 8),
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
	_current_type = 0
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


# 用权威整态重建背包。**必须先于 equip_type(wslot)** —— 否则重放时可能切到客户端
# 背包里没有的类型,`equip_type` 只 push_error、不加入(§4.5)。
# 返回值:**是否按 `want_inst` 解析成功**(即手持下标来自权威的 `winst`)。
# ★ 调用方靠它决定"重建实例时走下标还是走类型" —— 见 `player._apply_weapon_state`。
#   返回 false 表示走的是**按类型**兜底(老载荷无 `winst`、或权威那把不在表里),
#   此时下标只代表"旧类型那把",拿它去重建会把权威的 wslot 顶掉。
func restore_inventory(entries: Array, want_inst: int = 0) -> bool:
	# ★ **类型还在就保持手持那把不重建**:`restore_state` 每次 reconcile 都会调到这里,
	#   而无脑重建 = 每帧 queue_free 旧枪 + 新建一把 + deferred 入树 —— 入树前那一帧
	#   `tick()`/`fire()` 全是空转(该帧的开火边沿直接丢掉),而且白烧一次 instantiate。
	#   只在"权威说的东西变了"时才动武器实例。
	#
	# ★★ `want_inst` = 权威说"手持的是**哪一把**"(`capture_state` 的 `winst`)。
	#   **必须先按 inst 找**:`inst` 逐把唯一,而同型号两把**类型相同** ⇒ 按类型找只能拿到第 0 把
	#   ⇒ `_current_index` 与手上真正那把分家:残弹写进**错的那把**、**丢弃丢错把**、
	#   左上角武器框高亮错(用户 2026-09-23 报的就是最后这一条的表现)。
	#   找不到(老载荷没带 `winst`、或权威那把不在表里)时**退回按类型** —— 行为与改动前逐字相同。
	var keep_type := _current_type
	inventory.restore(entries)
	var idx := inventory.index_of_inst(want_inst) if want_inst > 0 else -1
	var by_inst := idx >= 0
	if not by_inst:
		idx = inventory.first_index_of_type(keep_type) if keep_type > 0 else -1
	if idx >= 0:
		_current_index = idx
		# ★★ `_current_type` **保持 `keep_type`(旧类型),不要改成表里那一条的类型** ——
		#   调用方 `player._apply_weapon_state` 靠 `wslot != _current_type` 决定**要不要 `equip_type()`**,
		#   而 `equip_type()` 顺带**重建武器实例**。改成表里那条的类型后,同类型时那个判据恒假
		#   ⇒ 实例永不重建 ⇒ 被清空过背包的一方恢复后**手上没枪**,武器不再写 `set_facing`,
		#   与权威在 `facing` 上发散(`pvp_twin_smoke` 实测 tick=255 红)。真正的类型不一致
		#   那一档仍由调用方的 `equip_type(wslot)` 收尾 —— 那是**已有**行为,别绕开它。
		_current_type = keep_type
		inventory_changed.emit()
		return by_inst
	# 权威说手上那把没了(或本来空手)→ 清空手持,让调用方按 wslot 重新 equip_type
	# ★ 武器实例也要放掉:只清索引的话 `_weapon` 还活着,而 `tick()`/`fire()` 只判
	#   `_player_ok()`(player 非空且没倒地)、**不看索引** → 手上留着一把索引 -1 却照常
	#   开火的**幽灵枪**。早先这条路径要等一次回滚才走得到,软回灌之后是常路。
	if _weapon != null and is_instance_valid(_weapon):
		_weapon.queue_free()
	_weapon = null
	_current_index = -1
	_current_type = 0
	inventory_changed.emit()
	return false


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


# ★ 2026-09-25:原 `refill_current_weapon()` / `_refill_mag()` **已删除**。它们存在的唯一理由是
#   "`_refill_mag` 必须 deferred、且要排在 `equip_type()` 排下的 `_restore_mag.call_deferred` 之后" ——
#   而 `_restore_mag` 这条帧末写回本身已随 `pending_mag` 一起删除(回滚不再抹掉弹数)。
#   且全仓**没有任何生产调用点**(复活满弹由 `Level0.restart_single` 统一重置背包)。
#   ⚠ 删掉 `_restore_mag` **不等于**弹数有了常规纠正路径:`_close_enough` 仍不比 `mag`,
#     `sync_soft_state` 的指纹只比结构 ⇒ 非回滚来源的弹数分歧仍会静默保留(见 docs/eng/weapons.md)。


func current_weapon() -> WeaponBase:
	return _weapon


func current_type_id() -> int:
	return _current_type


# 手持那一条的 `inst`(逐把唯一);空手 / 下标越界返回 0。
# ★ 与 `current_type_id()` 的分工:那个是**类型 id**(协议/副本按它走),同型号两把**恒等**;
#   这个才回答"是**哪一把**"—— 权威态(`capture_state` 的 `winst`)与 UI 高亮都需要它。
func current_inst() -> int:
	return inst_at_index(_current_index)


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
