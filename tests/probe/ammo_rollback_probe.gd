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
	TileDefs.load_terrain(_build_grid(), [])
	var host := Node2D.new()
	host.name = "Host"
	add_child(host)
	TileDefs.terrain.attach(host)
	var ts := GameParameters.TILE_SIZE
	P = preload("res://scenes/player/player.tscn").instantiate()
	P.name = "AmmoProbe"
	P.set_input_source(PacketInputSource.new())
	host.add_child(P)
	P.global_position = Vector2(6 * ts + ts * 0.5, 3 * ts + ts * 0.5)
	P.weapons.set_initial_inventory([1])   # 初始配置手枪(type_id 1)
	_check_deferred_weapon_visuals()
	_check_inventory_presentation()
	_check_singleplayer_rewind()
	_check_prediction_pool()
	_run_pre_tree_tick_phase()

func _check_prediction_pool() -> void:
	var pooled: Player = preload("res://scenes/player/player.tscn").instantiate()
	add_child(pooled)
	pooled.enable_manual_simulation()
	pooled.weapons.set_initial_inventory([1, 2])
	var nodes := pooled.weapon_slot.get_child_count()
	var identities: Array = []
	for child in pooled.weapon_slot.get_children(): identities.append(child.get_instance_id())
	for index in 100:
		pooled.weapons.equip_index(index % 2)
		var weapon := pooled.weapons.current_weapon()
		weapon.mag_ammo = 1
		weapon._reloading = true
		weapon._reload_t = 0.25
		weapon.fire_cd_timer = 0.4
		var state: Dictionary = pooled.capture_state()
		pooled.weapons.equip_index((index + 1) % 2)
		pooled.restore_state(state)
		_check(pooled.capture_state() == state, "复用武器后仍须精确恢复弹药、冷却及换弹状态")
	var restored: Array = []
	for child in pooled.weapon_slot.get_children():
		restored.append(child.get_instance_id())
		_check(not child.visible and not child.is_queued_for_deletion(), "模拟切枪不改变武器显示或延迟销毁节点")
	_check(pooled.weapon_slot.get_child_count() == nodes and restored == identities,
		"一百次切枪和恢复不应创建、替换武器节点")
	var final_state: Dictionary = pooled.capture_state()
	pooled.weapons.present()
	_check(pooled.weapons.current_weapon().visible and pooled.capture_state() == final_state,
		"表现阶段显示最终武器且不改写模拟状态")
	pooled.free()

func _check_deferred_weapon_visuals() -> void:
	var weapon: WeaponBase = P.weapons.current_weapon()
	_check(Player.expand_prediction_state(P.capture_prediction_state()) == P.capture_state(true),
		"紧凑预测历史必须逐字段保留完整可恢复状态")
	_check(weapon._laser == null and weapon._explosion_marker == null,
		"模拟装配不应创建瞄准显示资源")
	weapon._update_laser()
	_check(weapon._laser == null and weapon._explosion_marker == null,
		"未瞄准的表现更新无需分配预瞄节点")
	weapon._aiming = true
	var state: Dictionary = P.capture_state()
	weapon._update_laser()
	_check(weapon._laser != null and weapon._explosion_marker != null and weapon._laser.visible,
		"首次瞄准时创建并显示预瞄资源")
	_check(P.capture_state() == state, "预瞄资源创建不能改变可回滚的模拟状态")
	var laser: Line2D = weapon._laser
	weapon._aiming = false
	weapon._update_laser()
	_check(weapon._laser == laser and not laser.visible,
		"退出瞄准时隐藏并复用已有资源")

func _check_singleplayer_rewind() -> void:
	var rewind := WorldRewind.new(P.get_parent())
	P.weapons.set_initial_inventory([1, 2])
	P.weapons.inventory.held[1]["mag"] = 4
	var weapon: WeaponBase = P.weapons.current_weapon()
	weapon.mag_ammo = 3
	weapon._reloading = true
	weapon._reload_t = 0.25
	weapon.fire_cd_timer = 0.4
	rewind.record(1.0 / TimeParams.SNAP_HZ, P, [], [])
	var first: Dictionary = rewind._frames[-1]
	P.weapons.equip_index(1)
	P.weapons.current_weapon().mag_ammo = 1
	rewind._apply(first, P)
	_check(P.weapons.inventory.held[1]["mag"] == 4,
		"单人回溯切枪不得用离手弹量覆盖快照")
	_check(P.weapons.current_inst() == first["player"]["winst"] and P.weapons.current_weapon().mag_ammo == 3,
		"单人复用多人快照，按实例 ID 恢复装备及实际弹量")
	weapon = P.weapons.current_weapon()
	_check(weapon._reloading and is_equal_approx(weapon._reload_t, 0.25) and is_equal_approx(weapon.fire_cd_timer, 0.4),
		"共享恢复入口同时恢复换弹状态、进度和开火冷却")
	weapon._reloading = false
	weapon.mag_ammo = weapon.mag_size
	rewind.record(1.0 / TimeParams.SNAP_HZ, P, [], [])
	weapon.mag_ammo = 0
	rewind._apply(rewind._frames[-1], P)
	_check(P.weapons.current_weapon().mag_ammo == P.weapons.current_weapon().mag_size,
		"共同快照恢复满弹夹")
	P.weapons.current_weapon().mag_ammo = 0
	rewind.record(1.0 / TimeParams.SNAP_HZ, P, [], [])
	P.weapons.current_weapon().mag_ammo = 1
	rewind._apply(rewind._frames[-1], P)
	_check(P.weapons.current_weapon().mag_ammo == 0, "空弹夹快照不能恢复成满弹")
	_check(first["player"]["inv"][0]["mag"] == 3 and first["player"]["inv"][1]["mag"] == 4,
		"共享的只读历史背包不能被后续开火或恢复改写")
	P.weapons.set_initial_inventory([])
	_check(Player.expand_prediction_state(P.capture_prediction_state()) == P.capture_state(true),
		"空手紧凑历史不能残留上一把武器的状态")
	rewind.record(1.0 / TimeParams.SNAP_HZ, P, [], [])
	P.weapons.set_initial_inventory([1])
	rewind._apply(rewind._frames[-1], P)
	_check(P.weapons.inventory.held.is_empty() and P.weapons.current_weapon() == null,
		"空手历史必须卸下后来拿到的武器，不能留下当前装备")
	var template: BulletBase = preload("res://scenes/weapons/grenade_bullet.tscn").instantiate()
	template.position = P.position
	template.velocity_vec = Vector2(10, -20)
	template.max_range = 100000.0  # 回放对象会短暂入树，不能用默认零射程触发测试外自爆。
	var bullet := {"id": 101, "sp": "res://scenes/weapons/grenade_bullet.tscn",
		"from_player": true, "state": template.rewind_state()}
	template.free()
	rewind._apply_bullets([bullet], P)
	var replay = rewind.replay_bullets()[0]
	bullet["state"]["vel"] = Vector2(-30, 40)
	rewind._apply_bullets([bullet], P)
	_check(rewind.replay_bullets()[0] == replay and replay.velocity_vec == bullet["state"]["vel"],
		"复用回放弹时必须恢复出口帧速度")
	_check(is_equal_approx(replay.rotation, replay.velocity_vec.angle()), "公共接口同步恢复弹丸朝向")
	var enemy: EnemyBullet = preload("res://scenes/enemies/enemy_bullet.tscn").instantiate()
	enemy.damage = 17
	enemy.water_mult = 2.5
	enemy.velocity_vec = Vector2(100, 50)
	enemy.max_range = 100000.0
	var other := {"id": 102, "sp": "res://scenes/enemies/enemy_bullet.tscn",
		"from_player": false, "state": enemy.rewind_state()}
	enemy.free()
	rewind._apply_bullets([other, bullet], P)
	_check(rewind._replay_bullets[101] == replay and rewind._replay_bullets[102] is EnemyBullet,
		"快照顺序变化不能按下标串用不同弹丸")
	_check(rewind._replay_bullets[102].damage == 17 and rewind._replay_bullets[102].water_mult == 2.5,
		"敌方弹丸的扩展状态仍由同一接口恢复")
	rewind.record(1.0 / TimeParams.SNAP_HZ, P, [], rewind.replay_bullets())
	_check(rewind._frames[-1]["bullets"].any(func(meta: Dictionary) -> bool: return meta["id"] == 101),
		"重建后再次录制应保留原历史 ID")
	rewind._apply_bullets([], P)
	_check(rewind.replay_bullets().is_empty() and replay.is_queued_for_deletion(),
		"目标帧尚未出生的单人回放弹必须回收，不能留下隐形活弹")
	rewind._apply_bullets([bullet], P)
	_check(rewind.replay_bullets().size() == 1 and rewind.replay_bullets()[0] != replay,
		"单人允许按目标历史帧重新创建缺失弹丸")
	rewind._apply_bullets([], P)
	P.weapons.set_initial_inventory([1])

func _check_inventory_presentation() -> void:
	var hud := Hud.new()
	add_child(hud)
	P.weapons.present()
	var box := hud._weapon_box.get_child(0)
	var state: Dictionary = P.capture_state()
	for i in 60:
		P.restore_state(state)
		P.weapons.present()
	_check(hud._weapon_box.get_child(0) == box, "相同权威背包不能反复重建 HUD")
	state["mag"] -= 1
	state["inv"][0]["mag"] -= 1
	P.restore_state(state)
	P.weapons.present()
	_check(hud._weapon_box.get_child(0) == box, "弹药变化直接刷新数字，不重建武器栏")
	P.weapons.set_initial_inventory([1, 2])
	P.weapons.present()
	_check(hud._weapon_box.get_child_count() == 3, "背包增加武器应刷新列表")
	P.weapons.equip_index(1)
	P.weapons.present()
	_check(hud._weapon_name.text == WeaponRegistry.name_of(2), "切枪后 HUD 名称应更新")
	P.weapons.set_initial_inventory([1])
	P.weapons.present()
	hud.queue_free()


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
			"状态恢复后同帧开火失败: 期望 %d，实得 %d; cd=%s reload=%s down=%s lock=%s hp=%s" % [
				_expected, got, w.fire_cd_timer, w._reloading, P.is_downed(), P._controls_locked, P.hp])
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
