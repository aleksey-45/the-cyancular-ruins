extends Node

const COLS := 24
const ROWS := 10
const TILE_WALL := 31      # 纹理 1 全砖(墙)
const WARMUP := 30
const MAG_START := 4
const SETTLE := 3          # 开火后等待若干帧供状态刷新

var P = null
var _tick := 0
var _fired_at := -1
var _expected := -1
var _checks := 0
var _fail := ""
var _done := false


func _ready() -> void:
	GameParameters.MAP_WIDTH = COLS * GameParameters.TILE_SIZE
	GameParameters.MAP_HEIGHT = ROWS * GameParameters.TILE_SIZE
	MazeGenerator.current_grid = _build_grid()
	TileDefs.load_defs()
	var host := Node2D.new()
	host.name = "Host"
	add_child(host)
	WorldBuilder.build_sim(host, MazeGenerator.current_grid)
	var ts := GameParameters.TILE_SIZE
	P = preload("res://scenes/player/player.tscn").instantiate()
	P.name = "AmmoProbe"
	P.set_input_source(PacketInputSource.new())
	host.add_child(P)
	P.global_position = Vector2(6 * ts + ts * 0.5, 3 * ts + ts * 0.5)
	P.weapons.set_initial_inventory([1])   # 初始配置手枪(type_id 1)
	_run_pre_tree_tick_phase()


func _build_grid() -> Array[Array]:
	var grid: Array[Array] = []
	for y in range(ROWS):
		var row: Array[int] = []
		for x in range(COLS):
			row.append(TILE_WALL if y == ROWS - 1 else 0)
		grid.append(row)
	return grid


func _physics_process(_delta: float) -> void:
	if P == null or _done:
		return
	# 断言失败时立即结算结果并退出，避免继续空转导致探针超时
	if not _fail.is_empty():
		_finish()
		return
	_tick += 1
	# 超时保护：若超过最大等待帧数仍未完成，判定为超时失败
	if _tick > WARMUP + 120:
		_check(false, "探针超时: 等待 %d 帧仍未完成判定(武器未就绪或开火受阻)" % _tick)
		_finish()
		return
	var w = P.weapons.current_weapon()
	if _fired_at < 0:
		if _tick < WARMUP or w == null or not w.is_inside_tree():
			return        # 武器由 call_deferred 挂载至场景树，未就绪前继续等待
		w.mag_ammo = MAG_START
		_check(int(w.mag_ammo) == MAG_START,
			"置残弹失败: 写 %d、读回 %d(武器未就绪时写入会被 _ready 覆盖)" % [MAG_START, int(w.mag_ammo)])
		P.weapons.reset_mag_state()   # 同步当前手持弹药至背包数据
		_check(int(P.weapons.inventory.held[P.weapons._current_index]["mag"]) == MAG_START,
			"背包弹药状态同步失败")
		if not _fail.is_empty():
			return
		P.restore_state(P.capture_state())
		_apply_attack()
		_fired_at = _tick
		_expected = MAG_START - 1
		return
	# 清除输入边沿，避免重复触发开火
	(P.input_source as PacketInputSource).clear_edges()
	if _tick >= _fired_at + SETTLE:
		var got := int(w.mag_ammo) if w != null else -99
		_check(got == _expected,
			"弹数被帧末写回覆盖: 状态恢复后同帧开火，期望 %d，实得 %d" % [_expected, got])
		_finish()


func _apply_attack() -> void:
	var src := P.input_source as PacketInputSource
	src.clear_edges()
	src.apply_packet({
		"seq": _tick, "ax": 0.0,
		"held": PacketInputSource.BIT_ATTACK,
		"pressed": PacketInputSource.BIT_ATTACK,
		"released": 0,
		"winst": 0,
		"aim": Vector2(1.0, 0.0),
	})


func _run_pre_tree_tick_phase() -> void:
	var scene: PackedScene = load(WeaponRegistry.scene_of(1))
	if scene == null:
		_check(false, "阶段 2 加载手枪场景失败(WeaponRegistry.scene_of(1) 返回空路径)")
		return
	var w: WeaponBase = scene.instantiate()
	# 先调用 equip 初始化玩家引用，暂不挂载至场景树以测试边界窗口
	w.equip(P, 0.0)
	w._reloading = false           # 模拟 _apply_weapon_state 写入的权威值
	_check(not w.is_inside_tree(),
			"阶段 2 前提: 武器未加入场景树")
	_check(int(w.mag_ammo) == 0,
			"阶段 2 前提: 未加入场景树时 mag_ammo 保持默认初值 0(实得 %d)"
			% int(w.mag_ammo))
	_apply_attack()                # 模拟开火输入
	w.tick(1.0 / 60.0)
	_check(not w.is_reloading(),
			"未加入场景树时调用 tick() 导致 _reloading 被错误置为 true")
	# 验证未加入场景树时 tick() 不得修改弹夹内弹药数量
	_check(int(w.mag_ammo) == 0,
			"未加入场景树时调用 tick() 修改了 mag_ammo(实得 %d，应为初值 0)" % int(w.mag_ammo))
	# 验证未加入场景树时冷却计时器仍正常递减，确保时间步进逻辑不依赖场景树状态
	w.fire_cd_timer = 0.5
	w.tick(1.0 / 60.0)
	_check(absf(w.fire_cd_timer - (0.5 - 1.0 / 60.0)) < 0.0001,
			"未加入场景树时 tick() 冷却计时器未递减(期望 %.4f，实得 %.4f)"
			% [0.5 - 1.0 / 60.0, w.fire_cd_timer])
	w.free()                       # 释放未挂载节点
	# 清除输入状态，避免影响后续测试阶段
	(P.input_source as PacketInputSource).reset_state()

	var w2: WeaponBase = scene.instantiate()
	w2.equip(P, 0.0)
	add_child(w2)                  # 挂载至场景树触发 _ready 初始化
	_check(w2._mag_ready,
			"对照检查: 挂载后 _mag_ready 应置为 true")
	w2.mag_ammo = 0                # 手动清空弹药
	_apply_attack()
	w2.tick(1.0 / 60.0)
	_check(w2.is_reloading(),
			"挂载至场景树后空弹夹开火应正常触发换弹")
	(P.input_source as PacketInputSource).reset_state()
	# 保留 w2 节点挂载至测试结束，避免提前释放导致延迟初始化的子节点泄漏

	# 阶段 2c: 武器未加入场景树时调用 start_reload() 应直接忽略，不影响权威重装状态
	var w3: WeaponBase = scene.instantiate()
	w3.equip(P, 0.0)
	w3._reloading = false
	_check(not w3.is_inside_tree(),
			"阶段 2c 前提: 武器未挂载至场景树")
	_check(int(w3.mag_ammo) == 0,
			"阶段 2c 前提: 未挂载时 mag_ammo 保持默认初值 0(实得 %d)"
			% int(w3.mag_ammo))
	w3.start_reload()              # 直接调用换弹接口
	_check(not w3.is_reloading(),
			"未挂载至场景树时调用 start_reload() 必须忽略，不应将 _reloading 置为 true")
	w3.free()                      # 释放未挂载节点


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok and _fail.is_empty():
		_fail = msg


func _finish() -> void:
	if _done:
		return    # 退出防重入
	_done = true
	if _fail.is_empty():
		print("AMMO ROLLBACK PROBE: ALL-OK(%d 条断言)" % _checks)
		get_tree().quit(0)
	else:
		print("AMMO ROLLBACK PROBE: FAIL —— %s" % _fail)
		get_tree().quit(1)
