extends SceneTree
# 命中补偿(位置回溯环)纯逻辑守卫。存在理由:回溯是「按射手感知滞后改判中」的核心,
# 错了会表现成「明明没打中却掉血 / 隔墙打死转角后的人」—— 都是只能靠人眼试玩的暗病。
# 覆盖:环的逐拍记录与回放、回溯上限钳制、错拍退化、AI/无 peer 零回溯、
# 回溯位置参与环面测距(跨接缝回绕那一拍也能判中)。被测 = LagComp 纯静态(零 autoload)。
# 跑法:"$GODOT" --headless --path . -s res://tests/smoke/lag_comp_smoke.gd;判词 = LAG COMP OK(n 条断言)。
# 去掉什么才红:LagComp.rewound 退化为返回 fallback、或钳制/环索引错 —— 回放值立刻对不上。

const EXPECTED_CHECKS := 4

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	if LagComp == null:
		print("LAG COMP FAILED: LagComp 加载失败")
		quit(1)
		return
	var rings := {}
	const ROLE := 7

	# ① 逐拍记录与回放:连录 12 拍(位置 = tick 值),回溯 k 必须给出第 (newest - k) 拍的位置。
	for i in range(12):
		LagComp.record(rings, ROLE, Vector2(float(i * 10), 0.0), i + 1)
	var ok1 := true
	for k in range(LagComp.REWIND_TICKS):
		if LagComp.rewound(rings, ROLE, 12, k, Vector2(-1, -1)) != Vector2(float((11 - k) * 10), 0.0):
			ok1 = false
	_chk(ok1, "位置环逐拍记录与回放(回溯 k = 第 newest-k 拍)")

	# ② 上限钳制:回溯 999 拍 = REWIND_TICKS-1(≈150ms),不是负索引/不是 fallback。
	_chk(LagComp.rewound(rings, ROLE, 12, 999, Vector2(-1, -1))
			== Vector2(float((11 - (LagComp.REWIND_TICKS - 1)) * 10), 0.0),
			"回溯上限钳到 REWIND_TICKS-1(%d 拍 ≈150ms)" % LagComp.REWIND_TICKS)

	# ③ 感知滞后折算:无 peer(AI)恒 0;有 peer 时 0 RTT = 基础 67ms ≈ 4 tick、上限 8。
	_chk(LagComp.delay_ticks(999, false) == 0
			and LagComp.delay_ticks(0, true) == 4
			and LagComp.delay_ticks(1000, true) == LagComp.REWIND_TICKS - 1,
			"AI 零回溯;人类 0RTT≈4 tick;1000ms RTT 顶到上限")

	# ④ 回溯位置 × 环面测距:受害者跨接缝回绕的那一拍,按回溯位测距判中、按当前位测不到
	#    (射手瞄的就是回绕前那一拍 —— favor-the-shooter 要治的「提前量打空」)。
	var rings2 := {}
	for i in range(6):
		LagComp.record(rings2, 9, Vector2(50.0, 50.0), i + 1)
	var cur := Vector2(9550.0, 50.0)             # 跨过 9600 宽的接缝(离弹着点 ~135px)
	var rewound := LagComp.rewound(rings2, 9, 6, 0, cur)
	var bullet_pos := Vector2(85.0, 50.0)        # 紧挨回绕前那一拍(35px < HIT_RADIUS 40)
	var d_rewound := MazeGenerator.toroidal_delta_px(bullet_pos, rewound, 9600.0, 6400.0).length()
	var d_now := MazeGenerator.toroidal_delta_px(bullet_pos, cur, 9600.0, 6400.0).length()
	_chk(d_rewound < 40.0 and d_now >= 40.0,
			"跨接缝回绕拍按回溯位判中、按当前位测不到(回溯 %.0f px vs 当前 %.0f px)" % [d_rewound, d_now])

	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("LAG COMP OK(%d 条断言):逐拍回放 · 上限钳制 · 滞后折算 · 环面回绕判中" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("LAG COMP FAILED: %d 处" % _fails.size())
		quit(1)
