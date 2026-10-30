extends SceneTree
# 重连补态的子格守卫(BUG-03:重连后客户端比服务器多出"只被打掉部分子格的砖" ⇒ 幽灵墙/每帧回滚)。
# 存在理由:match_sync 载荷的 `destroyed` 只表达「64px 格与建局基线不同」;榴弹现在按 32px 块破坏
#   (2×2 子格),只灭几个子格的砖**格子本身没变** ⇒ 不在那一份里。不补这一份,客户端重连后:
#   贴图与碰撞都还留着、服务器上早已是洞 ⇒ 本地预测每帧撞不存在的墙(橡皮筋/子弹被挡)。
# 守卫 = 补态列表的纯函数(`TileResync.partial_damaged_subs`,不引 autoload ⇒ 本文件能 `-s` 跑):
#   只收"格仍与基线相同"的死子格,整格已消失的交给 `destroyed_cells()` 展开、不重复发;顺序确定。
# 测不到什么:① 载荷真从 worker 到达客户端(要真链路);② 客户端 `_on_remote_sub_destroyed` 静默补在真
#   Level0 上的效果(场景探针/人眼);③ 16px 子格 HP 只被磨低但没死的情况(外观不变,不需要补)。
# 变异验证:删掉"格仍与基线相同"过滤 ⇒ ② 红(整格子格被重复发);删 sort_custom ⇒ ④ 红;
#   把 `damaged` 换成全量遍历 ⇒ ③/⑤ 红。
# 跑法:"$GODOT" --headless --path . -s res://tests/smoke/resync_substate_smoke.gd;通过 = 结尾打 RESYNC SUBSTATE OK(n 条断言)。

const EXPECTED_CHECKS := 5

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	# 夹具:6×6 格(全实心 = 1);damaged_subs 里混三种情况:
	#   ① (1,1) 部分破坏:子格 (4,4)、(5,5) 死,格子仍实心 ⇒ 必须补;
	#   ② (2,2) 整格消失:16 子格全死 + grid 归 0 ⇒ 由 destroyed_cells() 覆盖,必须**不**重复发;
	#   ③ (3,3) 完全没动 ⇒ 不发。
	var base: Array = []
	for y in 6:
		var row: Array = []
		row.resize(6)
		row.fill(1)
		base.append(row)
	var cur: Array = (base as Array).duplicate(true)
	cur[2][2] = 0
	var damaged: Dictionary = {}
	damaged[Vector2i(4, 4)] = true
	damaged[Vector2i(5, 5)] = true
	for sy in 4:
		for sx in 4:
			damaged[Vector2i(2 * 4 + sx, 2 * 4 + sy)] = true

	var got: Array = TileResync.partial_damaged_subs(damaged, cur, base)

	# ① 部分破坏格的两个子格必须补(去掉收集 damaged 这步 ⇒ 这里空,红)
	_chk(got.size() == 2 and got.has(Vector2i(4, 4)) and got.has(Vector2i(5, 5)),
			"部分破坏的 16px 子格必须进补态列表(实得 %s)" % str(got))

	# ② 整格已消失的不许重复发(去掉"格仍与基线相同"过滤 ⇒ 会多出 16 个,红)
	var full_cell_leak := false
	for s in got:
		var sub: Vector2i = s
		if sub.x >= 8 and sub.x < 12 and sub.y >= 8 and sub.y < 12:
			full_cell_leak = true
	_chk(not full_cell_leak, "整格已消失的 16 子格不重复发(交给 destroyed_cells 展开)")

	# ③ 没动过的格不发
	var untouched := false
	for s in got:
		var sub2: Vector2i = s
		if sub2.x >= 12 and sub2.x < 16 and sub2.y >= 12 and sub2.y < 16:
			untouched = true
	_chk(got.size() == 2 and not untouched, "未破坏的格不进补态列表")

	# ④ 顺序确定:插进 damaged 的顺序打乱后结果仍按 (y,x) 升序、且两次调用逐位相同(载荷可复现)
	var shuffled: Dictionary = {}
	for k in [Vector2i(5, 5), Vector2i(4, 4)]:
		shuffled[k] = true
	var a := TileResync.partial_damaged_subs(shuffled, cur, base)
	var b := TileResync.partial_damaged_subs(shuffled, cur, base)
	_chk(a == b and a.size() == 2 and a[0] == Vector2i(4, 4) and a[1] == Vector2i(5, 5),
			"补态列表顺序确定(y 升序、同 y 升序 x;两次调用逐位相同)")

	# ⑤ 无假阳性:damaged 全落在"整格已消失"的格子里 ⇒ 列表必须空(整格那一路已够)
	var only_full: Dictionary = {}
	for sy in 4:
		for sx in 4:
			only_full[Vector2i(2 * 4 + sx, 2 * 4 + sy)] = true
	_chk(TileResync.partial_damaged_subs(only_full, cur, base).is_empty(),
			"全是整格消失时列表为空(不重复发整格子格)")

	# 判词:计数闸(条数不符也红 —— 防断言被静默跳过)
	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("RESYNC SUBSTATE OK(%d 条断言):部分破坏补齐 · 整格不重复 · 未动不发 · 顺序确定 · 无假阳性" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("RESYNC SUBSTATE FAILED: %d 处" % _fails.size())
		quit(1)