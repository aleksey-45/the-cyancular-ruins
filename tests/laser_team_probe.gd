extends Node
# 3v3 激光友伤:队友在光束路径上**不掉血**,而队友**身后**的敌人照常掉血(穿透语义)。
#
# 跑法:`--headless --quit-after 3600 res://tests/laser_team_probe.tscn`
# 判据:文本 `LASER TEAM PROBE: ALL-OK`(**不看退出码** —— 探针挂住时 --quit-after 到期仍 exit 0)。
#
# ★ 这条 bug 能活到今天,是因为既有的 `team_table_probe` ③④ 断的是**子弹与爆炸**,
#   激光不在其中 —— 而激光是即时命中、不走 `_adjudicate_bullets`,而 `same_team` 的调用点
#   全在 `server/`(`match_combat` ×2 / `team_host` ×2;`match_state` 那处是定义)。本探针补这个洞。
#
# ★ 后半条(队友**身后**的敌人照常掉血)是**鉴别点**:只断言"队友不掉血"的话,
#   把整个玩家循环删掉也能过。
#
# ★ 与 `tests/team_host_probe.gd` 同款手法:真建 `TeamHost`(`role_peers` 传空)+ 手工摆位,
#   走的是**生产代码路径**(`_damage_path_targets` 是本特性的被改函数)。

const MAP := "res://maps/factory1v1.cyrm"
const TEAMS := {1: 1, 2: 1, 3: 1, 4: 2, 5: 2, 6: 2}
const COLS := 60
const ROWS := 12
const TILE_WALL := 31
const ROW := 10          # 射手/队友/敌人桩都站这一行(同一 y ⇒ 水平光束必然穿过身体)


# 敌人桩:3v3 场上没有敌人,但"队友身后的东西照常掉血"是穿透语义的**鉴别点**。
# 无碰撞体 ⇒ `_body_rect` 走兜底 36×36、以节点原点为中心(laser_weapon_base.gd:172-177)。
class StubEnemy extends Node2D:
	var hits := 0
	func hurt(_dmg: int, _dir: Vector2, _impact: float) -> void:
		hits += 1


var _host = null
var _shooter: Node2D = null
var _mate: Node2D = null
var _foe: StubEnemy = null
var _fails: Array[String] = []


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  ok  " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


# ★ 必须 `await _run()` 再 `_finish()`:`_run()` 里有 `await get_tree().physics_frame`(协程),
#   同步调 `_finish()` 会在断言跑完**之前**执行 → 所有真断言都 ok 却打出 FAIL(假红)。
func _ready() -> void:
	await _run()
	_finish()


func _finish() -> void:
	if _fails.is_empty():
		print("LASER TEAM PROBE: ALL-OK")
	else:
		print("LASER TEAM PROBE: FAIL —— " + str(_fails))
	get_tree().quit(0 if _fails.is_empty() else 1)


func _place(host, role: int, at: Vector2i) -> Node2D:
	var p: Node2D = preload("res://scenes/player/player.tscn").instantiate()
	p.set_input_source(PacketInputSource.new())
	host.add_child(p)
	p.collision_mask |= 2
	host.players[role] = p
	var ts := GameParameters.TILE_SIZE
	p.global_position = Vector2(at.x * ts + ts * 0.5, at.y * ts + ts * 0.5)
	return p


func _build_grid() -> Array[Array]:
	var grid: Array[Array] = []
	for y in range(ROWS):
		var row: Array[int] = []
		for x in range(COLS):
			row.append(TILE_WALL if y == ROWS - 1 else 0)
		grid.append(row)
	return grid


func _run() -> void:
	seed(20260925)
	# ★ 合成平地网格:**不钉真地图** —— 探针要的是"一条无遮挡的水平光束",不是关卡几何。
	#   先填 `current_grid`,`TeamHost._init` 的 `if grid.is_empty()` 守卫就不会再去读地图。
	MazeGenerator.current_grid = _build_grid()
	TileDefs.load_defs()
	GameParameters.refresh_map_size()
	# spawns 显式传:不传的话 `TeamHost._init` 会调 `plan_team_spawns`(它按真实地图挑格),
	# 在合成网格上是另一份散点,与探针要摆的位置无关 —— 摆了也会被 `_place` 覆盖,但白白多算一次。
	var spawns := {1: Vector2i(5, ROW), 2: Vector2i(9, ROW), 3: Vector2i(30, ROW),
			4: Vector2i(34, ROW), 5: Vector2i(38, ROW), 6: Vector2i(42, ROW)}
	_host = TeamHost.new(MAP, {}, {}, [], spawns, TEAMS)
	add_child(_host)
	# ★★ 合成网格必须在 `TeamHost.new` **之后**重设 —— brief 里那句"先填 `current_grid`,
	#   `TeamHost._init` 的 `if grid.is_empty()` 守卫就不会再去读地图"**不成立**:
	#   那道守卫只在 `TeamHost._init` 自己那一小段,而它随后调的**超类** `MatchHost._init`
	#   (`server/match_host.gd:19-21`)是**无条件** `set_map_file(map_path)` +
	#   `grid = WorldBuilder.load_grid()` ⇒ 合成网格被真实关卡(150×100)覆盖掉。
	#   实测后果:光束在真图里于 x=1664 撞墙反射、折返时**二次**扫过敌人(`hits == 2`),
	#   探针红的**成因**与本特性无关(是几何,不是队伍判定)—— 那就不是一条能验本修的探针。
	MazeGenerator.current_grid = _build_grid()
	# ★ 关掉宿主自己的物理帧:`quit(0)` 是帧末生效,不关的话中间还会跑一帧 `_physics_process`
	#   → 快照广播去读尚未摆位的 `players`,在断言全过之后刷一屏 SCRIPT ERROR
	#   (与 `team_host_probe` / `royale_disconnect_count_probe` 同款理由)。
	_host.set_physics_process(false)
	for role in TEAMS:
		var p: Node2D = _place(_host, role, spawns[role])
		if role == 1:
			_shooter = p
		elif role == 2:
			_mate = p
	_host._apply_team_layers()
	await get_tree().physics_frame
	# ★ 清无敌帧:出生/复活可能带无敌,不清的话"队友不掉血"这条在**修复前也会绿**(假绿)。
	#   修复前的红本身就是"伤害确实打进去了"的证明;这一步是双保险。
	_mate.combat.iframes = 0.0
	_shooter.combat.iframes = 0.0
	# 敌人桩:放在队友**身后**同一行 —— 证明光束是**穿过去**的,而不是停在队友身上。
	# ★ y 取队友身体的 y(与射手同一行 ⇒ 水平光束的高度落在身体框内)。
	_foe = StubEnemy.new()
	_foe.add_to_group("enemies")
	_host.add_child(_foe)
	_foe.global_position = Vector2(14 * GameParameters.TILE_SIZE + 32, _mate.global_position.y)
	# 武器:直接挂到射手身上并 `equip`(同步入树 ⇒ `@onready` 的 muzzle/sprite 立即有效,
	# 不走 `WeaponComponent` 那条 `call_deferred("add_child")` 的路)。
	var laser: WeaponBase = preload("res://scenes/weapons/laser_gun.tscn").instantiate()
	_shooter.add_child(laser)
	laser.equip(_shooter, 0.0)
	await get_tree().physics_frame
	# 瞄准方向走**输入源的覆盖钩子**(`Player.get_aim_dir_override` → `PacketInputSource._aim`):
	# headless 没有鼠标,落回鼠标会得到一个无意义的方向。
	var src := _shooter.input_source as PacketInputSource
	src.clear_edges()
	src.apply_packet({"seq": 1, "ax": 0.0, "held": 0, "pressed": 0, "released": 0,
			"weapon": 0, "aim": Vector2.RIGHT})
	var hp_before := int(_mate.combat.hp)
	laser.try_fire()
	await get_tree().physics_frame
	await get_tree().physics_frame
	_check(_mate.combat.hp == hp_before,
			"队友在光束路径上**不掉血**(受伤前 %d、受伤后 %d)" % [hp_before, int(_mate.combat.hp)])
	_check(_foe.hits == 1,
			"队友**身后**的敌人照常掉血(命中 %d 次)—— 这是'穿透'的鉴别点" % _foe.hits)
