extends ProbeBase

# 回溯载荷契约(core/sim/rewind_frame.gd):build 写出的每个键必须能被 apply 读回,倒地恢复不许改 hp。
# 存在理由:单机 WorldRewind 与服务器 Beta 回溯曾各手写一份 8 键载荷(其中 `wslot` 无人读),
# 而这一面**零守卫** —— 这支探针是它第一次有断言。

const EXPECTED_CHECKS := 2
const PLAYER_SCENE := "res://scenes/player/player.tscn"
const RewindFrame := preload("res://core/sim/rewind_frame.gd")

var _checks := 0
var _readers: Dictionary = {}


func probe_id() -> String:
	return "rewind_frame"


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	_check(ok, msg)


func _ready() -> void:
	# 契约键 → 取值器。PLAYER_KEYS 加键却没加这里 = ① 会红(防止新字段漏测)。
	_readers = {
		"p": func(pl: Player) -> Vector2: return pl.global_position,
		"v": func(pl: Player) -> Vector2: return pl.velocity,
		"hp": func(pl: Player) -> int: return pl.hp,
		"facing": func(pl: Player) -> int: return pl.facing_direction,
		"downed": func(pl: Player) -> bool: return pl.is_downed(),
		"widx": func(pl: Player) -> int: return pl.weapons._current_index,
		"wmags": func(pl: Player) -> String: return _mags_of(pl),
		"wlive": func(pl: Player) -> int: return _live_mag_of(pl),
	}

	var ps: PackedScene = load(PLAYER_SCENE)
	if ps == null:
		_chk(false, "★ 空载守卫:load(player.tscn) 为 null")
		_finish()
		return
	var src: Player = ps.instantiate()
	var dst: Player = ps.instantiate()
	for p in [src, dst]:
		p.set_physics_process(false)   # 探针不跑移动:位置与状态由断言自己摆
		add_child(p)
	await get_tree().process_frame
	await get_tree().process_frame

	# ── ① 载荷往返:8 个键都在、apply 后逐键相等、hp 变化发过信号 ──
	_put_weapons(src, 0, [5, 7])
	_put_weapons(dst, 1, [9, 7])
	await get_tree().process_frame
	await get_tree().process_frame
	_set_live_mag(src, 3)
	_set_live_mag(dst, 4)
	src.global_position = Vector2(321.0, 654.0)
	src.velocity = Vector2(120.0, -40.0)
	src.facing_direction = -1
	src.combat.hp = 3

	var f: Dictionary = RewindFrame.build_player(src)
	var got_keys := f.keys()
	got_keys.sort()
	var want_keys: Array = RewindFrame.PLAYER_KEYS.duplicate()
	want_keys.sort()
	var bad: Array[String] = []
	if str(got_keys) != str(want_keys):
		bad.append("键集 %s ≠ 契约 %s" % [str(got_keys), str(want_keys)])

	var fired := [0]
	dst.hp_changed.connect(func(_c: int, _m: int) -> void: fired[0] += 1)
	RewindFrame.apply_player(dst, f)
	await get_tree().process_frame
	await get_tree().process_frame
	for k in RewindFrame.PLAYER_KEYS:
		var getter: Callable = _readers.get(k)
		if getter == null:
			bad.append("契约键 %s 在探针里没有取值器(新增键必须补断言)" % k)
			continue
		var a: Variant = getter.call(dst)
		var b: Variant = getter.call(src)
		if a != b:
			bad.append("%s: dst=%s src=%s" % [k, str(a), str(b)])
	_chk(bad.is_empty() and fired[0] > 0,
			"① 载荷往返:%d 键全对且 hp_changed 发过 1 次以上(实发 %d)%s" % [
				RewindFrame.PLAYER_KEYS.size(), fired[0],
				"" if bad.is_empty() else " | " + "; ".join(bad)])

	# ── ② 倒地恢复:倒着的时候应用"活着"的帧 ⇒ 起身,且 hp 保持快照值(不许被 revive() 顶满) ──
	dst.combat.downed = true
	var f2: Dictionary = RewindFrame.build_player(src)
	RewindFrame.apply_player(dst, f2)
	await get_tree().process_frame
	_chk(not dst.is_downed() and dst.combat.hp == 3,
			"② 倒地→活着:hp 保持快照值(期望 3,实得 %d;满血 %d 说明走了 revive())" % [
				dst.combat.hp, dst.max_hp])

	if _checks != EXPECTED_CHECKS:
		_check(false, "实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上" % [_checks, EXPECTED_CHECKS])
	_finish()


func _put_weapons(p: Player, idx: int, entry_mags: Array) -> void:
	var inv: WeaponInventory = p.weapons.inventory
	inv.add(1, int(entry_mags[0]))
	inv.add(2, int(entry_mags[1]))
	p.weapons.equip_index(idx)


func _set_live_mag(p: Player, mag: int) -> void:
	var w: WeaponBase = p.weapons.current_weapon()
	if w != null and is_instance_valid(w):
		WeaponComponent.apply_mag(w, mag)


func _mags_of(p: Player) -> String:
	var out: Array = []
	for e in p.weapons.inventory.held:
		out.append(int(e["mag"]))
	return str(out)


func _live_mag_of(p: Player) -> int:
	var w: WeaponBase = p.weapons.current_weapon()
	if w == null or not is_instance_valid(w):
		return -1
	return w.mag_ammo
