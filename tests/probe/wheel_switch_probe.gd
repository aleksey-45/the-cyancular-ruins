extends ProbeBase

# 滚轮切枪 / 换弹 / 弹数 探针(用户实机报:「弹数/开火异常,鼠标滚轮切枪可能还是有bug」,**用两把狙击枪测出来的**)。
const EXPECTED_CHECKS := 11
const SNIPER := 3   # 重狙 M82A1(heavy_aim);用户用两把同型号狙击测出来

var _player: Node = null
var _checks := 0


func probe_id() -> String:
	return "wheel_switch"


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


func _mag_of(index: int) -> int:
	var w: WeaponComponent = _player.weapons
	if index < 0 or index >= w.inventory.held.size():
		return -1
	return int(w.inventory.held[index]["mag"])


func _ready() -> void:
	var ts: PackedScene = load("res://scenes/player/player.tscn")
	if ts == null:
		_chk(false, "★ 空载守卫:load(player.tscn) 为 null")
		_finish()
		return
	_player = ts.instantiate()
	add_child(_player)
	await get_tree().physics_frame
	var w: WeaponComponent = _player.weapons

	# ── ① 同帧滚两次:两把狙击 + 一把手枪,各带自己的残弹 ──
	w.set_initial_inventory([SNIPER, SNIPER, 1])
	await _settle()
	w.inventory.held[0]["mag"] = 2
	w.inventory.held[1]["mag"] = 4
	w.inventory.held[2]["mag"] = 5
	w.current_weapon().mag_ammo = 2
	w.request_net_cycle(1)     # → 第二把狙击(同帧)
	w.request_net_cycle(1)     # → 手枪(同帧)
	await _settle()
	var cur2: WeaponBase = w.current_weapon()
	_chk(cur2 != null and cur2.mag_ammo == 5,
			"① 同帧滚两次:手持应是手枪且残弹 5(实得 %d)" % (cur2.mag_ammo if cur2 != null else -1))
	_chk(_mag_of(0) == 2 and _mag_of(1) == 4,
			"① 同帧滚两次:两把狙击条目残弹必须各自保留 2 / 4(实得 %d / %d)" % [_mag_of(0), _mag_of(1)])

	# ── ② 上行包必须带目标那把的 inst ──
	w.request_net_cycle(-1)    # → 第二把狙击
	await _settle()
	var uplink := w.take_uplink_switch(0)
	_chk(uplink > 0 and uplink == w.current_inst(),
			"② 滚轮上行必须是目标那把的 inst(上行 %d / 当前 %d)" % [uplink, w.current_inst()])

	# ── ③ 换弹中滚走再滚回:残弹 = 切走时值,不残留换弹 ──
	var cur3: WeaponBase = w.current_weapon()
	cur3.mag_ammo = 4
	cur3.start_reload()
	var was_reloading := cur3.is_reloading()
	w.request_net_cycle(1)     # 换弹中切走(→手枪)
	await _settle()
	w.request_net_cycle(-1)    # 切回第二把狙击
	await _settle()
	var cur4: WeaponBase = w.current_weapon()
	_chk(was_reloading, "③ 前置:切走前确实在换弹")
	_chk(cur4 != null and cur4.mag_ammo == 4,
			"③ 换弹中切走再切回:残弹必须还是 4(实得 %d;变 0=丢弹,变满=白送)" % (cur4.mag_ammo if cur4 != null else -1))
	_chk(cur4 != null and not cur4.is_reloading(),
			"③ 切回后不该还在换弹(否则是无限换弹)")

	# ── ④ 换弹完成后再切走:条目残弹必须同步为满弹 ──
	var cur5: WeaponBase = w.current_weapon()
	cur5.mag_ammo = 1
	cur5.start_reload()
	for _i in 200:   # 2.6s 换弹,给足 3.3s
		cur5.tick(1.0 / 60.0)
	var size_after := cur5.mag_ammo
	var size_capacity := cur5.mag_size
	w.request_net_cycle(1)     # 切走 ⇒ 触发条目写回(旧实例被 queue_free,之后不能再读它)
	await _settle()
	_chk(size_after > 1, "④ 前置:换弹应已完成(实得残弹 %d / 容量 %d)" % [size_after, size_capacity])
	_chk(_mag_of(1) == size_after,
			"④ 换弹完成后再切走:条目残弹必须同步为 %d(实得 %d)" % [size_after, _mag_of(1)])

	# ── ⑤ 切枪后开火:残弹只扣 1 发 ──
	w.request_net_cycle(-1)
	await _settle()
	var cur6: WeaponBase = w.current_weapon()
	if cur6 != null:
		cur6.fire_cd_timer = 0.0
		var before := cur6.mag_ammo
		cur6.try_fire()
		_chk(cur6.mag_ammo == before - 1 or before == 0,
				"⑤ 切枪后开火:残弹只扣 1 发(%d → %d)" % [before, cur6.mag_ammo])
	else:
		_chk(false, "⑤ 切枪后没有手持武器实例")

	# ── ⑥ ★ 实例与下标分家(同型号两把):手持的是第二把,权威载荷**没有 winst**(老载荷/按类型兜底)
	# ⇒ restore_inventory 的兜底会按类型把下标改指第一把,而实例还是第二把。必须重建实例,
	#   否则开火扣的是第二把的弹、下标/写回却落到第一把上(用户用两把狙击枪实测的"弹数/开火异常")。
	await _settle()
	var inst_a := int(w.inventory.held[0]["inst"])
	var inst_b := int(w.inventory.held[1]["inst"])
	w.equip_inst(inst_b)       # 手持第二把
	await _settle()
	var st := {
		"wslot": SNIPER,
		"winst": 0,             # ← 没有 winst:按类型兜底
		"inv": [
			{"type": SNIPER, "inst": inst_a, "mag": 2},
			{"type": SNIPER, "inst": inst_b, "mag": 4},
			{"type": 1, "inst": int(w.inventory.held[2]["inst"]), "mag": 5},
		],
	}
	_player.sync_soft_state(st)
	await _settle()
	var cw6: WeaponBase = w.current_weapon()
	_chk(w._current_index == 0 and cw6 != null and cw6.mag_ammo == 2 and w.instance_matched(),
			"⑥ ★ 同型号实例与下标分家:重建后实例残弹必须取下标那把的 2(实得 %d,匹配=%s)"
			% [cw6.mag_ammo if cw6 != null else -1, str(w.instance_matched())])

	# ── ⑦ 同型号 equip_inst 切到第二把:实例残弹 = 第二把条目的残弹 ──
	w.equip_inst(inst_b)
	await _settle()
	var cw7: WeaponBase = w.current_weapon()
	_chk(w.current_inst() == inst_b and cw7 != null and cw7.mag_ammo == 4,
			"⑦ 同型号 equip_inst 切到第二把:残弹必须取第二把条目 4(实得 %d)" % (cw7.mag_ammo if cw7 != null else -1))

	if _checks != EXPECTED_CHECKS:
		_check(false, "实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	_finish()
