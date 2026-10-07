extends ProbeBase

# 武器命名纪律 + **上行传 inst** 的守卫(§4.1)。
# 跑法:
#   "$GODOT" --headless --path . --quit-after 3600 res://tests/probe/weapon_switch_inst_probe.tscn
# 判据:文本 `KH weapon-inst PROBE: ALL-OK`(grep 文本,**不看退出码**)。
#
# ═══ 本探针要守的那件事 ═══
# 上行包**曾**带"背包位置(1-based)",服务器用**它自己的** held 数组解(`equip_index(wslot - 1)`)。
# 拾取/丢弃是服务器裁决、客户端不预测  ->  那 ≈1 RTT 的窗口里同一个下标在两端解出**不同的枪**
# ——「切不动 / 切到另一把」的结构性来源。改成上行 **inst**(逐把唯一)之后,两端 held 的**顺序**
# 不再是前提。
#
# ═══ 为什么阶段 2 要写 `has_method` + `Object.call()` ═══
# 新 API(`take_uplink_switch` / `equip_inst` / `inst_at_index` / `push_switch_inst` /
# `PlayerInput.consume_switch_inst`)在改动前**不存在**。
# 若在**带类型标注**的变量上直接调它们,整份脚本是 **Parse Error** —— 那意味着本探针
# **一行都不打印**(判据 grep 不到 = 红,但红的形状是"跑不起来"而不是"断言失败",读者看不出是哪一件事)。
# 故:① 阶段 1 用**源码级断言**把"新 API 还没实现"变成**具名红**;
#     ② 阶段 2/③/④ 一律走 `Object.call("…")`(**动态派发,不需要符号存在**)+ `has_method` 守卫,
#        守卫缺失时记一条**具名失败**并跳过解引用(绝不静默 return)。
#     ③ 每个带守卫的相最后留**完成戳**(`_require_ran`,照 `tests/probe/rollback_fidelity_probe.gd` 的先例):
#        守卫哪天被写成静默 `return`,整相消失而 verdict 照打 ALL-OK —— 那是本仓抓过的测试漏检形状。

func probe_id() -> String:
	return "weapon-inst"


# 带守卫的相的完成戳:没跑到最后一行  ->  本趟读数不可信。
var _ran: Dictionary = {}


func _require_ran(name: String) -> void:
	if not _ran.has(name):
		_check(false, "%s 没跑到最后一行(被跳过或中途报错)→ 本趟读数不可信" % name)


# 某个玩家手上那把的 **inst**;空手/越界返回 -1(与 type_id 区分开:同型号两把 type_id 恒等)。
func _inst_of(p: Node2D) -> int:
	var w = p.weapons
	var i: int = w._current_index
	if i < 0 or i >= w.inventory.held.size():
		return -1
	return int(w.inventory.held[i]["inst"])


# 合成平地:本探针只验"切枪解析成哪一把",不需要任何关卡几何。
const COLS := 40
const ROWS := 12


func _build_grid() -> Array[Array]:
	var grid: Array[Array] = []
	for y in range(ROWS):
		var row: Array[int] = []
		for x in range(COLS):
			row.append(31 if y == ROWS - 1 else 0)
		grid.append(row)
	return grid


func _ready() -> void:
	# - 必须 `await _run()` 再 `_finish()`(与 `laser_team_probe` 相同机制,**只此一处** `_finish()`)。
	#   为什么不能写成 `_run(); _finish()`:`_run()` 是个协程,同步调它会在它**第一个 await
	#   处**就返回(`_run` 尾部那三帧等待),于是 `quit()` 排在等待**之前** —— 那三帧就不等了,
	#   `call_deferred("add_child")` 加入场景树的武器可能连同玩家一起被计成退出期泄漏
	#   (`N ObjectDB instances / 1 RID leaked`,实测踩过)。断言本身不受影响,受影响的只是收尾。
	await _run()
	_finish()


func _run() -> void:
	_phase_source_contract()
	_phase_downlink_key()
	_require_ran("downlink_key")
	_phase_opposite_order()
	_require_ran("opposite_order")
	_phase_missing_inst()
	_require_ran("missing_inst")
	_phase_index_resolution()
	_require_ran("index_resolution")
	# - 收尾等几帧:见 `_ready()` 的注释。-  **这里不调 `_finish()`** —— 它归 `_ready()`,
	#   两处都调会把 verdict 打两遍(初稿就是两处都调,被评审检测暴露)。
	for i in 3:
		await get_tree().physics_frame


# ── 阶段 1 源码级:协议与解析点的形状(-  改动前**逐条红**)──
func _phase_source_contract() -> void:
	var before := _failures.size()
	var wc := _code_only(_read("res://scenes/player/weapon_component.gd"))
	var pl := _code_only(_read("res://scenes/player/player.gd"))
	var pis := _code_only(_read("res://core/net/packet_input_source.gd"))
	var pmc := _code_only(_read("res://scenes/pvp_match_client.gd"))

	var rnc := _func_body(wc, "request_net_cycle")
	_check(not rnc.is_empty(), "request_net_cycle 找得到")
	# - 这条**接管**了 net_ground_probe ④c 原先那条(它断言的是 `push_net_slot(next + 1)` —— 被本 Task 反证)。
	_check(rnc.contains("push_switch_inst(inst_at_index("),
			"滚轮待发值不是**目标那把的 inst** —— 传背包位置会让两端 held 顺序不同时切到不同的枪")

	_check(pis.contains("\"winst\":"),
			"pack_record 没产出 winst 键(上行传的还是寻址方式,不是解析结果)")
	_check(not pis.contains("\"weapon\":"),
			"pack_record 还在产出旧键 \"weapon\" —— 同名不同义正是本设计要消灭的东西")

	var pmcp := _func_body(pmc, "_physics_process")
	_check(pmcp.contains("take_uplink_switch("),
			"客户端组包没走 take_uplink_switch —— 数字键那条上行的还是背包位置")
	_check(pmcp.contains("pkt[\"winst\"]"), "客户端组包没把 winst 塞进输入包")

	var plp := _func_body(pl, "_physics_process")
	_check(plp.contains("consume_switch_inst()"),
			"player.gd 没读 input_source.consume_switch_inst() —— 上行 inst 没人消费")
	_check(plp.contains("equip_inst("), "player.gd 没按 inst 切枪")
	# - 与 net_ground_probe:144 那条**同一个字符串、方向相反** —— 本 Task 把那条改写掉,这一条接管。
	_check(not plp.contains("equip_index(wslot"),
			"player.gd 还在按**背包位置**解上行值 —— 两端 held 顺序不同时会切到不同的枪")
	_summary(before, "相① 协议与解析点的形状")


# ── 阶段 5 下行:世界包的"拿的是哪种枪"字段叫 type_id,且**两端同名**(-  改动前逐条红)──
# - 为什么必须**两端一起**断言:只改一端**不报错** —— 副本那句 `data.get("type_id", 0)`
#   读不到键会拿到默认 0  ->  副本**一直空手**(对手的枪凭空消失)。这是本批唯一
#   "改一半完全静默"的地方,故判据是**一对**而不是一条。
func _phase_downlink_key() -> void:
	var before := _failures.size()
	var mss := _code_only(_read("res://server/match/match_snapshot.gd"))
	var pre := _code_only(_read("res://scenes/player/player_replica.gd"))
	# - 2026-10-02 降精度:三条都别再钉右侧表达式/默认值 —— 意图是"键名对不对",不是"值怎么取"。
	_check(mss.contains("\"type_id\":"),
			"下行快照生产端没把 weapon 字段改名 type_id")
	_check(not mss.contains("\"weapon\":"),
			"下行快照生产端还发着旧键 weapon —— 与上行同名不同义")
	_check(pre.contains("\"type_id\""),
			"副本没读 type_id —— 生产端改了名而它照旧读 weapon 的话,副本会**静默空手**")
	_summary(before, "相⑤ 下行键两端同源")
	_ran["downlink_key"] = true


# ── 阶段 2 两端 held 顺序相反 → 按同一个键必须切到同一把 ──
# 构造(与 spec §7 判据 2 相同机制,但走的是**真生产函数**而不是手搓的算术):
#   客户端 held = [重狙 inst=2, 手枪 inst=1]   ← 与服务器**反序**
#   服务器 held = [手枪 inst=1, 重狙 inst=2]
# 两边都从位置 0 起手  ->  **两端一开始拿的就是不同的枪**(本身就是那条 bug 的现场)。
func _phase_opposite_order() -> void:
	var before := _failures.size()
	MazeGenerator.current_grid = _build_grid()
	TileDefs.load_defs()
	GameParameters.refresh_map_size()
	# - 两个真 player.tscn:一端当客户端(LocalInputSource)、一端当服务器(PacketInputSource)。
	#   `_equip_index` 需要 `body.weapon_slot` 非空 —— 只有真 player.tscn 有那个挂点。
	var p_c: Node2D = preload("res://scenes/player/player.tscn").instantiate()
	p_c.set_input_source(LocalInputSource.new())
	add_child(p_c)
	var p_s: Node2D = preload("res://scenes/player/player.tscn").instantiate()
	p_s.set_input_source(PacketInputSource.new())
	add_child(p_s)
	# - `set_enabled_types` 的形参是 **`Array[int]`**:传无类型字面量 `[]` 会在运行期报
	#   "does not have the same element type as the expected typed array argument" 并**当场中断
	#   本函数** —— 阶段 2 会在建好玩家之后、摆背包之前就死掉,红成 `_require_ran` 那条完成戳
	#   (而不是下面那条具名的"§4.1 的落点还没实现")。故这里必须用**带类型**的空数组。
	#   语义与 `[]` 逐字相同:不传 = 没有任何类型被禁 = 六种全开(也是 `enabled_types` 的默认值)。
	var none_disabled: Array[int] = []
	p_c.weapons.set_enabled_types(none_disabled)
	p_s.weapons.set_enabled_types(none_disabled)
	# want_inst 传 0  ->  走"按类型保底处理",两端都会落到空手;随后各自 equip_index(0) 摆成既定状态。
	p_c.weapons.restore_inventory([
			{"type": 3, "inst": 2, "mag": -1},
			{"type": 1, "inst": 1, "mag": -1}], 0)
	p_s.weapons.restore_inventory([
			{"type": 1, "inst": 1, "mag": -1},
			{"type": 3, "inst": 2, "mag": -1}], 0)
	p_c.weapons.equip_index(0)      # 客户端手上 = 位置 0 = 重狙 inst 2
	p_s.weapons.equip_index(0)      # 服务器手上 = 位置 0 = 手枪 inst 1
	_check(_inst_of(p_c) == 2 and _inst_of(p_s) == 1,
			"前置:两端起手必须是**不同的枪**(客户端 inst=%d、服务器 inst=%d)" % [_inst_of(p_c), _inst_of(p_s)])

	# ── 对照组:旧语义(上行"背包位置"、服务器按位置解) ->  两端分家 ──
	# - 这是一条**特征化**断言(它断言的是"分歧确实存在",故恒真、不红不绿)。它存在的唯一
	#   理由是证明阶段 2 不是恒真的:同一对背包、同一个键,只换解的量纲就**分家**。
	# - 必须**完整走一遍旧链路**,不能只改服务器那一步 —— 旧链路里客户端**也**本地切了
	#   (同一次按键),所以上行的"位置 2"对应客户端的**位置 1**(手枪 inst 1),
	#   而服务器的位置 1 是**另一把**(重狙 inst 2)。只改服务器那一步会得出"两端相等"
	#   (两端都落在 inst 2),那条断言会红 —— 而它红得没有意义(是探针写错了,不是发现了 bug)。
	p_c.weapons.equip_index(1)        # 旧链路:客户端本地切到**它的**位置 1 → 手枪 inst 1
	_check(_inst_of(p_c) == 1, "对照组:客户端本地切到 inst=1(实际 %d)" % _inst_of(p_c))
	p_s.weapons.equip_index(2 - 1)    # 旧消费端:服务器按**它自己的**位置解 key_index - 1 → 位置 1
	_check(_inst_of(p_s) != _inst_of(p_c),
			"对照组:按位置解时两端**不同把**(客户端 %d / 服务器 %d)—— 这正是要修的分歧"
					% [_inst_of(p_c), _inst_of(p_s)])

	# ── 新语义:客户端本地解析成 inst → 过真 PacketInputSource → 服务器按 inst 解 ──
	var missing: Array[String] = []
	for m in ["take_uplink_switch", "equip_inst", "inst_at_index", "push_switch_inst"]:
		if not p_c.weapons.has_method(m):
			missing.append(m)
	if not p_s.input_source.has_method("consume_switch_inst"):
		missing.append("PlayerInput.consume_switch_inst")
	if not missing.is_empty():
		_check(false, "§4.1 的落点还没实现,相② 无法执行:缺 %s" % str(missing))
		_ran["opposite_order"] = true
		return

	# 1) 客户端滚轮:走**生产函数** `request_net_cycle` —— 它一次做完两件事:
	#    本地立即切(`_equip_index`)+ 把**目标那一把的 inst** 记进待发槽(`push_switch_inst`)。
	#    注意： 必须用 `request_net_cycle`,**不能**用 `cycle_index` —— 后者是**单机**那条路
	#       (`weapon_component.gd:116-122`),只做 `_peek_cycle` + `_equip_index`,**从不 push**;
	#       用它的话 `take_uplink_switch` 恒读到 0,这一相**永远绿不了**。
	#       PvP 与单机的分叉在 `player.gd` 的滚轮分支(`Level0.pvp_mode` → `request_net_cycle`)。
	p_s.weapons.equip_index(0)        # 把两端都摆回位置 0 再走一遍
	p_c.weapons.equip_index(0)
	p_c.weapons.request_net_cycle(1)  # 位置 0 → 位置 1(客户端的位置 1 = 手枪 inst 1)
	_check(_inst_of(p_c) == 1, "客户端本地已切到 inst=1(实际 %d)" % _inst_of(p_c))
	var uplink: int = int(p_c.weapons.call("take_uplink_switch", 0))
	_check(uplink == 1, "上行必须是**目标那把的 inst**(=1),实际 %d" % uplink)

	# 2) 过真解码端:组包 → apply_packet → 服务器取走(与生产相同机制;`clear_edges` 走 `MatchHost` 的口径)
	# - 显式标 Variant:`input_source` 是从 Node2D 上取的不安全访问,标了具体类型会让
	#   `clear_edges()` / `apply_packet()` 变成静态检查(它们不在 `PlayerInput` 上)。
	var srv_src: Variant = p_s.input_source
	srv_src.clear_edges()
	srv_src.apply_packet({"seq": 1, "ax": 0.0, "held": 0, "pressed": 0, "released": 0,
			"winst": uplink, "aim": Vector2.RIGHT})
	var winst: int = int(srv_src.call("consume_switch_inst"))
	_check(winst == 1, "服务器从包里取出的 winst 应为 1(实际 %d)" % winst)
	_check(int(srv_src.call("get_switch_index_pressed")) == 0,
			"网络输入源的**位置**读口必须恒 0(包里的值不是位置)")
	if winst > 0:
		p_s.weapons.call("equip_inst", winst)
	_check(_inst_of(p_s) == _inst_of(p_c),
			"★ 两端 held **顺序相反**时,按同一个键必须切到**同一把**(客户端 inst=%d、服务器 inst=%d)"
					% [_inst_of(p_c), _inst_of(p_s)])
	_ran["opposite_order"] = true
	_summary(before, "相② 两端反序 → 同一把")


# ── 阶段 3 服务器手里没有那把  ->  **静默不动**,不切到别的枪 ──
func _phase_missing_inst() -> void:
	var before := _failures.size()
	var p_s: Node2D = _players_server_side()
	if p_s == null or not p_s.weapons.has_method("equip_inst"):
		_check(false, "相③ 需要相② 建好的服务器侧玩家(或 equip_inst 缺失)")
		_ran["missing_inst"] = true
		return
	var t_before: int = p_s.weapons.current_type_id()
	var i_before := _inst_of(p_s)
	p_s.weapons.call("equip_inst", 999)
	_check(_inst_of(p_s) == i_before and p_s.weapons.current_type_id() == t_before,
			"服务器找不到该 inst 时必须**静默不动**(实测 inst %d → %d)" % [i_before, _inst_of(p_s)])
	p_s.weapons.call("equip_inst", 0)
	_check(_inst_of(p_s) == i_before, "equip_inst(0) 也必须不动(0 = 无请求)")
	_ran["missing_inst"] = true
	_summary(before, "相③ 找不到就不动")


# ── 阶段 4 数字键那条:1-based 背包位置 → 那一把的 inst ──
func _phase_index_resolution() -> void:
	var before := _failures.size()
	var p_c: Node2D = _players_client_side()
	if p_c == null or not p_c.weapons.has_method("inst_at_index"):
		_check(false, "相④ 需要相② 建好的客户端侧玩家(或 inst_at_index 缺失)")
		_ran["index_resolution"] = true
		return
	_check(int(p_c.weapons.call("inst_at_index", 0)) == 2,
			"位置 0 的 inst 应为 2(实际 %d)" % int(p_c.weapons.call("inst_at_index", 0)))
	_check(int(p_c.weapons.call("inst_at_index", 1)) == 1,
			"位置 1 的 inst 应为 1(实际 %d)" % int(p_c.weapons.call("inst_at_index", 1)))
	_check(int(p_c.weapons.call("inst_at_index", 9)) == 0,
			"越界位置必须返回 0(实际 %d)" % int(p_c.weapons.call("inst_at_index", 9)))
	# 数字键"2"(1-based)  ->  位置 1  ->  inst 1;且**必须把滚轮的待发值一起取走**(读一次即清,
	# 免得它漏到下一帧变成一次迟到的切枪 —— 与旧 consume_net_slot 相同机制)。
	p_c.weapons.call("push_switch_inst", 2)
	_check(int(p_c.weapons.call("take_uplink_switch", 2)) == 1,
			"数字键 2 应解析成位置 1 的 inst(=1)")
	_check(int(p_c.weapons.call("take_uplink_switch", 0)) == 0,
			"滚轮的待发值必须已被取走(第二问读到 %d,应为 0)" % int(p_c.weapons.call("take_uplink_switch", 0)))
	_ran["index_resolution"] = true
	_summary(before, "相④ 数字键按位置解析成 inst")


# 阶段 2 建的两位端玩家(位置固定:先 client 后 server)。
func _players_client_side() -> Node2D:
	for c in get_children():
		if c is Node2D and c.has_method("set_input_source") and c.input_source is LocalInputSource:
			return c
	return null


func _players_server_side() -> Node2D:
	for c in get_children():
		if c is Node2D and c.has_method("set_input_source") and c.input_source is PacketInputSource:
			return c
	return null
