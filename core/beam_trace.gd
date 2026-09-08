extends RefCounted

# 激光光束几何追踪(纯静态、可 -s 冒烟、不引 autoload)。不是物理弹丸——
# 开火瞬间沿方向逐格走 32px 子格(64px 格 → 2×2 形状掩码),遇墙翻对应轴反射,
# 至多 max_bounces 次;第 (max_bounces+1) 次碰墙被吸收(停在该墙表面),或累计距离
# ≥ max_len 在空中消失。折线点集 = 起始 + 每次反射墙面的拐点 + 终点。
#
# 判定语义与 CollisionBuilder.build_sub 完全一致(只认 type=wall 且形状位实心;
# 通道/液体/气体无碰撞 → 光束穿过水/梯)。环面:固体判定 posmod 回规范副本,
# 坐标保持在「射手所在副本」的连续系 → 跨接缝也连续。
# 不声明 class_name:新 class 名需 --import 刷新全局缓存;此文件用 preload 引用即可。

const SUB_TS: float = 32.0  # 子格边长(px)

# origin: 枪口世界坐标;dir: 单位方向;max_len: 总射程(px);max_bounces: 反射次数上限。
# 返回 {"points": PackedVector2Array 世界坐标折线(含起点/拐点/终点),
#       "contacts": Array[Vector2i] 每次碰墙的 64px 格(规范坐标,可破坏砖扣血用),
#       "hit_points": PackedVector2Array 与 contacts 平行的碰墙表面世界坐标(播粒子落点)}。
static func trace(origin: Vector2, dir: Vector2, max_len: float, max_bounces: int) -> Dictionary:
	var grid := MazeGenerator.current_grid
	var pts := PackedVector2Array([origin])
	var cells: Array = []
	var hit_pts := PackedVector2Array()
	if grid.is_empty():
		pts.append(origin + dir.normalized() * max_len)
		return {"points": pts, "contacts": cells, "hit_points": hit_pts}
	var cols := grid[0].size()
	var rows := grid.size()
	var sub_cols := cols * 2
	var sub_rows := rows * 2
	var p := origin
	var d := dir.normalized()
	if d == Vector2.ZERO:
		d = Vector2.RIGHT
	var traveled := 0.0
	var bounces := 0
	var guard := 0
	while guard < 10000:
		guard += 1
		var remaining := max_len - traveled
		if remaining <= 0.0:
			break
		# 当前所在 32px 子格(可越界,跨接缝靠 posmod 判实)
		var sx := floori(p.x / SUB_TS)
		var sy := floori(p.y / SUB_TS)
		# 到下一个 x/y 子格边界(沿行进方向)的距离
		var tx := INF
		var ty := INF
		if d.x > 0.0:
			tx = ((sx + 1) * SUB_TS - p.x) / d.x
		elif d.x < 0.0:
			tx = (sx * SUB_TS - p.x) / d.x
		if d.y > 0.0:
			ty = ((sy + 1) * SUB_TS - p.y) / d.y
		elif d.y < 0.0:
			ty = (sy * SUB_TS - p.y) / d.y
		var t := minf(tx, ty)
		if is_inf(t):
			pts.append(p + d * remaining)
			break
		if t <= 1e-9:
			# 起点恰在某 32px 子格线上:正对边界 t=0 会原地空转,朝行进方向推一点再判
			p += d * 0.25
			continue
		if t > remaining:
			pts.append(p + d * remaining)
			break
		var q := p + d * t
		var cross_x := tx <= ty  # 越过竖线(翻 x)还是横线(翻 y)
		var nsx := sx
		var nsy := sy
		if cross_x:
			nsx = sx + (1 if d.x > 0.0 else -1)
		else:
			nsy = sy + (1 if d.y > 0.0 else -1)
		# 进入格是否实心(规范副本 + 形状位)
		var gx := posmod(nsx, sub_cols)
		var gy := posmod(nsy, sub_rows)
		var cell := Vector2i(gx / 2, gy / 2)
		var solid := false
		var v: int = grid[cell.y][cell.x]
		if v != 0 and TileDefs.is_blocked(v):
			var shape := v % 16
			if shape & (1 << (gy % 2 * 2 + gx % 2)):
				solid = true
		if not solid:
			p = q
			traveled += t
			continue
		# 碰墙:记录拐点 + 触格 + 触面点;仍在反射额度内 → 翻对应轴反射,超额度 → 被吸收终止
		pts.append(q)
		cells.append(cell)
		hit_pts.append(q)
		traveled += t
		if bounces < max_bounces:
			bounces += 1
			if cross_x:
				d.x = -d.x
			else:
				d.y = -d.y
			p = q + d * 0.5  # 稍微离开墙面,避免下一轮立即判定原地实心
		else:
			break
	return {"points": pts, "contacts": cells, "hit_points": hit_pts}
