class_name WeaponState
extends RefCounted

# 整态的**武器段**:capture / restore / 软同步 / 回灌(键名 = NetCodec 的 C2_SCHEMA + WEAPON_SCHEMA)。
# 与 core/sim/rewind_frame.gd 同一形态:纯静态、无状态,只操作 WeaponComponent 的公开面。
# ★ 为什么单独一个文件:这五条是"协议面"(键序、缺键语义、弹量回写窗口),与"背包/手持怎么变"是两种变更理由;
#   放在一起时改协议要读装备逻辑,改装备要担心键。语句序不变量见 §apply 的注释。
# ★ 不持有 Node:探针与服务器都能直接调;WeaponComponent 只做一行转发。


static func capture(c: WeaponComponent) -> Dictionary:
	var st := {
		"wslot": c.current_type_id(),
		"winst": c.current_inst(),
		"inv": c.snapshot_inventory(),
	}
	var w := c.current_weapon()
	if w != null and is_instance_valid(w):
		st.merge(w.capture_state(), true)
	return st


static func restore(c: WeaponComponent, st: Dictionary) -> void:
	apply(c, st)


# 非预测字段的软同步(拾取/丢弃/复活/换局改的就是这些):先比指纹再动手 —— restore_inventory 会 emit inventory_changed,
# 无脑调等于每帧重建 HUD 武器框;mag 是连续量,指纹只比结构不比它。
static func sync_soft(c: WeaponComponent, st: Dictionary) -> void:
	# ★ 指纹必须连 winst 一起比:同型号两把之间换手时 wslot 与背包结构都不变。
	if int(st.get("wslot", c.current_type_id())) == c.current_type_id() \
			and int(st.get("winst", c.current_inst())) == c.current_inst() \
			and inv_structure_equal(c, st.get("inv", [])):
		return
	apply(c, st)


# 只比结构(type/inst 的有序对):mag 本地每帧都在变,比它等于每帧都不一致,指纹守卫当场失效。
static func inv_structure_equal(c: WeaponComponent, want: Array) -> bool:
	var held: Array = c.inventory.held
	if held.size() != want.size():
		return false
	for i in held.size():
		if int(held[i]["type"]) != int(want[i].get("type", 0)):
			return false
		if int(held[i]["inst"]) != int(want[i].get("inst", 0)):
			return false
	return true


# 武器/弹药的权威字段回灌(整态恢复与软同步共用)。
# ★ 顺序不可反:先读 wslot(_current_type 还有值,可作默认)→ restore_inventory(会清 _current_type)
#   → 判实例是否匹配/重建 → 最后回灌武器字段。写反就把快照弹量冲掉(见 docs/eng/time.md §10 同源坑)。
static func apply(c: WeaponComponent, st: Dictionary) -> void:
	var wslot := int(st.get("wslot", c.current_type_id()))
	var by_inst := c.restore_inventory(st.get("inv", []), int(st.get("winst", 0)))
	if c.current_index() >= 0 and not c.instance_matched():
		c.equip_index_authoritative(c.current_index())
	if wslot > 0 and wslot != c.current_type_id():
		if by_inst and c.current_index() >= 0:
			c.equip_index(c.current_index())
		else:
			c.equip_type(wslot)
	var w := c.current_weapon()
	if w != null and is_instance_valid(w):
		w.restore_state(st)
