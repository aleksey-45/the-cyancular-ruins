extends Node

# 榴弹「直接命中玩家」权威路径探针(场景模式):钉 `MatchHost._adjudicate_grenade`。
# 跑法:
#   "$GODOT" --headless --path . res://tests/grenade_player_hit_probe.tscn
# 期望:每条 [gren] … 通过,末行 "GRENADE PLAYER HIT PROBE: ALL-OK"。
#
# 为什么单开一个:-s 冒烟(`grenade_smoke.gd`)能测引信那一侧(BulletBase._check_player_contact),
# 但**测不到权威直接伤** —— 那条在 MatchHost 上,要一整局服务器环境。而它恰恰是本功能的
# 另一半(碰到人掉 5 血 + 击杀归因 + 射手端 X 标记),漏测就等于"改了个没人验的路径"。
# 大乱斗压力跑的 `受击 5 伤` 事件与它一致,但那是概率性的,不能当断言。
#
# 做法:真建一个 MatchHost(真地图 + 真 WorldBuilder 碰撞),但 **role_peers 传空** ——
# 于是不建玩家、不排 peer、所有 rpc_id 都无对象(notify_direct_hit 因此静默早退,
# 不会在无多人连接时尝试发包报错)。玩家由本探针自己摆进 host.players,可控且确定。
#
# ⚠ 判据 grep 文本 "GRENADE PLAYER HIT PROBE: ALL-OK"(不只看退出码)。

const MAP := "res://maps/factory1v1.cyrm"

var _failures: Array[String] = []
var _host: Node = null
var _p1: Node2D = null   # 射手
var _p2: Node2D = null   # 受害者


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("[gren]   ✓ %s" % msg)
	else:
		_failures.append(msg)
		print("[gren]   ✗ %s" % msg)


func _ready() -> void:
	_host = MatchHost.new(MAP, {})   # 空 role_peers:不建玩家、不排 peer
	add_child(_host)
	# 关掉服务器每帧编排,只手动调被测函数(否则 COUNTDOWN/复活/快照会来搅局)
	_host.set_physics_process(false)
	_p1 = _make_player(1, Vector2i(17, 65))
	_p2 = _make_player(2, Vector2i(133, 64))
	print("[gren] MatchHost 就绪,射手 %s / 受害者 %s(相距 %d px)" % [
			str(_p1.global_position), str(_p2.global_position),
			int(_p1.global_position.distance_to(_p2.global_position))])

	_test_direct_hit()
	_test_idempotent()
	_test_shooter_excluded()
	_test_out_of_range()

	if _failures.is_empty():
		print("GRENADE PLAYER HIT PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("GRENADE PLAYER HIT PROBE: FAIL %s" % str(_failures))
		get_tree().quit(1)


func _test_direct_hit() -> void:
	var b = _make_grenade(_p1)
	b.global_position = _p2.global_position
	var hp0: int = _p2.hp
	_host._adjudicate_grenade(b)
	_check(_p2.hp == hp0 - int(b.direct_hit_damage),
			"直接命中扣 direct_hit_damage(%d → %d,期望 %d)" % [hp0, _p2.hp, hp0 - int(b.direct_hit_damage)])
	_check(is_instance_valid(b), "★ 子弹**未销毁**(销毁会把引信吞掉、爆炸永不触发)")
	_check(b.has_meta("grenade_direct_hit"), "置了一次性闩 meta(榴弹会连续穿过判定圈好几帧)")
	# 击杀归因:大乱斗靠读受害者 meta 的 last_damager 计分(RoyaleHost._attributed_killer)
	_check(_p2.has_meta("last_damager") and _p2.get_meta("last_damager") == _p1,
			"归因写到了射手身上(大乱斗击杀计分读它)")
	b.free()


func _test_idempotent() -> void:
	var b = _make_grenade(_p1)
	b.global_position = _p2.global_position
	_host._adjudicate_grenade(b)
	var hp_after_first: int = _p2.hp
	_host._adjudicate_grenade(b)
	_host._adjudicate_grenade(b)
	_check(_p2.hp == hp_after_first, "同一颗榴弹只结算一次(再调两次血量不变:%d)" % _p2.hp)
	b.free()


func _test_shooter_excluded() -> void:
	var b = _make_grenade(_p1)
	b.global_position = _p1.global_position   # 贴着射手自己
	var hp0: int = _p1.hp
	_host._adjudicate_grenade(b)
	_check(_p1.hp == hp0 and not b.has_meta("grenade_direct_hit"),
			"射手自己不结算(一出膛就在自己身上吃 5 伤)")
	b.free()


func _test_out_of_range() -> void:
	var b = _make_grenade(_p1)
	b.global_position = _p2.global_position + Vector2(MatchHost.HIT_RADIUS + 5.0, 0.0)
	var hp0: int = _p2.hp
	_host._adjudicate_grenade(b)
	_check(_p2.hp == hp0, "超出 HIT_RADIUS(%d)不结算" % int(MatchHost.HIT_RADIUS))
	b.free()


# 一具真 Player(真 take_hit / 真 combat),但关掉它自己的物理:本探针只验判定与结算。
func _make_player(role: int, cell: Vector2i) -> Node2D:
	var p: Node2D = (preload("res://scenes/player/Player.tscn") as PackedScene).instantiate()
	_host.add_child(p)
	var ts: int = GameParameters.TILE_SIZE
	p.global_position = Vector2(cell.x * ts + ts * 0.5, cell.y * ts + ts * 0.5)
	p.set_physics_process(false)
	_host.players[role] = p
	return p


# 真榴弹场景(真 direct_hit_damage=5),但关掉它自己的物理:只手动喂给裁决函数。
func _make_grenade(shooter: Node2D):
	var b = (load("res://scenes/weapons/grenade_bullet.tscn") as PackedScene).instantiate()
	_host.add_child(b)
	b.set_physics_process(false)
	b.shooter = shooter
	b.hit_impact = 10.0   # 与 grenade_launcher.tscn 的 impact 一致(weapon_base 出弹时注入的值)
	return b
