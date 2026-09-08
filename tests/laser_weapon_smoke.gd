extends SceneTree

# LaserWeaponBase 抽取冒烟:验证基类三缝存在、默认直线几何、反射子类可解析、PvP 上报 round-trip、
# 远端"粘副本"公式。跑 `-s res://tests/laser_weapon_smoke.gd`(需先跑过编辑器 --import 刷全局类缓存,
# laser_gun extends LaserWeaponBase 才可解析)。
#
# 纪律:laser 脚本链全部在 _initialize() 内 load()(顶层不触碰会解析 autoload 名的脚本 —— -s 阶段
# autoload 尚未实例化,类作用域 preload/静态引用会把编译期 Parse Error 拖进来,运行时 load 则安全)。
# 不真正 fire(伤害结算走 GameParameters.MAP_WIDTH 实例访问需 autoload);几何/上报/公式这些纯逻辑面在此覆盖,
# 伤害与视觉回归交给既有 enemy_logic_smoke + 手动。

var _failures: Array[String] = []

func _check(cond: bool, name: String) -> void:
	if cond:
		print("  ok  - " + name)
	else:
		_failures.append(name)
		printerr("  FAIL - " + name)

func _initialize() -> void:
	TileDefs.load_defs()
	var BaseScript: Variant = load("res://scenes/weapons/laser_weapon_base.gd")
	var GunScript: Variant = load("res://scenes/weapons/laser_gun.gd")
	_check(BaseScript != null, "LaserWeaponBase 脚本可 load")
	_check(GunScript != null, "laser_gun 脚本可 load")

	# ── 基类默认几何 = 直线 hitscan:空网格无墙 → 起点 + 射程末端两点 ──
	MazeGenerator.current_grid = _make_grid(20, 6)
	var base_weapon: Variant = BaseScript.new()
	base_weapon.bullet_range = 500.0
	var b1: Dictionary = base_weapon._emit_beam(Vector2(150, 150), Vector2.RIGHT)
	var p1: PackedVector2Array = b1["points"]
	_check(p1.size() == 2, "基类默认直线 2 点(起+止)")
	_check(absf(p1[1].x - 650.0) < 0.01 and absf(p1[1].y - 150.0) < 0.01, "基类默认止于射程末端")

	# ── 反射子类可解析 + 几何(竖墙 col1,从右往左打 → 撞墙反射)── 顺带证明 extends LaserWeaponBase 就绪
	var grid := _make_grid(20, 6)
	for y in range(6):
		grid[y][1] = MazeGenerator.SOLID
	MazeGenerator.current_grid = grid
	var gun: Variant = GunScript.new()
	gun.bullet_range = 1000.0
	gun.max_bounces = 2
	var b2: Dictionary = gun._emit_beam(Vector2(150, 150), Vector2.LEFT)
	var p2: PackedVector2Array = b2["points"]
	var c2: Array = b2["contacts"]
	_check(p2.size() == 3, "反射子类 3 点(起+墙+反射后止)")
	_check(p2[1] == Vector2(128, 150), "反射点在墙表面 x=128")
	_check(p2[2].x > 128.0, "反射后继续向右(离开墙面)")
	_check(c2.size() == 1 and c2[0] == Vector2i(1, 2), "接触格 = 墙格 (1,2)")

	# ── 三缝存在 + PvP 权威门控 + 上报取后即清(读源码字符串,防接口漂移)──
	var base_src := FileAccess.get_file_as_string("res://scenes/weapons/laser_weapon_base.gd")
	var gun_src := FileAccess.get_file_as_string("res://scenes/weapons/laser_gun.gd")
	_check(gun_src.contains("extends LaserWeaponBase"), "laser_gun extends LaserWeaponBase")
	for seam in ["func _emit_beam", "func _apply_beam_damage", "func _spawn_beam_visual",
			"func collect_pending_beam_report", "func _make_beam_report"]:
		_check(base_src.contains(seam), "基类含可覆写缝/上报口: " + seam)
	_check(base_src.contains("return not Level0.pvp_mode"), "权威门控走 Level0.pvp_mode(与出弹同 gate)")

	# ── 上报 round-trip:字段齐全 + 取后即清 ──
	var w2: Variant = BaseScript.new()
	w2.laser_color = Color(0.1, 0.35, 1.0, 1.0)
	w2.beam_half_width = 3.0
	w2.beam_lifetime = 0.4
	var rep_pts := PackedVector2Array([Vector2(1, 2), Vector2(3, 4)])
	var rep: Dictionary = w2._make_beam_report(rep_pts)
	_check(rep.has("pts") and rep.has("origin") and rep.has("canonical") and rep.has("color")
			and rep.has("half_width") and rep.has("lifetime") and rep.has("style"),
			"上报 dict 字段齐全(pts/origin/canonical/color/half_width/lifetime/style)")
	_check(rep["pts"] == rep_pts and rep["half_width"] == 3.0 and rep["style"] == 0, "上报字段值正确")
	w2.pending_beam_report = rep
	var taken: Dictionary = w2.collect_pending_beam_report()
	_check(taken == rep, "collect_pending_beam_report 首次取到上报")
	_check(w2.collect_pending_beam_report().is_empty(), "collect_pending_beam_report 二次为空(读到即清)")

	# ── 远端"粘副本"公式:跨接缝原始 pts 逐点锚到射手副本渲染位置 → 全落在可见副本、连续 ──
	var w_map := 9600.0   # factory 图宽
	var h_map := 6400.0
	var anchor := Vector2(9500, 1500)      # 射手副本已渲染在本地附近的副本
	var raw := PackedVector2Array([Vector2(100, 1500), Vector2(600, 1500), Vector2(1100, 1500)])
	var glued := PackedVector2Array()
	for p in raw:
		glued.append(MazeGenerator.anchor_to_nearest(p, anchor, w_map, h_map))
	var all_near := true
	var monotonic := true
	for i in range(glued.size()):
		var q: Vector2 = glued[i]
		if absf(q.x - anchor.x) > w_map * 0.5:
			all_near = false
		if i > 0 and glued[i].x <= glued[i - 1].x:
			monotonic = false
	_check(all_near, "跨接缝光束逐点锚后全部落在可见副本(与 anchor 各轴差 ≤ 半图)")
	_check(monotonic and glued[0].x > 9000.0, "逐点锚保持折线连续递增(不撕裂)")

	# 释放 _new() 出的 Node 实例,避免 -s 退出时 ObjectDB/RID 泄漏噪音
	base_weapon.free()
	gun.free()
	w2.free()

	if _failures.is_empty():
		print("SMOKE OK")
		quit(0)
	else:
		printerr("SMOKE FAILURES: " + str(_failures.size()))
		quit(1)

func _make_grid(cols: int, rows: int) -> Array[Array]:
	var g: Array[Array] = []
	for y in range(rows):
		var row: Array[int] = []
		row.resize(cols)
		row.fill(MazeGenerator.EMPTY)
		g.append(row)
	return g
