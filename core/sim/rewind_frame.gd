class_name RewindFrame
extends RefCounted

# 玩家回溯载荷的**唯一**契约:单机 WorldRewind 与服务器 Beta 回溯共用同一份生产者与恢复实现。
# 加字段 = 改 PLAYER_KEYS + build_player + apply_player + tests/scene/rewind_frame_probe.gd 的 READERS;
# 探针第 ① 条会把"加了键却没补断言"照出来 —— 它不是同源重复,是防止契约漏测的闸。
# ★ 键名短是刻意的:这份载荷只在内存里活,不上线(线上格式见 core/net/net_codec.gd 的 C2_SCHEMA)。
# ★ 帧的外层形状 = `{t, player}`:enemies / bullets 是 WorldRewind 的私有扩展,不属于本契约。
const PLAYER_KEYS: Array[String] = ["p", "v", "hp", "facing", "downed", "widx", "wmags", "wlive"]


# 保证 PLAYER_KEYS 全在(含武器段缺省值):调用方不再需要 has() 防御。
static func build_player(p: Player) -> Dictionary:
	var wc: WeaponComponent = p.weapons
	var widx := -1
	var wmags: Array = []
	var wlive := -1
	if wc != null:
		widx = wc._current_index
		var inv: WeaponInventory = wc.inventory
		if inv != null:
			for e in inv.held:
				wmags.append(int(e["mag"]))
		var live: WeaponBase = wc.current_weapon()
		if live != null and is_instance_valid(live):
			wlive = live.mag_ammo
	return {
		"p": p.global_position,
		"v": p.velocity,
		"hp": p.hp,
		"facing": p.facing_direction,
		"downed": p.is_downed(),
		"widx": widx,
		"wmags": wmags,
		"wlive": wlive,
	}


# 缺键 = 契约破了,让它当场抛错,不写 has() 防御(静默跳过只会让回溯"看着生效")。
static func apply_player(p: Player, d: Dictionary) -> void:
	p.global_position = d["p"]
	p.velocity = d["v"]
	p.combat.knock_velocity = Vector2.ZERO
	# ★ 必须发 hp_changed:HUD 血条只听信号(不是每帧轮询),直接改 combat.hp 的话血条会停在旧值。
	var hp_before: int = p.hp
	var hp_new := clampi(int(d["hp"]), 0, p.max_hp)
	if hp_new != hp_before:
		p.combat.hp = hp_new
		p.combat.hp_changed.emit(hp_new, p.max_hp)
	p.facing_direction = int(d["facing"])
	var downed_before: bool = p.is_downed()
	_apply_weapons(p, d)
	var downed_want := bool(d["downed"])
	if downed_want and not downed_before:
		p.combat.set_downed_by_rewind(true)
	elif not downed_want and downed_before:
		# ★ 不走 revive():它会把 hp 顶成满血,冲掉上面刚从快照恢复的 hp。
		p.combat.restore_alive_state()


# 弹量回溯的语句序是承重面(见 docs/systems/gameplay/time.md §10):切枪必须排在条目写回之前 ——
# _equip_index 会把走掉那把的出膛实弹写回条目;手持实弹走 apply_mag(未入树窗口写 pending)。
static func _apply_weapons(p: Player, d: Dictionary) -> void:
	var wc: WeaponComponent = p.weapons
	if wc == null:
		return
	var inv: WeaponInventory = wc.inventory
	var want_idx := int(d["widx"])
	var switched := want_idx >= 0 and want_idx != wc._current_index
	if switched:
		wc.equip_index(want_idx)
	if inv != null:
		var held: Array = inv.held
		var mags: Array = d["wmags"]
		for i in mini(held.size(), mags.size()):
			held[i]["mag"] = int(mags[i])
	var live2: WeaponBase = wc.current_weapon()
	if live2 == null or not is_instance_valid(live2):
		return
	var want := int(d["wlive"])
	if want < 0 and switched and inv != null and wc._current_index >= 0 \
			and wc._current_index < inv.held.size():
		# 快照没记手持实弹而这次换了枪 ⇒ 用快照条目值,不是恢复前的旧值。
		want = int(inv.held[wc._current_index]["mag"])
		# ★ 两个 -1 语义不同:wlive 的 -1 = 哨兵;条目 mag 的 MAG_FULL(-1) = 满弹。折成 mag_size 与不设 pending 同效。
		if want == WeaponInventory.MAG_FULL:
			want = live2.mag_size
	if want >= 0:
		WeaponComponent.apply_mag(live2, want)
