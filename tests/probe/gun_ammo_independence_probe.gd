extends ProbeBase


const EXPECTED_CHECKS := 9
const WeaponLoadoutScript := preload("res://scenes/player/weapon_loadout.gd")

var _player: Node = null
var _checks := 0


func probe_id() -> String:
	return "gun_ammo_independence"


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	_check(ok, msg)


func _settle() -> void:
	var w: WeaponComponent = _player.weapons
	for _i in 3:
		await get_tree().process_frame
		await get_tree().physics_frame
		var cw: WeaponBase = w.current_weapon()
		if cw == null or cw.is_inside_tree():
			return


func _ready() -> void:
	var ts: PackedScene = load("res://scenes/player/player.tscn")
	_player = ts.instantiate()
	add_child(_player)
	await get_tree().physics_frame
	var w: WeaponComponent = _player.weapons

	w.set_initial_inventory([1, 1, 1, 1])
	await _settle()
	for i in w.inventory.held.size():
		w.inventory.held[i]["mag"] = 10
	w.current_weapon().mag_ammo = 3
	var old_mag := w.current_weapon().mag_ammo
	var dropped: int = w.pick_up(2, 5)
	await _settle()
	_chk(dropped == 1, "背包满时拾取必须替换手上那把(返回值 = 被换下的 type id 1,实得 %d)" % dropped)
	_chk(w.current_type_id() == 2, "替换后手持必须是新枪(type 2,实得 %d)" % w.current_type_id())
	var cw := w.current_weapon()
	_chk(cw != null and cw.mag_ammo == 5,
			"新枪残弹必须来自地面那件(5),不能继承旧枪实弹(%d);实得 %s" % [old_mag, str(cw.mag_ammo) if cw != null else "null"])
	var ci: int = w._current_index
	var entry_mag := int(w.inventory.held[ci]["mag"]) if ci >= 0 and ci < w.inventory.held.size() else -1
	_chk(entry_mag == 5, "新枪的背包条目残弹也必须是 5(实得 %d)" % entry_mag)
	var d: Dictionary = w.take_last_dropped()
	_chk(int(d.get("type", -1)) == 1 and int(d.get("mag", -1)) == old_mag,
			"被换下的枪掉落时必须带走它自己的实弹(type 1 / mag %d),实得 %s" % [old_mag, str(d)])

	w.set_initial_inventory([1, 1, 1])
	await _settle()
	w.inventory.held[0]["mag"] = 11
	w.inventory.held[1]["mag"] = 22
	w.inventory.held[2]["mag"] = 33
	w.current_weapon().mag_ammo = 7
	var pick_seed := 1
	for sd in range(1, 200):
		seed(sd)
		if int(randi() % 3) != 0:
			pick_seed = sd
			break
	seed(pick_seed)
	var kept_idx := int(randi() % 3)
	seed(pick_seed)
	var rest: Array = w.random_keep_one()
	await _settle()
	var expect_kept: int = [7, 22, 33][kept_idx]
	var kept_mag := int(w.inventory.held[0]["mag"]) if w.inventory.held.size() == 1 else -1
	_chk(kept_mag == expect_kept,
			"随机保留那把的条目残弹必须是它自己的(%d,kept_idx=%d);实得 %d" % [expect_kept, kept_idx, kept_mag])
	var rest_mags: Array = []
	for e in rest:
		rest_mags.append(int(e["mag"]))
	_chk(rest_mags.has(7) and not rest_mags.has(11),
			"倒地掉落的当前枪必须带真实实弹 7(不是条目陈旧值 11),实得 %s" % str(rest_mags))

	w.set_initial_inventory([1, 1])
	await _settle()
	w.current_weapon().mag_ammo = 4
	var dropped2: int = w.pick_up(2, 5)
	await _settle()
	var cw2 := w.current_weapon()
	_chk(dropped2 == 0 and w.current_type_id() == 2 and cw2 != null and cw2.mag_ammo == 5,
			"对照:背包没满时拾取直接放入,新枪残弹 = 地面 5(实得 dropped=%d / type=%d / mag=%s)"
			% [dropped2, w.current_type_id(), str(cw2.mag_ammo) if cw2 != null else "null"])

	# ⑨ pick_up 三态的第三种:被启用类型闸门拒绝必须返回 PICKUP_DENIED(-1)。
	# 与 0(成功无替换)分开是承重的:Level0.try_pickup_for 只在成功时删地面那件;混同 = 静默丢枪。
	w.set_enabled_types([3])
	var denied: int = w.pick_up(3, 5)
	_chk(denied == WeaponLoadoutScript.PICKUP_DENIED,
			"被拒的拾取必须返回 PICKUP_DENIED(-1),不能与成功 0 混同(实得 %d)" % denied)

	if _checks != EXPECTED_CHECKS:
		_check(false, "实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	_finish()