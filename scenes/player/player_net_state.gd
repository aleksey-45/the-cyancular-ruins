class_name PlayerNetState
extends RefCounted

# C2 整态(capture/restore)的**装配处**:决定下一物理帧输出的变量 = 根本体字段 + climb / swim / combat / weapons 各自的状态。
# 漏一个变量 → 回滚重放与服务器分歧;字段键名尽量短,压缩协议体积。
# ★ 键名的唯一 schema 是线上快照:core/net/net_codec.gd 的 C2_SCHEMA + WEAPON_SCHEMA。本文件**不另立一份键清单**
#   (另立一份就是第二个真相源)。加字段 = 加在有所有权的那个组件里 + 改 schema;装配处只在"新增一个组件"时动。
# ★ 顺序与拆分前逐字一致:本体字段 → combat(hp/倒地/无敌帧/击退) → climb → swim → weapons。
#   最后一步(碰撞箱/朝向贴图/贴地重判)留在 Player._after_state_restore:它改的是场景节点,不是可序列化状态。


static func capture(p: Player) -> Dictionary:
	var st: Dictionary = p.capture_self_state()
	st.merge(p.climb.capture_state(), true)
	st.merge(p.swim.capture_state(), true)
	st.merge(p.combat.capture_state(), true)
	st.merge(p.weapons.capture_state(), true)
	return st


static func restore(p: Player, st: Dictionary) -> void:
	p.restore_self_state(st)
	p.combat.restore_state(st)
	p.climb.restore_state(st)
	p.swim.restore_state(st)
	p.weapons.restore_state(st)


# 软同步:只补权威裁决的字段(拾取/丢弃/复活/换局),不动预测出来的位置/速度 —— 拿权威覆盖位置才是橡皮筋。
static func sync_soft(p: Player, st: Dictionary) -> void:
	p.weapons.sync_soft(st)


# 服务器快照的权威 hp/氧/倒地:与整态恢复共用"倒地不顶满 hp"的判据(见 CombatComponent.restore_state)。
static func apply_authoritative(p: Player, hp_val: int, waterproof_val: int, downed_val: bool) -> void:
	p.combat.apply_authoritative(hp_val, downed_val)
	p.swim.set_waterproof(waterproof_val)
