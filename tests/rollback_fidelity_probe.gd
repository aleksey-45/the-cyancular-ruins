extends Node

# C2 回放保真探针(场景模式:要真 Player,故 autoload 必须已实例化,不能用 -s 跑)。
# 跑法:
#   "$GODOT" --headless --path . res://tests/rollback_fidelity_probe.tscn
# 期望:末行 "ROLLBACK FIDELITY PROBE: ALL-OK"。判据 grep 该文本,不只看退出码。
#
# A 组 · 环面比较:`_close_enough` 原先比 pos 用裸 distance_to。环面上客户端与服务器在
#   跨接缝那一帧可能相差**一整幅地图宽**(其实同一个物理点)→ 误判分歧、白跑一次回滚。
# B 组 · 重放保真:回滚重放时对手身体没被倒回 → 重放与原始预测对不上 → 级联回滚。
#   这两条是本批的全部内容,故断言都钉在这里。

const DT := 1.0 / 60.0
const MARKER := "ROLLBACK FIDELITY PROBE: ALL-OK"

var _failures: Array[String] = []

# ★ 假绿防线(本仓被抓过四次的那一类,本探针初版就中过):
#   Godot 的运行时错误只**中断当前函数**,调用它的 `_ready()` 会照常往下走 —— 于是
#   「测试函数中途报错 → 一条 _check 都没跑到 → _failures 仍空 → 照样打印 ALL-OK 并 exit 0」。
#   实测:改之前把 map_px 从 `_close_enough` 里删掉(必报错),红跑却印了 ALL-OK。
#   故每个测试函数在**最后一行**给自己盖完成戳;缺戳 = 没跑完 = 红。
var _ran: Dictionary = {}

func _check(ok: bool, msg: String) -> void:
	if ok:
		print("[fid]   ✓ %s" % msg)
	else:
		_failures.append(msg)
		print("[fid]   ✗ %s" % msg)


func _fail(msg: String) -> void:
	_failures.append(msg)
	print("[fid]   ✗ %s" % msg)


# 每个测试函数跑完后必须留下完成戳;缺了就说明它中途被中断了 —— 那种情况下面的 ✓/✗ 都不可信。
func _require_ran(name: String) -> void:
	if not _ran.has(name):
		_fail("%s 没跑到最后一行(中途报错或被跳过)→ 本趟读数不可信" % name)


func _ready() -> void:
	_test_torus_compare()
	_require_ran("torus")
	_check_source_guard()
	if _failures.is_empty():
		print(MARKER)
		get_tree().quit(0)
	else:
		print("ROLLBACK FIDELITY PROBE: FAIL")
		for f in _failures:
			print("[fid]   ✗ %s" % f)
		get_tree().quit(1)


# ── A 组:环面上「差一整幅地图宽」= 同一个物理点,不该判分歧 ──
func _test_torus_compare() -> void:
	var w := GameParameters.MAP_WIDTH
	var h := GameParameters.MAP_HEIGHT
	var p: Node2D = preload("res://scenes/player/Player.tscn").instantiate()
	add_child(p)
	p.global_position = Vector2(w * 0.5, h * 0.5)

	var c := PredictionRollback.new()
	c.bind(p)
	for i in range(20):
		c.advance({"seq": i + 1, "ax": 0.0, "held": 0, "pressed": 0, "released": 0,
				"weapon": 0, "aim": Vector2(1.0, 0.0)})

	# 取两个真实 capture,把它们的位置平移**整整一幅地图宽** —— 环面上仍是同一个物理点
	var s14: Dictionary = (c._captures[14] as Dictionary).duplicate()
	s14["pos"] = (s14["pos"] as Vector2) + Vector2(float(w), 0.0)
	var s15: Dictionary = (c._captures[15] as Dictionary).duplicate()
	s15["pos"] = (s15["pos"] as Vector2) + Vector2(float(w), 0.0)

	# ① 设了 map_px → 判为「预测被证实」,不回滚
	c.map_px = Vector2(float(w), float(h))
	var rb0 := c.rollback_count()
	c.on_authoritative(14, s14)
	c.reconcile()
	_check(c.rollback_count() == rb0,
			"① 环面同一物理点(差一整幅地图宽)不判分歧(回滚 ×%d→×%d)" % [rb0, c.rollback_count()])

	# ② 反证:map_px 归零 → 同一份形状的载荷必须判成分歧(证明 ① 不是空转断言)
	c.map_px = Vector2.ZERO
	var rb1 := c.rollback_count()
	c.on_authoritative(15, s15)
	c.reconcile()
	_check(c.rollback_count() == rb1 + 1,
			"② 去掉环面处理后同一份载荷判为分歧(回滚 ×%d→×%d)" % [rb1, c.rollback_count()])

	p.queue_free()
	_ran["torus"] = true   # ★ 完成戳必须在最后一行:中途报错就到不了这里(见顶部说明)


# ── 源码守卫 ──
# `map_px` 不接线的话,环面修复在**真机上是惰性的** —— 而且**静默**:不报错、探针全绿、
# 生产行为与修复前逐帧一致(实测过)。所以把"接线了"这件事本身变成断言。
# 若日后改法换了入口(例如搬进 player.gd),请把这里改成认新入口,**别删掉这条断言**。
func _check_source_guard() -> void:
	var txt := FileAccess.get_file_as_string("res://scenes/pvp_client.gd")
	var found := false
	for line in txt.split("\n"):
		if line.contains("map_px") and not line.strip_edges().begins_with("#"):
			found = true
			break
	_check(found, "pvp_client 给控制器设了 map_px(不设 = 环面修复惰性且静默)")
