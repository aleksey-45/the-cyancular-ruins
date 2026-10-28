extends SceneTree

# 武器背包逻辑状态机冒烟测试：
# 验证背包容量负荷计算、多武器槽位切换、拾取/丢弃以及同类型武器区分。

var _fail := 0


func _check(ok: bool, msg: String) -> void:
	if ok:
		return
	_fail += 1
	print("[FAIL] ", msg)


func _initialize() -> void:
	var WI: GDScript = load("res://core/sim/weapon_inventory.gd")
	# - 空载防御性校验:load() 失败时若继续往下走,_initialize() 会在 WI.new() 处抛错,
	#   而 -s 脚本抛错就走不到 quit() -> 进程永久挂起(本仓踩过,见 tile_query_smoke 的注释)。
	#   这里显式退 1,让"文件不存在"表现为干净的红,而不是超时。
	if WI == null:
		print("WEAPON_INVENTORY FAILED: 找不到 core/sim/weapon_inventory.gd")
		quit(1)
		return

	# 假 tier 表:1/2 = 轻(2格),3/4 = 中(3格),5/6 = 重(4格)
	var tiers := {1: 0, 2: 0, 3: 1, 4: 1, 5: 2, 6: 2}

	var inv = WI.new(tiers)
	_check(inv.used_cell_count() == 0, "空背包占 0 格")
	_check(inv.can_hold(5), "空背包放得下重武器")
	inv.add(1, 5)           # 轻,2 格
	inv.add(2, 5)           # 轻,2 格
	inv.add(3, 5)           # 中,3 格 -> 共 7 格 / 3 把
	_check(inv.used_cell_count() == 7, "2轻+1中 = 7 格(实际 %d)" % inv.used_cell_count())
	_check(not inv.can_hold(5), "7 格放不下 4 格的重武器(容量闸门)")
	_check(not inv.can_hold(1), "7 格只剩 1 格,放不下 2 格的轻武器")
	# 门控前置校验要是"卡死"就测不出上面那些了 —— 腾出格后必须重新放得下
	var freed: Dictionary = inv.remove_at(2)
	_check(int(freed["type"]) == 3, "腾出的是中武器")
	_check(inv.used_cell_count() == 4 and inv.held.size() == 2, "腾出后 4 格 / 2 把")
	_check(inv.can_hold(5), "腾出后放得下 4 格的重武器(4+4=8)")

	# 恰好占满 8 格:任何一档(最便宜 2 格)都放不下了
	var inv_b = WI.new(tiers)
	inv_b.add(1, 5)         # 轻 2
	inv_b.add(5, 5)         # 重 4
	inv_b.add(2, 5)         # 轻 2 -> 8 格 / 3 把
	_check(inv_b.used_cell_count() == 8 and inv_b.held.size() == 3, "恰好 8 格 / 3 把")
	_check(not inv_b.can_hold(1), "满容量后最便宜的档也放不下")

	var wconsts: Dictionary = WI.get_script_constant_map()
	var def_cap := int(wconsts.get("DEFAULT_CAPACITY", -1))
	var def_max := int(wconsts.get("DEFAULT_MAX_WEAPONS", -1))
	_check(def_max == 4, "DEFAULT_MAX_WEAPONS 必须恰好是 4(实际 %d)" % def_max)
	_check(def_cap == 8, "DEFAULT_CAPACITY 必须恰好是 8(实际 %d)" % def_cap)
	_check(int(WI.CELL_COST[int(WI.TIER_LIGHT)]) == 2, "轻武器必须恰好占 2 格")
	_check(int(WI.CELL_COST[int(WI.TIER_LIGHT)]) * def_max == def_cap,
		"轻武器 cost × 4 应恰好等于容量(这条等式一旦不成立,上面那条注释就该重写)")
	var inv_y = WI.new(tiers)
	for i in 4:
		inv_y.add(1, 5)     # 4 把轻武器 = 8 格,把数与容量同时到顶
	_check(inv_y.held.size() == 4 and inv_y.used_cell_count() == 8, "4 把轻武器 = 4 把 / 8 格")
	_check(not inv_y.can_hold(1), "4 把轻武器后不能再装")

	var probe = WI.new(tiers)
	var has_capacity := false
	var has_max := false
	for pr in probe.get_property_list():
		# 遍历属性列表，查找 capacity 与 max_weapons
		var n := str(pr.get("name", ""))
		if n == "capacity":
			has_capacity = true
		elif n == "max_weapons":
			has_max = true
	_check(has_capacity, "WeaponInventory 应包含实例字段 capacity（支持动态配置）")
	_check(has_max, "WeaponInventory 应包含实例字段 max_weapons（支持动态配置）")
	if has_capacity and has_max:
		# ① 不带额外实参  ->  默认值不变(协议零改动的前提)
		var dflt = WI.new(tiers)
		_check(dflt.capacity == 8 and dflt.max_weapons == 4,
				"缺省构造 = 8 格 / 4 把(实际 %d / %d)" % [dflt.capacity, dflt.max_weapons])
		# ② 构造实参生效
		var wide = WI.new(tiers, 12, 6)
		_check(wide.capacity == 12 and wide.max_weapons == 6,
				"构造实参生效(实际 %d / %d)" % [wide.capacity, wide.max_weapons])
		wide.add(5, 5)
		wide.add(5, 5)
		wide.add(5, 5)                      # 三把重型 = 12 格(加起来正好到顶)
		_check(wide.used_cell_count() == 12,
				"宽松配置下三把重型 = 12 格(实际 %d)" % wide.used_cell_count())
		_check(not wide.can_hold(1), "背包容量满时无法继续添加新武器")
		# ③ 两条门控前置校验互相独立 —— 这是本节的核心断言,今天靠真表造不出来(见上面那段长注释)
		var by_cap = WI.new(tiers, 4, 9)
		by_cap.add(5, 5)                    # 重型 4 格 = 正好占满 4 格,而把数还剩 8
		_check(by_cap.used_cell_count() == 4,
				"容量 4 的背包放一把重型正好占满(实际 %d)" % by_cap.used_cell_count())
		_check(not by_cap.can_hold(1), "背包容量门控单独生效")
		var by_max = WI.new(tiers, 100, 1)
		by_max.add(1, 5)                    # 轻 2 格,容量还剩 98
		_check(by_max.used_cell_count() == 2,
				"容量 100 的背包放一把轻型只占 2 格(实际 %d)" % by_max.used_cell_count())
		_check(not by_max.can_hold(1), "武器数量门控单独生效")
		# ④ setter 路径
		by_max.set_capacity(0)
		by_max.set_max_weapons(0)
		_check(by_max.capacity >= 1 and by_max.max_weapons >= 1,
				"setter 必须将容量与数量下限钳制为 >= 1（实际 %d / %d）"
						% [by_max.capacity, by_max.max_weapons])
		by_max.set_capacity(12)
		by_max.set_max_weapons(6)
		_check(by_max.capacity == 12 and by_max.max_weapons == 6,
				"setter 设值生效(实际 %d / %d)" % [by_max.capacity, by_max.max_weapons])
	else:
		_check(false, "容量与武器数量配置测试被跳过（字段未就绪）")

	var inv3 = WI.new(tiers)
	inv3.add(1, 5)          # 轻 2
	inv3.add(5, 5)          # 重 4
	_check(inv3.cell_start(0) == 0, "第 0 把起始格 = 0")
	_check(inv3.cell_start(1) == 2, "第 1 把起始格 = 2(实际 %d)" % inv3.cell_start(1))

	var inv4 = WI.new(tiers)
	var a: int = inv4.add(1, 11)
	var b: int = inv4.add(1, 3)
	_check(a != b, "同类型两把的 inst 不同(%d vs %d)" % [a, b])
	_check(inv4.held.size() == 2, "允许持有两把同类型武器")
	_check(inv4.index_of_inst(b) == 1, "index_of_inst 找得到第二把")
	_check(inv4.first_index_of_type(1) == 0, "first_index_of_type 返回第一把")

	var inv5 = WI.new(tiers)
	inv5.add(1, 11)         # idx 0
	inv5.add(3, 22)         # idx 1
	inv5.add(6, 33)         # idx 2
	var gone: Dictionary = inv5.remove_at(1)
	_check(int(gone["mag"]) == 22, "remove_at 返回被删条目的残弹(实际 %s)" % str(gone))
	_check(inv5.held.size() == 2, "删后剩 2 条")
	_check(int(inv5.held[0]["mag"]) == 11 and int(inv5.held[1]["mag"]) == 33,
		"删中间条目后其余残弹不串位")
	_check(inv5.cell_start(1) == 2, "删后第 1 把起始格重算 = 2(实际 %d)" % inv5.cell_start(1))

	var snap: Array = inv5.snapshot()
	_check(snap.size() == 2, "snapshot 出 2 条")
	var inv6 = WI.new(tiers)
	inv6.restore(snap)
	_check(inv6.held.size() == 2 and int(inv6.held[1]["type"]) == 6,
		"restore 后类型正确")
	_check(inv6.used_cell_count() == inv5.used_cell_count(), "restore 后占用格一致")
	# restore 必须把 _next_inst 顶到已用 inst 之上,否则新加的条目会与旧条目撞 inst
	# (inst 是"哪把是哪个"的唯一凭据,撞了 = 残弹串到另一把枪上)
	var c: int = inv6.add(1, 0)
	_check(inv6.index_of_inst(c) == 2 and c > int(inv5.held[1]["inst"]),
		"restore 后新加的 inst 不与已有条目冲突")

	inv6.clear()
	_check(inv6.held.is_empty() and inv6.used_cell_count() == 0, "clear 清空持有表")

	if _fail == 0:
		print("WEAPON_INVENTORY OK")
		quit(0)
	else:
		print("WEAPON_INVENTORY FAILED: %d" % _fail)
		quit(1)
