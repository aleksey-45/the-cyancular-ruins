extends SceneTree
# 对比 A(旧行为)与 B(修复后)的像素差: 差集区域 = 修复后敌人精灵出现的位置。

func _init() -> void:
	var a := Image.load_from_file("res://Tests/_seam_a_old.png")
	var b := Image.load_from_file("res://Tests/_seam_b_fixed.png")
	var count := 0
	var minx := 1e9
	var maxx := -1
	var miny := 1e9
	var maxy := -1
	for y in range(b.get_height()):
		for x in range(b.get_width()):
			var ca: Color = a.get_pixel(x, y)
			var cb: Color = b.get_pixel(x, y)
			var d := (ca.r - cb.r) * (ca.r - cb.r) + (ca.g - cb.g) * (ca.g - cb.g) \
					+ (ca.b - cb.b) * (ca.b - cb.b)
			if d > 0.01:
				count += 1
				minx = mini(minx, x)
				maxx = maxi(maxx, x)
				miny = mini(miny, y)
				maxy = maxi(maxy, y)
	if count == 0:
		print("A 与 B 完全相同")
	else:
		print("A/B 差异像素=", count, " 包围盒 x[", minx, ",", maxx,
				"] y[", miny, ",", maxy, "]")
		# 相机在 W-100=2300,视口 800 宽 → 视口 x = 世界x - 2300 + 400
		print("视口 x≈", minx, "~", maxx, " 对应世界 x≈",
				int(minx + 2300 - 400), "~", int(maxx + 2300 - 400))
	quit()
