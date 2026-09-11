extends Node

# 预瞄红线可见性回归(**只有使用者本人可见**)。
# 背景:heavy_aim 武器(重狙 M82A1 / 榴弹)按住开火会画一条红色预瞄线(Line2D, laser_color)。
# 原行为:本人看得到,**对手副本也看得到**(副本武器的 _aiming 被 drive_remote_visual 置 true)
#        → 你在 PvP 里蓄力重狙时,对面能提前看见你的预瞄线。
# 现行为(用户裁定 2026-09-11):预瞄线**只对使用者本人可见**,对手/其他玩家看不到。
#
# 两条断言缺一不可 —— 只测一条会漏掉一半的回归:
#   ① 本人持 heavy_aim 武器按住开火 → 自己的红线**必须出现**
#      (防"删对手那条时顺手把本人这条也删了";本地可见性经探针实测是本来就好的一侧)
#   ② 对手副本收到 previewing=true 的快照 → 副本武器**不得**画出红线
#      (这条是本改动的主目标;改动前它是红的)
# 另附一条负向对照:副本在 previewing=false 时同样不可见(防止断言恒真)。
#
# 跑法: "$GODOT" --headless --path . --quit-after 900 res://tests/preview_visibility_probe.tscn

const HEAVY_SLOT := "3"   # weapon_component.WEAPONS 的 "3" = m82a1(heavy_aim=true)

var _fail := 0


func _ready() -> void:
	await _check_owner_sees_own_line()
	await _check_replica_never_shows_line()

	if _fail == 0:
		print("PREVIEW VISIBILITY: ALL-OK")
		get_tree().quit(0)
	else:
		print("PREVIEW VISIBILITY: FAIL(%d 条)" % _fail)
		get_tree().quit(1)


# ① 本人:按住 attack → _aiming=true 且 _laser.visible=true;松开 → 收回。
func _check_owner_sees_own_line() -> void:
	var lv: Node = (load("res://scenes/Level0.tscn") as PackedScene).instantiate()
	add_child(lv)
	await _frames(8)

	var player: Node = lv.get_node_or_null("WorldViewport/Player")
	if player == null:
		_check(false, "Level0 里找得到 WorldViewport/Player")
		return
	var wep: Node = player.weapons
	wep.equip(HEAVY_SLOT)
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


# ② 对手副本:快照 previewing=true → 副本武器不得画线;previewing=false 同样不得画(负向对照)。
func _check_replica_never_shows_line() -> void:
	var rep: Node2D = (load("res://scenes/player/player_replica.tscn") as PackedScene).instantiate()
	add_child(rep)
	await _frames(4)

	var anchor := Vector2(500.0, 500.0)
	rep.apply_snapshot({"pos": Vector2(520.0, 500.0), "facing": 1, "aim": Vector2.RIGHT,
			"weapon": int(HEAVY_SLOT), "previewing": true, "hp": 100, "pose": 0, "downed": false},
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
			"weapon": int(HEAVY_SLOT), "previewing": false, "hp": 100, "pose": 0, "downed": false},
			anchor, 2)
	await _frames(4)
	rep._drive_weapon_visual()
	_check(not rw._laser.visible, "对手副本 previewing=false 同样不可见(负向对照)")

	# 反空转:副本武器的朝向/枪口旋转**仍必须被驱动**(不能为了去掉红线把整个外观驱动也删了)。
	rep.apply_snapshot({"pos": Vector2(520.0, 500.0), "facing": 1, "aim": Vector2(0.0, -1.0),
			"weapon": int(HEAVY_SLOT), "previewing": false, "hp": 100, "pose": 0, "downed": false},
			anchor, 3)
	await _frames(4)
	rep._drive_weapon_visual()
	_check(absf(rw.rotation) > 0.01, "副本枪口仰角仍被照常驱动(只去掉红线,不废外观)")


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  ok  " + what)
	else:
		_fail += 1
		print("  FAIL " + what)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame
