class_name EditorGeometry
extends RefCounted

# 镜像 level_editor/core/85_geometry.js —— 名字净化与画笔几何。
# ★ 禁止 RegEx(客户端导出裁剪了 regex 模块):JS 的三条正则在这里全部手写。


# 名字净化:空白 → "_"、剔除非法字符、去前导 "-"、截 32 字符、空则 "structure"。
# 允许集与 JS 的 [A-Za-z0-9_一-龥-] 逐字对应(CJK 区间 = 一-龥)。
static func sanitize_name(name: String) -> String:
	var n := _trim_js(name)
	var chars: Array[String] = []
	var i := 0
	while i < n.length():
		var cp := n.unicode_at(i)
		if _is_js_space(cp):
			while i < n.length() and _is_js_space(n.unicode_at(i)):
				i += 1
			chars.append("_")
			continue
		if (cp >= 48 and cp <= 57) or (cp >= 65 and cp <= 90) or (cp >= 97 and cp <= 122) \
				or cp == 95 or cp == 45 or (cp >= 0x4E00 and cp <= 0x9FA5):
			chars.append(n.substr(i, 1))
		i += 1
	var out := "".join(chars)
	while out.begins_with("-"):
		out = out.substr(1)
	if out.length() > 32:
		out = out.substr(0, 32)
	return "structure" if out == "" else out


# 画笔块偏移:以指针格为中心向上下/左右扩展,保证 lo+1+hi == size;奇数对称,偶数偏下右。
static func brush_offsets(size: int) -> Dictionary:
	return {"lo": (size - 1) / 2, "hi": size / 2}


# Bresenham 直线路径格坐标(含两端)。
static func line_cells(x0: int, y0: int, x1: int, y1: int) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	var dx := absi(x1 - x0)
	var dy := absi(y1 - y0)
	var sx := 1 if x0 < x1 else -1
	var sy := 1 if y0 < y1 else -1
	var err := dx - dy
	var x := x0
	var y := y0
	while true:
		cells.append(Vector2i(x, y))
		if x == x1 and y == y1:
			break
		var e2 := 2 * err
		if e2 > -dy:
			err -= dy
			x += sx
		if e2 < dx:
			err += dx
			y += sy
	return cells


# 矩形区域归一化:任意两角点 → {x, y, w, h}(含两端)。
static func norm_region(x0: int, y0: int, x1: int, y1: int) -> Dictionary:
	return {
		"x": mini(x0, x1),
		"y": mini(y0, y1),
		"w": absi(x1 - x0) + 1,
		"h": absi(y1 - y0) + 1,
	}


# JS 的 \s(trim 与 \s+ 同一集合);不引 RegEx,按码点判。
static func _is_js_space(cp: int) -> bool:
	if cp >= 9 and cp <= 13:
		return true
	if cp == 32 or cp == 0xA0 or cp == 0x1680 or cp == 0x2028 or cp == 0x2029 \
			or cp == 0x202F or cp == 0x205F or cp == 0x3000 or cp == 0xFEFF:
		return true
	return cp >= 0x2000 and cp <= 0x200A


static func _trim_js(s: String) -> String:
	var a := 0
	var b := s.length()
	while a < b and _is_js_space(s.unicode_at(a)):
		a += 1
	while b > a and _is_js_space(s.unicode_at(b - 1)):
		b -= 1
	return s.substr(a, b - a)
