extends ProbeBase

# 地面武器**联机**的源码级守卫(场景模式;判据 grep `NET GROUND PROBE: ALL-OK`)。
#
#   ★ 安全网给足(3600 帧):探针正常跑完会自己 quit(),这个值**只在探针挂住时**才用得上 ——
#     放宽不花任何代价。原先的 600/900 在机器负载重时可能**先耗尽**、探针来不及跑完
#     就被掐断(表现为"一行 ALL-OK 都没有",看着像功能坏了)。
# 跑法:
#   "$GODOT" --headless --path . --quit-after 3600 res://tests/net_ground_probe.tscn
#
# ═══ 为什么需要它 ═══
# 本仓有两套并存的 RPC 总线(`NetBus` 与 `NetBusExt`),而它们**已经有一对重名函数**
# (`beam_fired`)。挂错节点的表现是**静默 no-op** —— 对手的枪凭空消失、且不报任何错。
# 这类错误写代码时看不出来、跑起来也不报,只有"两边名字集不重叠"这条断言拦得住。
# 其余几条钉的是"加了字段但漏了某处"的同族问题。


func probe_id() -> String:
	return "net-ground"


func _ready() -> void:
	# ★ 一律用**去注释视图**:本仓的注释里大量出现这些标识符(比如这条注释本身),
	#   裸 contains 会把注释当成代码(探针自己把自己喂绿)。
	var nb := _code_only(_read("res://core/net/net_bus.gd"))
	var nbe := _code_only(_read("res://core/net/net_bus_ext.gd"))
	var pmc := _code_only(_read("res://scenes/pvp_match_client.gd"))
	var pl := _code_only(_read("res://scenes/player/player.gd"))
	var pr := _code_only(_read("res://core/net/prediction_rollback.gd"))
	var mg := _code_only(_read("res://server/match_ground.gd"))
	var mh := _code_only(_read("res://server/match_host.gd"))

	_check(nb != "" and nbe != "" and pmc != "", "核心文件读得到")
	if nb == "" or nbe == "" or pmc == "":
		_finish()
		return

	# ① NetBus 必须有两条事件 RPC 与两个 local_ 信号
	_check(nb.contains("func weapon_spawned("), "NetBus 缺 weapon_spawned")
	_check(nb.contains("func weapon_removed("), "NetBus 缺 weapon_removed")
	_check(nb.contains("signal local_weapon_spawned("), "NetBus 缺 local_weapon_spawned 信号")
	_check(nb.contains("signal local_weapon_removed("), "NetBus 缺 local_weapon_removed 信号")

	# ② ★ 反向断言:NetBusExt **不得**有同名函数/信号。
	#    (与 beam_fired 同款的重名陷阱:重名 = 接收端挂错 = 静默 no-op。)

	_check(not nbe.contains("func weapon_spawned("),
			"NetBusExt 里出现了 weapon_spawned —— 重名会让挂错节点的那端静默收不到")
	_check(not nbe.contains("func weapon_removed("),
			"NetBusExt 里出现了 weapon_removed —— 同上")
	_check(not nbe.contains("signal local_weapon_spawned"),
			"NetBusExt 里出现了 local_weapon_spawned")

	# ③ 客户端订阅的必须是 **NetBus** 的那一对
	_check(pmc.contains("NetBus.local_weapon_spawned.connect"),
			"客户端没有订阅 NetBus.local_weapon_spawned")
	_check(pmc.contains("NetBus.local_weapon_removed.connect"),
			"客户端没有订阅 NetBus.local_weapon_removed")
	_check(not pmc.contains("NetBusExt.local_weapon_"),
			"客户端把地面武器事件挂到了 NetBusExt(会静默 no-op)")

	# ③b ★ 丢弃的"长按满"必须是**边沿**而不是"Q 按着"。
	#    真实出现过的 bug:LocalInputSource 的 drop 读口返回 `Input.is_action_pressed("Q")`,
	#    于是联机端**碰一下 Q 就丢枪**(长按 2s 规则形同虚设),而且按住不放每 tick 丢一把。
	var lis := _code_only(_read("res://core/net/local_input_source.gd"))
	var body := _func_body(lis, "_drop_pressed_raw")
	_check(not body.contains("Input.is_action_pressed"),
			"LocalInputSource._drop_pressed_raw 读的是「Q 按着」而不是「长按满的边沿」")
	_check(body.contains("_drop_edge"), "LocalInputSource._drop_pressed_raw 应读一次性边沿标志")
	# 反向锚:计时确实在 player 里做,且联机分支会打这个标
	_check(pl.contains("mark_drop_edge"), "player 没在长按满时打边沿标")
	# 反向锚:计时确实在 player 里跑(联机分支会打这个标),而不是整个早退掉
	_check(pl.contains("mark_drop_edge"), "player 没在长按满时打边沿标")
	_check(_func_body(pl, "_poll_pickup_drop").contains("_drop_latched"),
			"player._poll_pickup_drop 里没有长按闩锁(计时没跑?)")

	# ③c 拾取提示必须是**逐把**判定(用户 2026-09-16「只要能捡起就会显示 F」),
	#     而不是"只管最近那把"。判据:两个调用点都不许用 nearest_within 选目标。
	var l0 := _code_only(_read("res://scenes/level_0.gd"))
	var l0body := _func_body(l0, "_update_pickup_prompt")
	var clbody := _func_body(pmc, "_update_pickup_prompt")
	for b in [l0body, clbody]:
		_check(not b.is_empty(), "_update_pickup_prompt 找得到")
		_check(not b.contains("nearest_within"),
				"拾取提示又回到「只提示最近那把」了 —— 用户要的是**每把能捡的**都提示")
		_check(b.contains("set_prompt_visible"), "拾取提示没有逐把开关")
	_check(_read("res://ui/pickup_prompt.gd").contains("const BOX"),
			"PickupPrompt 常量不见了(文件被换?)")

	# ③d 提示的"自己刚丢下的"排除:服务器要把 by_role 告诉客户端(那条 0.5s 冷却
	#     只有权威知道),客户端要按它排除 —— 否则刚丢下的枪会显示 F 却捡不起来。
	_check(_read("res://server/match_ground.gd").contains("\"by_role\":"),
			"weapon_spawned 载荷里没有 by_role")
	_check(_read("res://server/match_ground.gd").contains("_broadcast_weapon_spawned(ni, role)")
			or _read("res://server/match_ground.gd").contains("_broadcast_weapon_spawned(inst, role)"),
			"丢枪/换枪那条广播没带上角色")
	_check(pmc.contains("_self_drop_until"), "客户端没记自己刚丢下的那把")
	_check(clbody.contains("_live_self_drops"), "客户端的提示判定没排除自己刚丢下的")

	# ④ 背包进整态:capture 里有 inv,而 `_close_enough` 里**没有**
	_check(pl.contains("\"inv\""), "player.capture_state 里没有 inv")
	_check(pl.contains("restore_inventory"), "player.restore_state 里没有重建背包")
	_check(not pr.contains("\"inv\""),
			"_close_enough 里出现了 inv —— 它必须只进 capture/restore,进去就会每帧判分歧、无限回滚")
	_check(not pr.contains("inv"), "_prediction_rollback 里出现了 inv 字样(见上一条)")

	# ④b 换局重铺:**清的与铺的都必须广播**,且 inst 编号不得回退。
	#     换局是客户端唯一"既不重进场景、也不再拉 match_sync"的时刻 —— 不广播 = 它留着一整批
	#     上一局的幽灵枪(按 F 无效),而新一轮那批在它那儿一件都不存在(表现正是"地上的枪
	#     捡不起来,只能捡后来丢弃的")。`_next_ground_inst = 1` 会让新一轮与客户端残留节点
	#     **撞号**,而 `_spawn_pickup_node` 对已有 inst 是静默 return。
	var rb := _func_body(mg, "_reset_ground_weapons")
	_check(not rb.is_empty(), "_reset_ground_weapons 找得到")
	_check(rb.contains("_broadcast_weapon_removed"),
			"换局清空没广播 weapon_removed —— 客户端会留下一整批上一局的幽灵枪")
	_check(rb.contains("_broadcast_weapon_spawned"),
			"换局重铺没广播 weapon_spawned —— 新一轮那批在客户端一件都建不出来")
	_check(not rb.contains("_next_ground_inst = 1"),
			"换局把 _next_ground_inst 重置回 1 —— 新一轮会与客户端残留节点撞号(客户端静默拒绝建档)")
	# ★ **反向断言**:客户端那一侧**不得**在换局时自己清空地面武器。
	#   真写过一版(以为"漏收一条事件会留幽灵枪,清一次自愈"),结果是**反向**的破坏:
	#   服务器的顺序是「先 `_reset_ground_weapons` 广播 removed×旧 + spawned×新,**再**
	#   `_broadcast_round_state`」,两条走同一条可靠通道、保序 → 客户端收到新一轮 COUNTDOWN 时
	#   那批新枪**早已建好**,再清一次 = 第 2 局起客户端地面恒为空(服务器有 10 把,客户端
	#   一把都看不见、只能捡后来的丢弃物 —— 正是要修的那个症状)。清旧的只由服务器那两条
	#   有序事件负责;真漏收了,掉线重进会重新拉 match_sync 兜住。
	var pg := _code_only(_read("res://scenes/pvp_game.gd"))
	_check(not pg.contains("clear_ground_weapons"),
			"pvp_game 又在换局时清空地面武器了 —— 那会把服务器刚广播来的新一轮那批一起抹掉(见这条注释)")
	_check(not pmc.contains("func clear_ground_weapons"),
			"pvp_match_client 里又出现了 clear_ground_weapons —— 换局的清理只走服务器事件,别在客户端加第二条路")

	# ④c 切枪包字段**两端同量纲 = 背包位置(1-based)**。
	#     滚轮曾经上行"武器类型 id",而消费端按位置读(`equip_index(字段 - 1)`):背包
	#     `[步枪2, 手枪1]` 从步枪滚一下发 1 → 服务器切回步枪(等于没切);`[手枪1, 重狙3]` 发 3
	#     → 越界早退(压根没切)→ 权威 wslot 把客户端拉回 →「滚轮切不动」。
	var wc := _code_only(_read("res://scenes/player/weapon_component.gd"))
	var rnc := _func_body(wc, "request_net_cycle")
	_check(not rnc.is_empty(), "request_net_cycle 找得到")
	_check(not rnc.contains("push_net_slot(int(inventory.held"),
			"滚轮切枪又在发武器**类型 id** 了(消费端按背包位置读 → 切错/越界早退)")
	_check(rnc.contains("push_net_slot(next + 1)"),
			"滚轮切枪应上行背包位置(next + 1)")
	_check(_func_body(pl, "_physics_process").contains("equip_index(wslot - 1)"),
			"消费端不再是按背包位置切(equip_index(wslot - 1))—— 两条路径的量纲必须一致")

	# ⑤ 链规矩:MatchGround 是中间层,**不得**定义生命周期钩子
	for hook in ["func _init(", "func _ready(", "func _enter_tree(",
			"func _exit_tree(", "func _physics_process("]:
		_check(not mg.contains(hook),
				"MatchGround 定义了 %s —— 中间层不得有生命周期钩子(见 match_state.gd 的链规矩)" % hook)
	# 反向锚:它确实进了链(否则上面那条会因为文件不存在而假绿)
	_check(mg.contains("extends MatchState"), "MatchGround 应 extends MatchState")
	_check(mh.contains("_handle_ground_actions("), "MatchHost 没调 _handle_ground_actions")
	_check(mh.contains("_setup_ground_weapons("), "MatchHost 没调 _setup_ground_weapons")

	# ⑥ 开局那批**必须**走 match_sync 拉取,不能在 worker 里推送
	var sm := _code_only(_read("res://server/server_main.gd"))
	_check(sm.contains("ground_weapons"), "match_sync_data 载荷里没有 ground_weapons")
	for ident in ["local_ground_weapons", "pending_ground_weapons"]:
		_check(not (nb + nbe + sm).contains(ident),
				"出现了 %s —— 地面武器**只能**有一条投递路径(match_sync 拉取)" % ident)

	_finish()
