extends Node

const FLY := preload("res://scenes/enemies/enemy_fly_bird.tscn")
const BLACK := preload("res://scenes/enemies/enemy_black_bird.tscn")
const JUMP := preload("res://scenes/enemies/enemy_jump_bird.tscn")

const DT: float = 1.0 / 60.0

# 阶段 4 合成地图网格参数：仅底行为实体墙，其余为空
const COLS := 60
const ROWS := 14
const FLOOR_TOP_Y := float((ROWS - 1) * 64)   # 地面顶部 Y 坐标 (832)
const DROP_X := 40 * 64 + 32                  # 下落测试列位置
const DROP_SPAWN_Y := FLOOR_TOP_Y - 200.0     # 空中初始生成高度
const DROP_VY := 900.0                        # 初始垂直下落速度

# 浮点数比较容差
const EPS := 1e-4
# 落地帧垂直速度判定下限
const MIN_LANDING_VY := 500.0
# 睡眠状态衰减观察帧数
const SLEEP_FRAMES := 100

const S_FINDING_B := 0
const S_DONE := 1

# 阶段 1 状态与形变映射配置表
const STATE_CASES := [
	["FlyBird", FLY, "TAKE_OFF"],
	["FlyBird", FLY, "CHARGE"],
	["BlackBird", BLACK, "TAKE_OFF"],
	["BlackBird", BLACK, "CHARGE"],
	["JumpBird", JUMP, "LUNGE_DASH"],
	["JumpBird", JUMP, "BACK_HOP"],
]

var _stage := -1
var _f := 0
var _total := 0
var _fails: Array[String] = []
var _lines: Array[String] = []

# 阶段 4 状态与读数缓存
var _bird = null                    # 目标敌人实例
var _landing_vy := 0.0              # 落地瞬间记录的 _pre_move_vy
var _first_sleep_x := 1.0           # 首次进入睡眠帧时的 scale.x
var _last_sleep_x := 1.0            # 睡眠窗口结束时的 scale.x
var _sleep_frames := 0


func _ready() -> void:
	GameParameters.MAP_WIDTH = COLS * GameParameters.TILE_SIZE
	GameParameters.MAP_HEIGHT = ROWS * GameParameters.TILE_SIZE
	MazeGenerator.current_grid = _build_grid()
	TileDefs.load_defs()
	var host := Node2D.new()
	host.name = "World"
	add_child(host)
	WorldBuilder.build_sim(host, MazeGenerator.current_grid)
	print("[squash_enemy] 合成世界 %dx%d 格; 底行地面 y=%d; 阶段 4 落点列 x=%d" % [
			COLS, ROWS, int(FLOOR_TOP_Y), DROP_X])
	_probe_events()
	_begin_finding_b()


func _build_grid() -> Array[Array]:
	var ts_wall := 31            # 纹理 1 全砖(墙)
	var grid: Array[Array] = []
	for y in range(ROWS):
		var row: Array[int] = []
		for x in range(COLS):
			row.append(ts_wall if y == ROWS - 1 else 0)
		grid.append(row)
	return grid


# 实例化敌人节点并禁用其自动物理更新，便于手动步进控制
func _mk_enemy(scene: PackedScene):
	var b = scene.instantiate()
	add_child(b)
	b.set_physics_process(false)
	return b


# 获取敌人脚本中的 State 枚举常量表
func _state_of(b) -> Dictionary:
	var scr := b.get_script() as GDScript
	if scr == null:
		return {}
	return scr.get_script_constant_map().get("State", {})


func _physics_process(_delta: float) -> void:
	_total += 1
	if _stage == S_FINDING_B:
		_tick_finding_b()


func _begin(stage: int) -> void:
	_stage = stage
	_f = 0


# 阶段 1、2、3：状态机触发形变、睡眠不触发形变、受击挤压形变测试
func _probe_events() -> void:
	# 阶段 1：起飞、冲刺等动作触发拉伸形变(scale.x < 1.0)
	for c in STATE_CASES:
		var b = _mk_enemy(c[1])
		var label: String = c[0]
		var sname: String = c[2]
		var states := _state_of(b)
		if not states.has(sname):
			_record(false, "阶段 1 前提: %s 包含 State.%s" % [label, sname],
				"当前可用状态: %s" % str(states.keys()))
			b.queue_free()
			continue
		b._set_state(int(states[sname]))
		b.squash.tick(DT, 0.0, true, false)
		var sx := _scale_x(b)
		_record(sx < 1.0, "阶段 1: %s 进入 %s 触发垂直拉伸" % [label, sname],
			"scale.x %.4f(需 < 1.0)" % sx)
		b.queue_free()

	# 验证进入 SLEEP 状态时不应触发拉伸挤压事件
	for c in [["FlyBird", FLY], ["BlackBird", BLACK], ["JumpBird", JUMP]]:
		var b = _mk_enemy(c[1])
		var states := _state_of(b)
		if not states.has("SLEEP"):
			_record(false, "阶段 1 前提: %s 包含 SLEEP 状态" % c[0], str(states.keys()))
			b.queue_free()
			continue
		b._set_state(int(states["SLEEP"]))
		b.squash.tick(DT, 0.0, true, false)
		var sx := _scale_x(b)
		_record(absf(sx - 1.0) <= EPS, "阶段 1: %s 进入 SLEEP 保持中性" % c[0],
			"scale.x %.6f(需 == 1.0)" % sx)
		b.queue_free()

	# 阶段 3：受击触发水平挤压形变(scale.x > 1.0)；死亡状态受击不触发形变
	for c in [["FlyBird", FLY], ["BlackBird", BLACK], ["JumpBird", JUMP]]:
		var b = _mk_enemy(c[1])
		b._apply_hit(1, Vector2.RIGHT)
		b.squash.tick(DT, 0.0, true, false)
		var sx := _scale_x(b)
		_record(sx > 1.0, "阶段 3: %s 受击触发挤压形变" % c[0],
			"scale.x %.4f(需 > 1.0)" % sx)
		b.queue_free()

		var d = _mk_enemy(c[1])
		d.is_dead = true
		d.hurt(1, Vector2.RIGHT)          # 死亡状态调用 hurt 仅处理击退，不触发形变
		d.squash.tick(DT, 0.0, true, false)
		var dsx := _scale_x(d)
		_record(absf(dsx - 1.0) <= EPS, "阶段 3: %s 死亡受击不产生形变" % c[0],
			"scale.x %.6f(需 == 1.0)" % dsx)
		d.queue_free()


func _scale_x(b) -> float:
	var spr := b.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	if spr == null:
		_record(false, "前提检查: 敌人根节点下需存在 AnimatedSprite2D 节点", "未找到节点")
		return 1.0
	return spr.scale.x


# 阶段 4：测试真物理环境下敌人落地进入休眠后的形变衰减与唤醒表现
func _begin_finding_b() -> void:
	_bird = _mk_enemy(BLACK)
	_bird.global_position = Vector2(DROP_X, DROP_SPAWN_Y)
	_bird.velocity = Vector2(0.0, DROP_VY)
	var states := _state_of(_bird)
	if not states.has("SLEEP") or not states.has("TAKE_OFF"):
		print("SQUASH HOST ENEMY PROBE: FAIL | BlackBird 状态定义缺少 SLEEP 或 TAKE_OFF")
		get_tree().quit(1)
		return
	_bird._set_state(int(states["SLEEP"]))
	_landing_vy = 0.0
	_first_sleep_x = 1.0
	_last_sleep_x = 1.0
	_sleep_frames = 0
	_begin(S_FINDING_B)


func _tick_finding_b() -> void:
	if _bird == null or not is_instance_valid(_bird):
		return
	_bird._physics_process(DT)
	_f += 1
	if _landing_vy == 0.0:
		if not _bird.is_on_floor():
			return
		_landing_vy = _bird._pre_move_vy
		return
	_sleep_frames += 1
	if _sleep_frames == 1:
		_first_sleep_x = _scale_x(_bird)
		_record(_bird._is_far_sleeping(), "阶段 4 前提: 落地后进入远处睡眠分支",
			"state=%d on_floor=%s vx=%.2f vy=%.2f dist=%.1f" % [
				_bird.state, str(_bird.is_on_floor()), _bird.velocity.x,
				_bird.velocity.y, _bird.toroidal_dist_to_player()])
		_record(_landing_vy >= MIN_LANDING_VY, "阶段 4 前提: 落地帧记录有效下坠速度",
			"_pre_move_vy = %.1f(需 >= %.1f)" % [
				_landing_vy, MIN_LANDING_VY])
		return
	if _sleep_frames < SLEEP_FRAMES:
		return
	_last_sleep_x = _scale_x(_bird)
	_record(_first_sleep_x > 1.0, "阶段 4: 首个睡眠帧吸收下落速度产生挤压形变",
		"scale.x %.6f(需 > 1.0)" % _first_sleep_x)
	_record(absf(_last_sleep_x - 1.0) <= EPS, "阶段 4: 睡眠 %d 帧后形变衰减恢复中性" % SLEEP_FRAMES,
		"scale.x %.8f(偏差需 <= %s)" % [
			_last_sleep_x, str(EPS)])
	# 唤醒首帧：切换至起飞状态并更新一帧物理
	var states := _state_of(_bird)
	_bird._set_state(int(states["TAKE_OFF"]))
	_bird._physics_process(DT)
	var wake_x := _scale_x(_bird)
	_record(wake_x < 1.0, "阶段 4: 唤醒首帧起飞产生垂直拉伸形变",
		"scale.x %.6f(需 < 1.0)" % wake_x)
	_begin(S_DONE)
	_finish()


func _record(ok: bool, label: String, detail: String) -> void:
	var line := "%s %s —— %s" % ["OK  " if ok else "FAIL", label, detail]
	_lines.append(line)
	print("[squash_enemy] %s" % line)
	if not ok:
		_fails.append("%s(%s)" % [label, detail])


func _finish() -> void:
	if _fails.is_empty():
		print("SQUASH HOST ENEMY PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("SQUASH HOST ENEMY PROBE: FAIL | %d 条: %s" % [_fails.size(), "; ".join(_fails)])
		get_tree().quit(1)
