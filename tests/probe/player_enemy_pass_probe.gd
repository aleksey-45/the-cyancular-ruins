extends Node

# 玩家 ↔ 敌人:不物理互挡 / 无被动贴触伤害 / 伤害只来自冲击攻击。
# 真实例化 player.tscn 与 enemy_jump_bird.tscn;所有读数取自真节点,不读源码文本。
# 能给出的最强保证:去掉「玩家 mask 改动 / 敌人 mask 改动 / 被动伤害删除 / 扑击伤害」任一项,
#   本文件必有一条断言红(2026-11-10 逐项变异实跑过)。
# 测不到:黑鸟/飞鸟冲锋的命中路径、真实地图网格下的手感。

const PLAYER_SCENE := preload("res://scenes/player/player.tscn")
const JUMP_BIRD_SCENE := preload("res://scenes/enemies/enemy_jump_bird.tscn")
const ENEMY_SCENES := [
	"res://scenes/enemies/enemy_black_bird.tscn",
	"res://scenes/enemies/enemy_fly_bird.tscn",
	"res://scenes/enemies/enemy_jump_bird.tscn",
]

const MARKER := "PLAYER ENEMY PASS PROBE: ALL-OK"
const EXPECTED_CHECKS := 7

const TERRAIN_LAYER := 1
const PLAYER_LAYER := 2
const ENEMY_LAYER := 4

var _checks := 0
var _failures: Array[String] = []
var _ran: Dictionary = {}


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if ok:
		print("[pep]   ✓ %s" % msg)
	else:
		_failures.append(msg)
		print("[pep]   ✗ %s" % msg)


func _fail(msg: String) -> void:
	_failures.append(msg)
	print("[pep]   ✗ %s" % msg)


# 假绿防线:运行时错误只结束出错的那个函数,调用方继续、verdict 照打 ALL-OK。
func _require_ran(name: String) -> void:
	if not _ran.has(name):
		_fail("%s 没跑到最后一行(中途报错或被跳过)→ 本趟读数不可信" % name)


func _center() -> Vector2:
	return Vector2(float(GameParameters.MAP_WIDTH) * 0.5, float(GameParameters.MAP_HEIGHT) * 0.5)


# 等足一整步物理:physics_frame 在 _physics_process 之前发,连等两次才跨过一步。
func _step_physics(n: int) -> void:
	for _i in range(n):
		await get_tree().physics_frame
		await get_tree().physics_frame


# 玩家物理关掉(位置固定,便于精确摆位),跳鸟按需由调用方打开。
func _spawn(bird_offset: Vector2) -> Dictionary:
	var p = PLAYER_SCENE.instantiate()
	add_child(p)
	p.set_physics_process(false)
	var bird = JUMP_BIRD_SCENE.instantiate()
	add_child(bird)
	bird.set_physics_process(false)
	p.global_position = _center()
	bird.global_position = p.global_position + bird_offset
	return {"p": p, "bird": bird}


func _free_fixture(f: Dictionary) -> void:
	for n in [f["p"], f["bird"]]:
		if is_instance_valid(n):
			n.free()


func _ready() -> void:
	await _test_pass_through()
	_require_ran("pass")
	await _test_overlap_no_damage()
	_require_ran("overlap")
	await _test_lunge_impact()
	_require_ran("lunge")
	_test_mask_contract()
	_require_ran("masks")
	if _checks != EXPECTED_CHECKS:
		_fail("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	print("[pep] checks = %d (EXPECTED_CHECKS=%d)" % [_checks, EXPECTED_CHECKS])
	if _failures.is_empty():
		print("%s(%d 条断言)" % [MARKER, _checks])
		get_tree().quit(0)
	else:
		print("PLAYER ENEMY PASS PROBE: FAIL")
		for f in _failures:
			print("[pep]   ✗ %s" % f)
		get_tree().quit(1)


# a) 玩家可以穿过敌人:朝敌人方向 test_move 不报碰撞;反证 = 把 mask 换成敌人层就会报。
func _test_pass_through() -> void:
	var f := _spawn(Vector2(120.0, 0.0))
	var p = f["p"]
	await _step_physics(1)
	var motion := Vector2(200.0, 0.0)
	var blocked: bool = p.test_move(p.global_transform, motion)
	p.collision_mask = ENEMY_LAYER
	var control_blocked: bool = p.test_move(p.global_transform, motion)
	p.collision_mask = TERRAIN_LAYER
	_check(not blocked,
			"a) 玩家 mask=1:朝敌人方向 test_move 位移 %.0fpx 不被挡(玩家↔敌人不物理互挡)" % motion.length())
	_check(control_blocked,
			"a 反证:同一段位移把 mask 换成敌人层(%d)后 test_move 报碰撞 → a 不是空转" % ENEMY_LAYER)
	_free_fixture(f)
	_ran["pass"] = true


# b) 玩家与跳鸟重叠静置:无被动贴触伤害 ⇒ hp 不变。
func _test_overlap_no_damage() -> void:
	var f := _spawn(Vector2.ZERO)
	var p = f["p"]
	var bird = f["bird"]
	bird.set_physics_process(true)
	var hp0 := int((p.capture_state() as Dictionary)["hp"])
	await _step_physics(8)
	var hp1 := int((p.capture_state() as Dictionary)["hp"])
	_check(hp1 == hp0,
			"b) 玩家与跳鸟重叠静置 8 物理帧:hp 不变(%d→%d),无被动贴触伤害" % [hp0, hp1])
	_free_fixture(f)
	_ran["overlap"] = true


# c) 跳鸟扑击命中仍是冲击伤害:贴身时置入 LUNGE_DASH 必须扣 hp 并结束扑击。
func _test_lunge_impact() -> void:
	var f := _spawn(Vector2(24.0, 0.0))
	var p = f["p"]
	var bird = f["bird"]
	bird.set_physics_process(true)
	await _step_physics(1)
	var hp0 := int((p.capture_state() as Dictionary)["hp"])
	var raw_dmg = bird.get("impact_damage")
	var dmg := int(raw_dmg) if raw_dmg != null else -1
	bird._set_state(EnemyJumpBird.State.LUNGE_DASH)
	await _step_physics(1)
	var hp1 := int((p.capture_state() as Dictionary)["hp"])
	_check(dmg > 0 and hp1 == hp0 - dmg,
			"c) 扑击命中:hp %d→%d(冲击伤害 impact_damage=%d,穿透无敌帧)" % [hp0, hp1, dmg])
	_check(int(bird.state) == EnemyJumpBird.State.BACK_HOP,
			"c) 扑击命中只结算一次并转 BACK_HOP(state=%d)" % int(bird.state))
	_free_fixture(f)
	_ran["lunge"] = true


# d) 数据契约:玩家 mask 不含玩家/敌人层;三只敌人 mask 含地形+敌人层、不含玩家层。
func _test_mask_contract() -> void:
	var p = PLAYER_SCENE.instantiate()
	var pmask: int = p.collision_mask
	var player_ok := (pmask & TERRAIN_LAYER) != 0 and (pmask & ENEMY_LAYER) == 0 \
			and (pmask & PLAYER_LAYER) == 0
	p.free()
	var bad: Array[String] = []
	for path in ENEMY_SCENES:
		var bird_scene := load(path) as PackedScene
		if bird_scene == null:
			bad.append("%s 加载失败" % path)
			continue
		var bird = bird_scene.instantiate()
		var m: int = bird.collision_mask
		if (m & PLAYER_LAYER) != 0 or (m & TERRAIN_LAYER) == 0 or (m & ENEMY_LAYER) == 0:
			bad.append("%s mask=%d" % [path.get_file(), m])
		bird.free()
	_check(player_ok, "d) 玩家 mask=%d:含地形层、不含玩家/敌人层(只撞地形)" % pmask)
	_check(bad.is_empty(), "d) 三只敌人 mask 均为 地形1|敌人4、不含玩家层(异常: %s)" % str(bad))
	_ran["masks"] = true
