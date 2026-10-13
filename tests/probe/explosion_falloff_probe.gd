extends SceneTree


const RADIUS := 128.0
const MAX_DMG := 35


func _initialize() -> void:
	var Exp: GDScript = load("res://core/sim/explosion.gd")
	if not Exp.has_method("cover_multiplier"):
		print("SMOKE FAILED: Explosion.cover_multiplier 未实现")
		quit(1)
		return
	var failures := 0

	# 1) 衰减曲线本身单调不增
	var prev := INF
	for i in range(0, 129):
		var d := float(i)
		var v: float = Exp._falloff(d, RADIUS, MAX_DMG)
		if v > prev + 0.0001:
			print("FAIL: _falloff 在 d=%d 回升 (%f > %f)" % [i, v, prev])
			failures += 1
		prev = v

	# 2) 掩护系数:内圈免疫,外圈被遮挡才衰减
	if Exp.cover_multiplier(RADIUS * 0.2, RADIUS, true) != 1.0:
		print("FAIL: 内圈被遮挡仍扣伤(应免疫)")
		failures += 1
	if not is_equal_approx(Exp.cover_multiplier(RADIUS * 0.8, RADIUS, true), Exp.BLOCKED_FRACTION):
		print("FAIL: 外圈被遮挡未按 BLOCKED_FRACTION 衰减")
		failures += 1
	if Exp.cover_multiplier(RADIUS * 0.8, RADIUS, false) != 1.0:
		print("FAIL: 外圈无遮挡不应衰减")
		failures += 1

	prev = INF
	for i in range(0, 129):
		var d := float(i)
		var v: float = Exp._falloff(d, RADIUS, MAX_DMG) * Exp.cover_multiplier(d, RADIUS, true)
		if v > prev + 0.0001:
			print("FAIL: 合成伤害在 d=%d 回升 (%f > %f)" % [i, v, prev])
			failures += 1
		prev = v

	if failures == 0:
		print("SMOKE OK")
	else:
		print("SMOKE FAILED: %d 处" % failures)
	quit(1 if failures > 0 else 0)
