extends SceneTree

# 武器背包纯逻辑冒烟。跑法(默认引擎路径):
#   "D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" \
#       --headless --path . -s res://tests/weapon_inventory_smoke.gd
# 通过 = `WEAPON_INVENTORY OK` 退出 0。
#
# ★ 在 _initialize() 里 load(),不用全局类名 —— 与 tile_query_smoke 的写法一致,
#   且 -s 阶段类名缓存不保证已就绪(见 CLAUDE.md「测试」一节)。
#
# ═══ 为什么需要它 ═══
# 背包有**两条独立的闸门**:8 格容量 与 4 把上限(用户 2026-09-15 明确裁定
# 「就算容量给 100 也最多四把」)。两条都容易在改动中被写成"其中一条推另一条",
# 而错了之后的表现是"某些组合莫名捡不起来"——日常很难复现。
# 另一半钉的是**残弹按 inst 记账**:允许持有同类型两把,若按类型记账,
# 「丢一把空弹手枪、捡一把满地手枪」就变成免费换弹,而且完全不报错。

var _fail := 0


func _check(ok: bool, msg: String) -> void:
	if ok:
		return
	_fail += 1
	print("[FAIL] ", msg)


func _initialize() -> void:
	var WI: GDScript = load("res://core/sim/weapon_inventory.gd")
	# ★ 空载守卫:load() 失败时若继续往下走,_initialize() 会在 WI.new() 处抛错,
	#   而 **-s 脚本抛错就走不到 quit() → 进程永久挂起**(本仓踩过,见 tile_query_smoke 的注释)。
	#   这里显式退 1,让"文件不存在"表现为干净的红,而不是超时。
	if WI == null:
		print("WEAPON_INVENTORY FAILED: 找不到 core/sim/weapon_inventory.gd")
		quit(1)
		return

	# 假 tier 表:1/2 = 轻(2格),3/4 = 中(3格),5/6 = 重(4格)
	var tiers := {1: 0, 2: 0, 3: 1, 4: 1, 5: 2, 6: 2}

	# ── 容量与把数上限是两条**独立**闸门 ──
	var inv = WI.new(tiers)
	_check(inv.used_slots() == 0, "空背包占 0 格")
	_check(inv.can_hold(5), "空背包放得下重武器")
	inv.add(1, 5)           # 轻,2 格
	inv.add(2, 5)           # 轻,2 格
	inv.add(3, 5)           # 中,3 格 → 共 7 格 / 3 把
	_check(inv.used_slots() == 7, "2轻+1中 = 7 格(实际 %d)" % inv.used_slots())
	_check(not inv.can_hold(5), "7 格放不下 4 格的重武器(容量闸门)")
	# 7 格只剩 1 格,而最便宜的档是 2 格 → 此时**什么都放不下**
	# (这里原先写成"放得下轻武器",是我把 7+2=9 看成了 8 —— 测试自己算错,
	#  实现拒绝加才是对的。留着这条是因为它正好钉住"闸门按剩余格数算,不是按把数算")
	_check(not inv.can_hold(1), "7 格只剩 1 格,放不下 2 格的轻武器")
	# 闸门要是"卡死"就测不出上面那些了 —— 腾出格后必须重新放得下
	var freed: Dictionary = inv.remove_at(2)
	_check(int(freed["type"]) == 3, "腾出的是中武器")
	_check(inv.used_slots() == 4 and inv.held.size() == 2, "腾出后 4 格 / 2 把")
	_check(inv.can_hold(5), "腾出后放得下 4 格的重武器(4+4=8)")

	# 恰好占满 8 格:任何一档(最便宜 2 格)都放不下了
	var inv_b = WI.new(tiers)
	inv_b.add(1, 5)         # 轻 2
	inv_b.add(5, 5)         # 重 4
	inv_b.add(2, 5)         # 轻 2 → 8 格 / 3 把
	_check(inv_b.used_slots() == 8 and inv_b.held.size() == 3, "恰好 8 格 / 3 把")
	_check(not inv_b.can_hold(1), "满容量后最便宜的档也放不下")

	# ★ 关于"把数闸门独立于容量闸门"的实话:**按今天的 cost 表,它其实是被容量蕴含的** ——
	#   最便宜的轻武器 2 格,4 把 × 2 = 8 = CAPACITY,所以 used_slots() ≤ 8 已经蕴含 size ≤ 4。
	#   没法用真表造出"容量还有余、但已满 4 把"的局面(要造就得有 cost=1 的档)。
	#   但它**不是死代码**:用户 2026-09-15 把它定为硬规则(「就算容量给 100 也最多四把」),
	#   而一旦有人把轻武器改成 1 格 / 把 CAPACITY 调大,"最多 4 把"这个承诺就只靠这一条守着了。
	#   这里退而钉住常量本身 + 那个临界等式,别假装验了闸门的独立性。
	_check(int(WI.MAX_WEAPONS) == 4, "MAX_WEAPONS 必须恰好是 4")
	_check(int(WI.CAPACITY) == 8, "CAPACITY 必须恰好是 8")
	_check(int(WI.SLOT_COST[int(WI.TIER_LIGHT)]) == 2, "轻武器必须恰好占 2 格")
	_check(int(WI.SLOT_COST[int(WI.TIER_LIGHT)]) * int(WI.MAX_WEAPONS) == int(WI.CAPACITY),
		"轻武器 cost × 4 应恰好等于容量(这条等式一旦不成立,上面那条注释就该重写)")
	var inv_y = WI.new(tiers)
	for i in 4:
		inv_y.add(1, 5)     # 4 把轻武器 = 8 格,把数与容量同时到顶
	_check(inv_y.held.size() == 4 and inv_y.used_slots() == 8, "4 把轻武器 = 4 把 / 8 格")
	_check(not inv_y.can_hold(1), "4 把轻武器后不能再装")

	# ── 紧凑排布 ──
	var inv3 = WI.new(tiers)
	inv3.add(1, 5)          # 轻 2
	inv3.add(5, 5)          # 重 4
	_check(inv3.slot_start(0) == 0, "第 0 把起始格 = 0")
	_check(inv3.slot_start(1) == 2, "第 1 把起始格 = 2(实际 %d)" % inv3.slot_start(1))

	# ── 允许重复:两把同类型各有各的 inst 与残弹 ──
	var inv4 = WI.new(tiers)
	var a: int = inv4.add(1, 11)
	var b: int = inv4.add(1, 3)
	_check(a != b, "同类型两把的 inst 不同(%d vs %d)" % [a, b])
	_check(inv4.held.size() == 2, "允许持有两把同类型武器")
	_check(inv4.index_of_inst(b) == 1, "index_of_inst 找得到第二把")
	_check(inv4.first_index_of_type(1) == 0, "first_index_of_type 返回第一把")

	# ── 删中间条目:后面的索引与残弹不错位 ──
	var inv5 = WI.new(tiers)
	inv5.add(1, 11)         # idx 0
	inv5.add(3, 22)         # idx 1
	inv5.add(6, 33)         # idx 2
	var gone: Dictionary = inv5.remove_at(1)
	_check(int(gone["mag"]) == 22, "remove_at 返回被删条目的残弹(实际 %s)" % str(gone))
	_check(inv5.held.size() == 2, "删后剩 2 条")
	_check(int(inv5.held[0]["mag"]) == 11 and int(inv5.held[1]["mag"]) == 33,
		"删中间条目后其余残弹不串位")
	_check(inv5.slot_start(1) == 2, "删后第 1 把起始格重算 = 2(实际 %d)" % inv5.slot_start(1))

	# ── 快照 / 恢复 ──
	var snap: Array = inv5.snapshot()
	_check(snap.size() == 2, "snapshot 出 2 条")
	var inv6 = WI.new(tiers)
	inv6.restore(snap)
	_check(inv6.held.size() == 2 and int(inv6.held[1]["type"]) == 6,
		"restore 后类型正确")
	_check(inv6.used_slots() == inv5.used_slots(), "restore 后占用格一致")
	# restore 必须把 _next_inst 顶到已用 inst 之上,否则新加的条目会与旧条目撞 inst
	# (inst 是"哪把是哪个"的唯一凭据,撞了 = 残弹串到另一把枪上)
	var c: int = inv6.add(1, 0)
	_check(inv6.index_of_inst(c) == 2 and c > int(inv5.held[1]["inst"]),
		"restore 后新加的 inst 不与已有条目冲突")

	# ── clear ──
	inv6.clear()
	_check(inv6.held.is_empty() and inv6.used_slots() == 0, "clear 清空持有表")

	if _fail == 0:
		print("WEAPON_INVENTORY OK")
		quit(0)
	else:
		print("WEAPON_INVENTORY FAILED: %d" % _fail)
		quit(1)
