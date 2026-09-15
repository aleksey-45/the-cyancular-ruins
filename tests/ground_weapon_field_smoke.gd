extends SceneTree

# 地面武器表冒烟:环面最近拾取 + 并列确定性 + 增删查。
# 跑法: "$GODOT" --headless --path . -s res://tests/ground_weapon_field_smoke.gd
# 通过 = `GROUND_WEAPON_FIELD OK` 退出 0。
#
# ═══ 为什么需要它 ═══
# 两条都是"单机看起来完全正常、只在接缝/多人时坏"的形状:
#   ① 距离必须走**环面最短** —— 用绝对坐标差的话,接缝另一侧贴脸的枪会被算成
#      "隔了整幅地图",表现是"贴脸也捡不到"。
#   ② 并列(两把完全重合)必须按 inst **确定性**排序 —— 否则两台客户端各自挑中不同的一把,
#      服务器裁决的和玩家看到的不是同一把。

var _fail := 0


func _check(ok: bool, msg: String) -> void:
	if ok:
		return
	_fail += 1
	print("[FAIL] ", msg)


func _initialize() -> void:
	var GW: GDScript = load("res://core/sim/ground_weapon_field.gd")
	# ★ 空载守卫:load() 失败还往下走会抛错,而 -s 抛错走不到 quit() → 永久挂起
	if GW == null:
		print("GROUND_WEAPON_FIELD FAILED: 找不到 core/sim/ground_weapon_field.gd")
		quit(1)
		return

	var f = GW.new()
	f.map_size = Vector2(640, 480)   # 假地图:10x7.5 格,足够验跨接缝

	f.add({"inst": 1, "type_id": 1, "mag": 5, "pos": Vector2(100, 100), "vel": Vector2.ZERO})
	f.add({"inst": 2, "type_id": 3, "mag": 5, "pos": Vector2(130, 100), "vel": Vector2.ZERO})
	f.add({"inst": 3, "type_id": 5, "mag": 5, "pos": Vector2(620, 100), "vel": Vector2.ZERO})

	# ── ① 环面最短距离:玩家在 x=5,id=3 在 x=620 —— 直线 615,但绕接缝只有 25,
	#    比 id=1 的 95 更近 ──
	var near: Dictionary = f.nearest_within(Vector2(5, 100), 64.0)
	_check(not near.is_empty() and int(near["inst"]) == 3,
		"跨接缝时最近的应是绕过去的那把(实际 %s)" % str(near.get("inst", "<无>")))

	# ── 半径外不选中 ──
	_check(f.nearest_within(Vector2(300, 400), 64.0).is_empty(), "半径外应返回空字典")

	# ── ② 并列时按 inst 升序(确定性) ──
	var f2 = GW.new()
	f2.map_size = Vector2(640, 480)
	f2.add({"inst": 7, "type_id": 1, "mag": 0, "pos": Vector2(100, 100), "vel": Vector2.ZERO})
	f2.add({"inst": 4, "type_id": 2, "mag": 0, "pos": Vector2(100, 100), "vel": Vector2.ZERO})
	var tie: Dictionary = f2.nearest_within(Vector2(100, 100), 64.0)
	_check(int(tie["inst"]) == 4, "完全重合时取 inst 小的(实际 %s)" % str(tie.get("inst", "<无>")))

	# ── exclude 不参与判定(自己刚丢下的枪不该被立刻捡回) ──
	var ex: Dictionary = f2.nearest_within(Vector2(100, 100), 64.0, [4])
	_check(int(ex["inst"]) == 7, "exclude 里的 inst 不参与判定(实际 %s)" % str(ex.get("inst", "<无>")))

	# ── 增删查 ──
	_check(f.size() == 3, "add 后 size = 3(实际 %d)" % f.size())
	var gone: Dictionary = f.remove(1)
	_check(int(gone["type_id"]) == 1, "remove 返回被删条目")
	_check(f.size() == 2 and f.get_entry(1).is_empty(), "remove 后查不到该条目")
	_check(f.remove(999).is_empty(), "remove 不存在的 inst 返回空字典而不崩")
	f.clear()
	_check(f.size() == 0, "clear 清空")

	if _fail == 0:
		print("GROUND_WEAPON_FIELD OK")
		quit(0)
	else:
		print("GROUND_WEAPON_FIELD FAILED: %d" % _fail)
		quit(1)
