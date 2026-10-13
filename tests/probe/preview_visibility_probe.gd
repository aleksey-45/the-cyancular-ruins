extends Node


const HEAVY_SLOT := "3"   # weapon_component.WEAPONS 的 "3" = m82a1(heavy_aim=true)

var _fail := 0


func _ready() -> void:
	await _check_owner_sees_own_line()
	await _check_replica_never_shows_line()
	await _check_replica_backpedal_pitch()

	if _fail == 0:
		print("PREVIEW VISIBILITY: ALL-OK")
		get_tree().quit(0)
	else:
		print("PREVIEW VISIBILITY: FAIL(%d 条)" % _fail)
		get_tree().quit(1)


# ① 本人:按住 attack -> _aiming=true 且 _laser.visible=true;松开 -> 收回。
func _check_owner_sees_own_line() -> void:
	var lv: Node = (load("res://scenes/level_0.tscn") as PackedScene).instantiate()
	add_child(lv)
	await _frames(8)

	var player: Node = lv.get_node_or_null("WorldViewport/Player")
	if player == null:
		_check(false, "Level0 里找得到 WorldViewport/Player")
		return
	var wep: Node = player.weapons
	# - 同 (a):必须走发放路径。单机开局只发一把手枪(`default_type()`),背包里没有重狙
	#    ->  `equip_type(3)` 自 §4.5 起是 push_error + 不加入  ->  这条探针会拿到手枪,
	#   `槽 %s 是 heavy_aim 武器` 直接红(PREVIEW VISIBILITY: FAIL(1 条))。
	wep.pick_up(int(HEAVY_SLOT), WeaponInventory.MAG_FULL)
	await _frames(4)

	var w: Node = wep.current_weapon()
	_check(w != null and w.heavy_aim, "槽 %s 是 heavy_aim 武器(预瞄武器)" % HEAVY_SLOT)
	if w == null:
		return

	Input.action_press("attack")
	await _frames(4)
	_check(bool(w._aiming) and w._laser != null and w._laser.visible,
			"★ 本人按住开火 → 自己的预瞄红线可见")

	Input.action_release("attack")
	await _frames(4)
	_check(not w._laser.visible, "本人松开开火 → 预瞄红线收回")

	lv.queue_free()
	await _frames(2)


# ② 对手副本:快照 previewing=true -> 副本武器不得画线;previewing=false 同样不得画(负向对照)。
func _check_replica_never_shows_line() -> void:
	var rep: Node2D = (load("res://scenes/player/player_replica.tscn") as PackedScene).instantiate()
	add_child(rep)
	await _frames(4)

	var anchor := Vector2(500.0, 500.0)
	rep.render_snapshot({"pos": Vector2(520.0, 500.0), "vel": Vector2.ZERO, "facing": 1, "aim": Vector2.RIGHT,
			"type_id": int(HEAVY_SLOT), "previewing": true, "hp": 100, "pose": 0, "downed": false},
			anchor)
	await _frames(4)
	rep._drive_weapon_visual()   # 副本每帧由 _process 驱动;显式再推一次,不依赖帧序
	var rw: Node2D = rep._weapon
	_check(rw != null, "副本武器已按快照槽位建出来")
	if rw == null:
		return
	_check(not bool(rw._aiming), "★ 对手副本 previewing=true 时 _aiming 仍为 false")
	_check(rw._laser != null and not rw._laser.visible,
			"★ 对手副本 previewing=true **看不到**你的预瞄红线")

	# 负向对照:previewing=false 也必须不可见(若上面那条是靠"恒不可见"蒙对的,这里会一起过 ——
	# 两条一起才说明是"因为 previewing 不生效",而不是"整条链根本没接通")。
	rep.render_snapshot({"pos": Vector2(520.0, 500.0), "vel": Vector2.ZERO, "facing": 1, "aim": Vector2.RIGHT,
			"type_id": int(HEAVY_SLOT), "previewing": false, "hp": 100, "pose": 0, "downed": false},
			anchor)
	await _frames(4)
	rep._drive_weapon_visual()
	_check(not rw._laser.visible, "对手副本 previewing=false 同样不可见(负向对照)")

	# 反无效操作:副本武器的朝向/枪口旋转仍必须被驱动(不能为了去掉红线把整个外观驱动也删了)。
	rep.render_snapshot({"pos": Vector2(520.0, 500.0), "vel": Vector2.ZERO, "facing": 1, "aim": Vector2(0.0, -1.0),
			"type_id": int(HEAVY_SLOT), "previewing": false, "hp": 100, "pose": 0, "downed": false},
			anchor)
	await _frames(4)
	rep._drive_weapon_visual()
	_check(absf(rw.rotation) > 0.01, "副本枪口仰角仍被照常驱动(只去掉红线,不废外观)")


func _check_replica_backpedal_pitch() -> void:
	var rep: Node2D = (load("res://scenes/player/player_replica.tscn") as PackedScene).instantiate()
	add_child(rep)
	await _frames(4)

	var anchor := Vector2(500.0, 500.0)
	var aim := Vector2(1.0, 0.3)   # 明确指向右侧、略向下
	rep.render_snapshot({"pos": Vector2(520.0, 500.0), "vel": Vector2.ZERO, "facing": -1, "aim": aim,
			"type_id": int(HEAVY_SLOT), "previewing": false, "hp": 100, "pose": 0, "downed": false},
			anchor)
	await _frames(4)
	rep._drive_weapon_visual()
	var rw: Node2D = rep._weapon
	if rw == null:
		_check(false, "副本武器已按快照槽位建出来(倒走用例)")
		return
	var limit := deg_to_rad(float(rw.pitch_clamp_deg))
	_check(rw.rotation > 0.05 and rw.rotation < 0.6,
			"★ 倒走(走路 facing=-1)+ 瞄向右下 → 枪口是瞄向那侧的**小幅下俯**(得 %.3f rad ≈ %.1f°,期望 ≈ +0.292 rad ≈ 16.7°)" % [rw.rotation, rad_to_deg(rw.rotation)])
	_check(absf(absf(rw.rotation) - limit) > 0.05,
			"...且没有被折到 ±pitch_clamp 的极限(%.3f rad,钳制 ±%.3f rad —— 折到极限就是本条要抓的那个 bug)" % [rw.rotation, limit])
	_check(rw.scale.x > 0.0, "枪身横向同样跟瞄准侧(走路朝左不影响枪指向哪边)")
	rep.queue_free()
	await _frames(2)


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  ok  " + what)
	else:
		_fail += 1
		print("  FAIL " + what)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame
