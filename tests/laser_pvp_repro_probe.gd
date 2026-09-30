extends Node

# ═══ 激光 PvP「无伤害」复现探针(排查 1v1 激光枪无伤害)═══
#
# 跑法(场景模式,autoload 必须在):
#   "$GODOT" --headless --path . res://tests/laser_pvp_repro_probe.tscn
# 判据:末行 `LASER REPRO: ALL-OK`。
#
# ═══ 它验什么 ═══
# 服务端权威 sim 的激光结算链(LaserWeaponBase._spawn_projectiles → _damage_path_targets
# → take_hit),在与**专用服务端进程相同的前提**下跑:Level0.pvp_mode=false、
# PacketInputSource 网络驱动玩家、合成平地网格、WorldBuilder 碰撞。
# 两分支:
#   ① pvp_mode=false(= 服务端形态):A 持激光(第 6 槽)朝 B 连打 → B 的 hp **必须下降**。
#   ② pvp_mode=true(= 客户端形态):同款输入 → B 的 hp **必须不变**(视觉副本不裁决,回归门)。
# ①红 = 服务端权威激光真的打不出伤害(与实机 1v1 症状同源,且与本网络层无关,可就地二分);
# ①绿 = 服务端路径无辜,问题在真链路层(会话/输入传输/背包同步),换 e2e 手段追。

const BIT_ATTACK := 8   # PacketInputSource.BIT_ATTACK

const COLS := 60
const ROWS := 14
const FIRE_FROM := 30   # 第几 tick 开始开火
const FIRE_TO := 150    # 第几 tick 结算并切换/收尾

var A = null
var B = null
var _tick := 0
var _phase := 0         # 0 = pvp_mode=false;1 = pvp_mode=true
var _hp0 := -1
var _fails := 0


func _ready() -> void:
	print("═══ LASER REPRO(激光 PvP 权威复现)═══")
	_start_phase(0)


func _start_phase(phase: int) -> void:
	_phase = phase
	Level0.pvp_mode = (phase == 1)
	for c in get_children():
		c.queue_free()
	GameParameters.MAP_WIDTH = COLS * GameParameters.TILE_SIZE
	GameParameters.MAP_HEIGHT = ROWS * GameParameters.TILE_SIZE
	MazeGenerator.current_grid = _build_grid()
	TileDefs.load_defs()
	var host := Node2D.new()
	add_child(host)
	WorldBuilder.build_sim(host, MazeGenerator.current_grid)
	var ts := GameParameters.TILE_SIZE
	var pa := Vector2(6 * ts + ts * 0.5, (ROWS - 2) * ts + ts * 0.5)
	var pb := pa + Vector2(6 * ts, 0)   # 384px 右侧,同高、平地无遮挡
	A = _make_player(host, "Shooter", pa)
	B = _make_player(host, "Target", pb)
	A.weapons.set_initial_inventory([6])   # 激光枪 = 第 6 槽
	B.weapons.set_initial_inventory([])
	_hp0 = -1
	_tick = 0
	print("  分支 %d:pvp_mode=%s | A@%s B@%s" % [phase, Level0.pvp_mode, pa, pb])


func _make_player(host: Node2D, nm: String, pos: Vector2):
	var p = preload("res://scenes/player/player.tscn").instantiate()
	p.name = nm
	var src := PacketInputSource.new()
	p.set_input_source(src)
	host.add_child(p)
	p.global_position = pos
	return p


func _build_grid() -> Array[Array]:
	var ts_wall := 31   # texture1 全砖(墙)
	var grid: Array[Array] = []
	for y in range(ROWS):
		var row: Array[int] = []
		for x in range(COLS):
			row.append(ts_wall if y == ROWS - 1 else 0)
		grid.append(row)
	return grid


func _physics_process(_d: float) -> void:
	_tick += 1
	var src := A.input_source as PacketInputSource
	var held := 0
	var pressed := 0
	if _tick >= FIRE_FROM:
		held = BIT_ATTACK
		if (_tick % 20) == 0:
			pressed = BIT_ATTACK   # 补按下边沿:半自动/按边沿开火的武器也能打
	src.apply_packet({"seq": _tick, "ax": 0.0, "held": held, "pressed": pressed,
			"released": 0, "weapon": 0, "aim": Vector2(1.0, 0.0)})
	if _tick == FIRE_FROM - 1:
		var w = A.weapons.current_weapon()
		print("  A 当前武器 = %s(mag=%s)" % [w, str(w.mag_ammo) if w != null else "?"])
		_hp0 = B.combat.hp
	if _tick == FIRE_TO:
		var hp1: int = B.combat.hp
		var ok: bool
		var what: String
		if _phase == 0:
			ok = hp1 < _hp0
			what = "pvp_mode=false(服务端形态): 激光应造成伤害 hp %d → %d" % [_hp0, hp1]
		else:
			ok = hp1 == _hp0
			what = "pvp_mode=true(客户端形态): 激光应无伤害 hp %d → %d" % [_hp0, hp1]
		print(("  [OK] " if ok else "  [FAIL] ") + what)
		if not ok:
			_fails += 1
		if _phase == 0:
			_start_phase(1)
		else:
			_finish()


func _finish() -> void:
	print("LASER REPRO: %s" % ("ALL-OK" if _fails == 0 else "FAILED(%d)" % _fails))
	get_tree().quit(0 if _fails == 0 else 1)
