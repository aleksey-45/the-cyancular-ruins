extends SceneTree
# 地面武器纯逻辑表守卫(「看得见却捡不起来」修复的承重部分之一)。

const EXPECTED_CHECKS := 5

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	# ★ 空载守卫(仓规):load() 失败还往下走会在 null 上抛错,而 `-s` 抛错走不到 quit() ⇒ 进程永久挂起。
	if load("res://core/sim/ground_weapon_field.gd") == null:
		print("GROUND WEAPON FIELD FAILED: load(ground_weapon_field.gd) 返回 null(-s 空载守卫:不 quit 会挂死)")
		quit(1)
		return

	var f := GroundWeaponField.new()
	f.map_size = Vector2(1000.0, 1000.0)
	f.add({"inst": 1, "type_id": 1, "mag": 30, "pos": Vector2(100.0, 100.0), "vel": Vector2.ZERO})
	f.add({"inst": 2, "type_id": 2, "mag": 10, "pos": Vector2(980.0, 100.0), "vel": Vector2.ZERO})

	# ① 最近一把:同半径内取更近的那件;半径外取不到
	_chk(f.nearest_within(Vector2(110.0, 100.0), 64.0).get("inst", -1) == 1
			and f.nearest_within(Vector2(500.0, 500.0), 64.0).is_empty(),
			"nearest_within 应取半径内最近的一件、半径外返回空")

	# ② 承重:环面最短距离 —— x=980 那件离 x=10 只有 30px(跨接缝),不能算成 970px
	_chk(int(f.nearest_within(Vector2(10.0, 100.0), 64.0).get("inst", -1)) == 2,
			"★ 接缝另一侧的武器必须够得着(环面最短距离;实得 %s)" % str(f.nearest_within(Vector2(10.0, 100.0), 64.0)))

	# ③ 承重:重锚改位置,且改完 nearest_within 立刻按新位置判定
	var moved := f.reanchor(2, Vector2(120.0, 100.0), Vector2.ZERO)
	_chk(moved and f.get_entry(2)["pos"] == Vector2(120.0, 100.0)
			and int(f.nearest_within(Vector2(118.0, 100.0), 32.0).get("inst", -1)) == 2,
			"★ reanchor 必须搬动位置并让拾取判定读到新位置(实得 moved=%s pos=%s 最近=%s)" % [
				str(moved), str(f.get_entry(2).get("pos", "?")),
				str(f.nearest_within(Vector2(118.0, 100.0), 32.0).get("inst", -1))])

	# ④ 不在表里的 inst:重锚必须失败(重播过期 —— 那件已被捡走/移除)
	_chk(not f.reanchor(99, Vector2.ZERO, Vector2.ZERO),
			"对不存在的 inst 重锚必须返回 false(过期的重播不能被当成新增)")

	# ⑤ 重锚只动位置/速度:类型与残弹是"同一件枪"的属性,归 add 管
	var e2 := f.get_entry(2)
	_chk(int(e2["type_id"]) == 2 and int(e2["mag"]) == 10,
			"★ 重锚不得改写 type_id/mag(实得 type=%s mag=%s)" % [str(e2["type_id"]), str(e2["mag"])])

	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("GROUND WEAPON FIELD OK(%d 条断言):最近一把 · 接缝够得着 · 重锚生效 · 过期重播拒绝 · 只动位置速度"
				% _checks)
		quit(0)
	else:
		for f2 in _fails:
			print("  [FAIL] ", f2)
		print("GROUND WEAPON FIELD FAILED: %d 处" % _fails.size())
		quit(1)
