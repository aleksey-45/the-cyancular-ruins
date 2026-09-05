extends SceneTree

# 爆炸衰减单调性探针(实验分支 KikuchiHeinr):验证修复后的
# "伤害随距离不增"(爆心 ≥ 任意边缘),含最坏情况(全程被墙遮挡)。
# 纯函数,不引 autoload,-s 可跑:
#   Godot_console --headless --path . -s res://Tests/explosion_falloff_probe.gd

const RADIUS := 128.0
const MAX_DMG := 35


func _init() -> void:
	var failures := 0

	# 1) 衰减曲线本身单调不增
	var prev := INF
	for i in range(0, 129):
		var d := float(i)
		var v: float = Explosion._falloff(d, RADIUS, MAX_DMG)
		if v > prev + 0.0001:
			print("FAIL: _falloff 在 d=%d 回升 (%f > %f)" % [i, v, prev])
			failures += 1
		prev = v

	# 2) 掩护系数:内圈免疫,外圈被遮挡才衰减
	if Explosion.cover_multiplier(RADIUS * 0.2, RADIUS, true) != 1.0:
		print("FAIL: 内圈被遮挡仍扣伤(应免疫)")
		failures += 1
	if not is_equal_approx(Explosion.cover_multiplier(RADIUS * 0.8, RADIUS, true), Explosion.BLOCKED_FRACTION):
		print("FAIL: 外圈被遮挡未按 BLOCKED_FRACTION 衰减")
		failures += 1
	if Explosion.cover_multiplier(RADIUS * 0.8, RADIUS, false) != 1.0:
		print("FAIL: 外圈无遮挡不应衰减")
		failures += 1

	# 3) 最坏情况(每个距离都判"被遮挡"):合成伤害仍单调不增
	#    ——修复前:贴脸遮挡目标 ×0.75 而边缘无遮挡目标全额,会倒挂。
	prev = INF
	for i in range(0, 129):
		var d := float(i)
		var v: float = Explosion._falloff(d, RADIUS, MAX_DMG) * Explosion.cover_multiplier(d, RADIUS, true)
		if v > prev + 0.0001:
			print("FAIL: 合成伤害在 d=%d 回升 (%f > %f)" % [i, v, prev])
			failures += 1
		prev = v

	if failures == 0:
		print("SMOKE OK")
	else:
		print("SMOKE FAILED: %d 处" % failures)
	quit(1 if failures > 0 else 0)
