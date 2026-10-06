extends Node

# C2 回放保真探针(场景模式:要真 Player,故 autoload 必须已实例化,不能用 -s 跑)。
# 跑法:
#   "$GODOT" --headless --path . res://tests/probe/rollback_fidelity_probe.tscn
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
	_test_contact_tolerance()
	_require_ran("contact_tol")
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
	var p: Node2D = preload("res://scenes/player/player.tscn").instantiate()
	add_child(p)
	p.global_position = Vector2(w * 0.5, h * 0.5)

	var c := PredictionRollback.new()
	c.bind(p)
	for i in range(20):
		c.advance({"seq": i + 1, "ax": 0.0, "held": 0, "pressed": 0, "released": 0,
				"winst": 0, "aim": Vector2(1.0, 0.0)})

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


# ── C 组:接触期容差(贴身时用 contact_pos_tol,非接触期保持 pos_tol)──
# 手法与 A 组同款:直接摆 _captures + on_authoritative + reconcile,不依赖真实物理世界。
# 造一个已跑到 20 帧的控制器 + 它绑的玩家,并把 seq14 那份 capture 的 pos 挪 10px 当"权威"。
func _make_contact_fixture() -> Dictionary:
	var p: Node2D = preload("res://scenes/player/player.tscn").instantiate()
	add_child(p)
	p.global_position = Vector2(GameParameters.MAP_WIDTH * 0.5, GameParameters.MAP_HEIGHT * 0.5)
	var c := PredictionRollback.new()
	c.bind(p)
	c.pos_tol = 2.0
	c.contact_pos_tol = 24.0   # 测试用值,与生产常量**解耦**(常量日后改了这条断言不该跟着漂)
	c.map_px = Vector2(float(GameParameters.MAP_WIDTH), float(GameParameters.MAP_HEIGHT))
	for i in range(20):
		c.advance({"seq": i + 1, "ax": 0.0, "held": 0, "pressed": 0, "released": 0,
				"winst": 0, "aim": Vector2(1.0, 0.0)})
	# 权威态 = 该帧 capture 平移 10px(> pos_tol 2px,< contact_pos_tol 24px)
	var s: Dictionary = (c._captures[14] as Dictionary).duplicate()
	s["pos"] = (s["pos"] as Vector2) + Vector2(10.0, 0.0)
	return {"ctrl": c, "player": p, "state": s}


func _test_contact_tolerance() -> void:
	# ① 非接触期:10px > pos_tol(2px)⇒ 真分歧 ⇒ 必须回滚
	var f1: Dictionary = _make_contact_fixture()
	var c1: PredictionRollback = f1["ctrl"]
	c1.in_contact = false
	var rb0 := c1.rollback_count()
	c1.on_authoritative(14, f1["state"])
	c1.reconcile()
	_check(c1.rollback_count() == rb0 + 1,
			"③ 非接触期 10px 偏差判为分歧(回滚 ×%d→×%d)" % [rb0, c1.rollback_count()])
	(f1["player"] as Node).queue_free()

	# ② 接触期:**同一份形状的载荷**、只把 in_contact 翻成 true ⇒ 必须**不**回滚
	#    ★ 两份夹具各自独立(不复用控制器):①的回滚会重放并改写 capture,复用会让 ② 比到别的东西。
	var f2: Dictionary = _make_contact_fixture()
	var c2: PredictionRollback = f2["ctrl"]
	c2.in_contact = true
	var rb1 := c2.rollback_count()
	c2.on_authoritative(14, f2["state"])
	c2.reconcile()
	_check(c2.rollback_count() == rb1,
			"④ 贴身时同一份载荷不再判分歧(回滚 ×%d→%d,容差 2→24px)" % [rb1, c2.rollback_count()])
	(f2["player"] as Node).queue_free()

	_ran["contact_tol"] = true   # ★ 完成戳必须在最后一行:中途报错就到不了这里(见文件头说明)


# ── 源码守卫 ──
# `map_px` 不接线的话,环面修复在**真机上是惰性的** —— 而且**静默**:不报错、探针全绿、
# 生产行为与修复前逐帧一致(实测过)。所以把"接线了"这件事本身变成断言。
# 若日后改法换了入口(例如搬进 player.gd),请把这里改成认新入口,**别删掉这条断言**。
func _check_source_guard() -> void:
	var txt := FileAccess.get_file_as_string("res://scenes/pvp_game.gd")
	var found := false
	for line in txt.split("\n"):
		if line.contains("map_px") and not line.strip_edges().begins_with("#"):
			found = true
			break
	_check(found, "pvp_client 给控制器设了 map_px(不设 = 环面修复惰性且静默)")

	# ② 接触提示的接线(`in_contact` 必须在 note_post_step 之前写 —— 它是那一步的消费方)。
	#    漏了这一行 = 静默退回 2px 容差:不报错、探针全绿、真机行为与改动前逐帧一致。
	#    ★ 要拦下的变异:把 `_rollback.in_contact = …` 挪到 `note_post_step(...)` **之后** ——
	#      接触提示永远用**上一帧**的碰撞信息(差一帧),静默且没有别的守卫看得见。
	#    ★ 位置序**就是**契约,保留;但比较范围**收在同一帧块内**(包住该赋值的那一层顶层函数):
	#      别处无关函数里新增/删掉一条 note_post_step 不该把这条带红(那是无关行数变动)。
	#    ★ 日后若换了入口,请把这里改成认新入口,**别删掉这条断言**。
	var txt2 := FileAccess.get_file_as_string("res://scenes/pvp_match_client.gd")
	var lines := txt2.split("\n")
	var hint_line := -1
	var hint_count := 0
	for i in range(lines.size()):
		var line := lines[i]
		if line.strip_edges().begins_with("#"):
			continue
		if line.contains("_rollback.in_contact =") and line.contains("touching_player()"):
			hint_count += 1
			hint_line = i
	_check(hint_count == 1,
			"接触提示只许有**一处**赋值(实得 %d 处 —— 0 = 漏接线,>1 = 有两处在抢)" % hint_count)
	# 同一帧块 = [该赋值所在行 +1, 下一个列 0 的 `func ` 之间)
	var note_line := -1
	if hint_line >= 0:
		var blk_end := lines.size()
		for i in range(hint_line + 1, lines.size()):
			if lines[i].begins_with("func "):
				blk_end = i
				break
		for i in range(hint_line + 1, blk_end):
			if lines[i].strip_edges().begins_with("#"):
				continue
			if lines[i].contains(".note_post_step("):
				note_line = i
				break
	_check(note_line >= 0,
			"接触提示的赋值排在**同一帧块内**的 note_post_step 之前(hint@%d, note@%d;顺序反了 = 静默退回 2px 容差)"
			% [hint_line, note_line])
