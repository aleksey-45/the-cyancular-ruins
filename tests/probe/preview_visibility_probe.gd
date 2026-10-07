extends Node

# 预瞄红线可见性回归(只有使用者本人可见)。
# 背景:heavy_aim 武器(重狙 M82A1 / 榴弹)按住开火会画一条红色预瞄线(Line2D, laser_color)。
# 原行为:本人看得到,对手副本也看得到(副本武器的 _aiming 被 drive_remote_visual 置 true)
# -> 你在 PvP 里蓄力重狙时,对面能提前看见你的预瞄线。
# 现行为(设计约定 2026-09-11):预瞄线只对使用者本人可见,对手/其他玩家看不到。
#
# 两条断言缺一不可 —— 只测一条会漏掉一半的回归:
#   ① 本人持 heavy_aim 武器按住开火 -> 自己的红线必须出现
#      (防"删对手那条时随意将本人这条也删了";本地可见性经探针实测是本来就好的一侧)
#   ② 对手副本收到 previewing=true 的快照 -> 副本武器不得画出红线
#      （本条为改动核心目标，用于防止对手提前获知瞄准轨迹）
# 另附一条负向对照:副本在 previewing=false 时同样不可见(防止断言始终为 true)。
#
#   - 配置充足的超时保护帧数(3600 帧):探针正常跑完会自己 quit(),这个值只在探针阻塞挂起时才用得上 ——
#     适当放宽超时保护可避免环境负载波动引发误报。原先的 600/900 在机器负载重时可能先耗尽、探针来不及跑完
#     就被意外中断(表现为"一行 ALL-OK 都没有",看着像功能坏了)。
# 运行方式： "$GODOT" --headless --path . --quit-after 3600 res://tests/probe/preview_visibility_probe.tscn

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
	rep.apply_snapshot({"pos": Vector2(520.0, 500.0), "facing": 1, "aim": Vector2.RIGHT,
			"type_id": int(HEAVY_SLOT), "previewing": true, "hp": 100, "pose": 0, "downed": false},
			anchor, 1)
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
	rep.apply_snapshot({"pos": Vector2(520.0, 500.0), "facing": 1, "aim": Vector2.RIGHT,
			"type_id": int(HEAVY_SLOT), "previewing": false, "hp": 100, "pose": 0, "downed": false},
			anchor, 2)
	await _frames(4)
	rep._drive_weapon_visual()
	_check(not rw._laser.visible, "对手副本 previewing=false 同样不可见(负向对照)")

	# 反无效操作:副本武器的朝向/枪口旋转仍必须被驱动(不能为了去掉红线把整个外观驱动也删了)。
	rep.apply_snapshot({"pos": Vector2(520.0, 500.0), "facing": 1, "aim": Vector2(0.0, -1.0),
			"type_id": int(HEAVY_SLOT), "previewing": false, "hp": 100, "pose": 0, "downed": false},
			anchor, 3)
	await _frames(4)
	rep._drive_weapon_visual()
	_check(absf(rw.rotation) > 0.01, "副本枪口仰角仍被照常驱动(只去掉红线,不废外观)")


# ③ -  往回走时对手枪口不得翘起(2026-09-21 用户报:"A 往回走的时候,在 B 眼里枪还会翘起来")。
# 成因:快照的 `facing` 是走路朝向(player.gd 的 facing_direction,移动代码排在 weapons.tick
# 之后、每帧覆盖 _auto_aim 写入的瞄准侧),而副本此前把它同时传入「身体翻转」与
# 「枪口俯仰钳制」。钳制在朝向折叠后的坐标系里算(clamp_pitch 先 `dir.x * facing`):
# 走路朝左而瞄向右时 local=(-1, 0.3) -> 163° -> 钳到 +65° -> 再 `× -1`  ->  -65° 上翘。
# 本体不受影响:它的枪用 _auto_aim 自己算出的瞄准侧(_aim_facing,不读被走路覆盖的 get_facing())。
# 期望值 = 按瞄准侧折叠后的小幅俯仰:atan2(0.3, 1) ≈ +16.7°(m82a1 的钳制是 65°,远未到限)。
# 判定条件只看符号与量级(不钉精确浮点),且额外来一条"没被折到钳制极限"的断言。
func _check_replica_backpedal_pitch() -> void:
	var rep: Node2D = (load("res://scenes/player/player_replica.tscn") as PackedScene).instantiate()
	add_child(rep)
	await _frames(4)

	var anchor := Vector2(500.0, 500.0)
	var aim := Vector2(1.0, 0.3)   # 明确指向右侧、略向下
	rep.apply_snapshot({"pos": Vector2(520.0, 500.0), "facing": -1, "aim": aim,
			"type_id": int(HEAVY_SLOT), "previewing": false, "hp": 100, "pose": 0, "downed": false},
			anchor, 1)
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
