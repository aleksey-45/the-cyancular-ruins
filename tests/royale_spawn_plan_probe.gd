extends Node

# 大乱斗出生点「单一来源」探针(场景模式:要真地图 + 真 Player,autoload 必须已实例化)。
# 跑法:
#   "$GODOT" --headless --path . res://tests/royale_spawn_plan_probe.tscn
# 期望:末行 "ROYALE SPAWN PLAN PROBE: ALL-OK"。判据 grep 该文本,不只看退出码。
#
# 存在理由:`RoyaleHost.start_on` 会算一份散点并经 `match_start` **广播给客户端**,而
# `RoyaleHost._init` **又**调了一次 `plan_spawns` —— 那个函数内部 `cells.shuffle()`,
# 所以两份是**不同的随机散点**。实际摆位用的是 `_init` 那份(`super._init` 虚调 `_spawn_cell`
# 时读的就是它),而 `start_on` 事后那句 `host._round_spawns = spawns` 因为 `_spawned_once`
# 已经闩上,**改不回任何人的位置**。
# ⇒ 后果:客户端拿着广播那份出生点,服务器却把玩家摆在另一处 —— 两端开局位置不一致,静默。
#
# 本探针钉:**传进去的散点必须被原样采用,不得被重算**。做法是递一组**故意不像**平面地板格的值:
# 一旦 `_init` 重算,`plan_spawns` 只会从地图的地板格里洗牌取,几乎必然与给定值不同。
#
# ⚠ 判据 grep 文本 "ROYALE SPAWN PLAN PROBE: ALL-OK"。

const MAP := "res://maps/factory1v1.cyrm"

# 故意用一组不像地板格的值(且两两分布离奇):重算就必然不同
const GIVEN := {1: Vector2i(3, 4), 2: Vector2i(50, 60)}

var _failures: Array[String] = []
var _ran: Dictionary = {}


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("[spawn]   ✓ %s" % msg)
	else:
		_failures.append(msg)
		print("[spawn]   ✗ %s" % msg)


func _fail(msg: String) -> void:
	_failures.append(msg)
	print("[spawn]   ✗ %s" % msg)


# 完成戳防线:Godot 的运行时错误只中断当前函数,调用它的 `_ready()` 照常往下走 →
# 「测试函数中途报错、一条 _check 都没跑到、却照样打印 ALL-OK」。故每个测试函数在最后一行盖戳。
func _require_ran(name: String) -> void:
	if not _ran.has(name):
		_fail("%s 没跑到最后一行(中途报错或被跳过)→ 本趟读数不可信" % name)


func _ready() -> void:
	_test_given_spawns_are_used()
	_require_ran("given")
	if _failures.is_empty():
		print("ROYALE SPAWN PLAN PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("ROYALE SPAWN PLAN PROBE: FAIL")
		for f in _failures:
			print("[spawn]   ✗ %s" % f)
		get_tree().quit(1)


func _test_given_spawns_are_used() -> void:
	# 喂进去一份显式散点;宿主必须**原样**采用(start_on 广播给客户端的就是这一份)
	var host: Node = RoyaleHost.new(MAP, {1: 1, 2: 2}, {}, [], GIVEN)
	var got: Dictionary = host._round_spawns
	var bad: Array = []
	for r in GIVEN:
		if got.get(r, Vector2i(-9999, -9999)) != GIVEN[r]:
			bad.append("role %d: 应为 %s,实为 %s" % [r, str(GIVEN[r]), str(got.get(r, null))])
	_check(bad.is_empty() and got.size() == GIVEN.size(),
			"宿主原样采用传入的散点(得 %s;重算 = 广播那份从不生效)" % [
					str(got) if bad.is_empty() else str(bad)])

	# 不传散点时仍要能自己算一份(手工/测试路径的兜底)——但那是**兜底**,不是常规路径
	var host2: Node = RoyaleHost.new(MAP, {1: 1, 2: 2}, {}, [])
	_check(host2._round_spawns.size() == 2 and
			host2._round_spawns.get(1, Vector2i(-1, -1)) != Vector2i(-1, -1),
			"未传散点时仍会自己算一份(兜底路径在位)")

	host.queue_free()
	host2.queue_free()
	_ran["given"] = true   # ★ 完成戳必须在最后一行(见上方说明)
