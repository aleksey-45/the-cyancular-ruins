extends Node

# 统一大厅 `mp_lobby` 的创建房间弹层探针。
# 运行方式： "$GODOT" --headless --path . --quit-after 3600 res://tests/probe/lobby_create_form_probe.tscn
# 验收标准： 文本 `LOBBY CREATE FORM PROBE: ALL-OK(N 条断言)`(不看退出码 —— 探针阻塞挂起时 --quit-after
#       到期仍 exit 0 且一行 ALL-OK 都不打印,只看退出码会把"未完整执行"读成"通过")。
#
# ── 为什么需要它 ──
# - 弹层"按模式变形"的实暴露异常状静默无报错:`_apply_create_form` 按 `_form_rows[...]` 取容器
#   置 `visible`,而键名对不上不报错 —— 表现只是"那一行永远不隐藏"。这类"少登记一个键"的
#   缺陷没有任何运行时信号,只有断言看得见。
# - 3v3 关掉禁用武器网格和 1v1 关掉"公开/私密"都不是审美,是真的功能缺陷:
#   - 禁用武器的勾选框写的是 `Settings.pvp_disabled_weapons`(全局),在 3v3 页勾一下会
#     连带改掉另两个模式;
#   - 1v1 的 `create_room(caller)` 是原版 NetBus 的冻结签名、收不了 opts  ->  那一行的
#     "私密 + 邀请码"在 1v1 下永远不生效(服务端恒建公开房)= 骗人的控件。
#    ->  故阶段 5 / ⑧ 是有真实危害的断言,不是"版式检查"。
# 注意事项：前三段用不加入场景树实例(读 `_form_rows` / payload / 信号接线,以及 `emit pressed` 驱动的
#   纯 UI 行为),最后一相才 `add_child`(ESC 与"按创建房间收起"都要页面自己 `_ready` 建出来的
#   `_addr_edit` / `_status` / `_grid` 与 viewport)。该相不发任何一个包:加入场景树后在**同一次
#   同步调用栈内** `free()`  ->  `_ready` 里那句 `_request_list.call_deferred` 因对象已失效被跳过;
#   ㉔ 里 `_with_lobby` 会建一个 client peer(对象连着用户配置的地址),但同一帧紧跟
#   `NetBus.stop()` 拆掉它,而 ENet 只在 poll 里 flush  ->  本帧就 quit,没有报文出网。
#   - 明确说明该约束的原因是:1v1 页默认地址是用户的云服,本仓对"探针去连用户服务端"有明令 ——
#   本探针的口径是"不发出任何包",不是"从不建 peer"。
#
# - EXPECTED_CHECKS 用于断言完整性校验：防止脚本中途出错静默跳过后续测试而误报 ALL-OK。断言数不足即判定失败。
const EXPECTED_CHECKS := 28

var _checks := 0
var _fails: Array[String] = []


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if ok:
		print("  ok   " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


func _ready() -> void:
	var packed: PackedScene = load("res://scenes/mp_lobby.tscn")
	# 空载防御性校验:解析失败时 `load()` 仍返回非 null 但 `instantiate()` 会炸;两者都挡住,
	# 免得走不到 `_finish()` 而让进程挂在 --quit-after 上(一行判定结果都不打)。
	if packed == null or not packed.can_instantiate():
		print("LOBBY CREATE FORM PROBE: 无法加载 mp_lobby.tscn")
		get_tree().quit(1)
		return

	_phase_form(packed)      # ①-⑭ 变形逻辑 / 三套载荷 / 信号接线(不加入场景树)
	_phase_buttons(packed)   # ⑮-⑱ 按钮行为:换形 / 两条关闭路径(不加入场景树)
	_phase_beta(packed)      # ⑲-⑳ Beta 时间参数块(自门控)
	_phase_live(packed)      # ㉑-㉔ ESC 与"按创建房间收起"(加入场景树)
	_phase_time_options(packed)   # ㉕-㉖ 上报的 time 键(权威那一份)
	_finish()


# ── ①-⑭:变形逻辑 / 三套载荷 / 信号接线面(不加入场景树)──
func _phase_form(packed: PackedScene) -> void:
	# - 无类型声明(Variant):本探针按脚本成员名访问(`_form_rows` / `_create_payload` …),
	#   声明成 `Control` 会让分析器在编译期报"未知成员"、整份探针加载失败。
	var page = _page(packed)
	page._open_create_dialog()

	# ① 首次打开不会自关(与 Task 3 那个"首点把自己关掉"的形状相反:新建节点 visible=false,
	#    `_open_create_dialog` 显式置真)。
	_check(page._create_panel.visible and page._create_mask.visible,
			"① 首次打开:弹层 + 压暗罩都可见(没有自己关掉)")

	# 三颗模式按钮各切一次,逐次取五行(`max_players` / `match_time` / `weapons` / `privacy` / `map`)。
	page._apply_create_form(PvpSession.MODE_ROYALE)
	var royale_max: bool = page._form_rows["max_players"].visible
	var royale_time: bool = page._form_rows["match_time"].visible
	var royale_weapons: bool = page._form_rows["weapons"].visible
	var royale_privacy: bool = page._form_rows["privacy"].visible
	var royale_map: bool = page._form_rows["map"].visible
	var royale_heal: bool = _row_visible(page, "full_heal")

	page._apply_create_form(PvpSession.MODE_TEAM)
	var team_max: bool = page._form_rows["max_players"].visible
	var team_time: bool = page._form_rows["match_time"].visible
	var team_weapons: bool = page._form_rows["weapons"].visible
	var team_privacy: bool = page._form_rows["privacy"].visible
	var team_map: bool = page._form_rows["map"].visible
	var team_heal: bool = _row_visible(page, "full_heal")

	page._apply_create_form(PvpSession.MODE_PVP)
	var pvp_max: bool = page._form_rows["max_players"].visible
	var pvp_time: bool = page._form_rows["match_time"].visible
	var pvp_weapons: bool = page._form_rows["weapons"].visible
	var pvp_privacy: bool = page._form_rows["privacy"].visible
	var pvp_map: bool = page._form_rows["map"].visible
	var pvp_heal: bool = _row_visible(page, "full_heal")

	_check(royale_max and royale_time, "② 大乱斗:人数行 + 限时行都可见")
	_check((not team_max) and (not team_time), "③ 3v3:人数行 + 限时行都不可见")
	_check((not pvp_max) and (not pvp_time), "④ 1v1:人数行 + 限时行都不可见")
	# ⑤ 有真实危害:见文件头 —— 3v3 勾一次禁用武器会改掉另两个模式的 Settings。
	_check(not team_weapons, "⑤ 3v3:禁用武器网格不可见(不连带改 Settings.pvp_disabled_weapons)")
	_check(pvp_weapons and royale_weapons, "⑥ 1v1 / 大乱斗:禁用武器网格可见")
	_check(pvp_map and royale_map and team_map, "⑦ 三个模式都可见地图选择器")
	# ⑧ 同样是"骗人的控件"那一类:1v1 收不了隐私选项,那一行必须整块收起。
	_check((not pvp_privacy) and team_privacy and royale_privacy,
			"⑧ 1v1:公开/私密 + 邀请码整块不可见;3v3 / 大乱斗:可见")

	# ⑧b/⑧c 「每回合开始回满血」(2026-10-03 ②):被删的 1v1 旧页有这颗勾选框,统一弹层必须
	#   收下它 —— 否则 `Settings.pvp_round_full_heal` 失去唯一写入方,仍被 `_player_options()`
	#   读取上报而玩家再也打不开它。它是房主/服务器规则  ->  归属创建弹层,仅 1v1 显示
	#   (大乱斗恒 false、3v3 压根不发)。
	_check(pvp_heal and (not team_heal) and (not royale_heal),
			"⑧b 每回合回满血行:仅 1v1 可见(1v1=%s / 3v3=%s / 大乱斗=%s)"
					% [str(pvp_heal), str(team_heal), str(royale_heal)])
	# - ⑧c:那一行必须真有一颗勾选框且接线恰一次 —— 光登记一个空容器的话,"玩家打不开它"
	#   这条原始缺陷原样还在,而⑧b 的可见性照样绿。
	var heal_cb := _find_check(page._form_rows.get("full_heal"))
	_check(heal_cb != null and heal_cb.toggled.get_connections().size() == 1,
			"⑧c 每回合回满血行里有一颗勾选框且 toggled 恰 1 个 handler(%s)"
					% ("缺" if heal_cb == null else str(heal_cb.toggled.get_connections().size())))

	_check(_has_close_button(page), "⑨ 弹层里有一颗 × 按钮(文案就是 ×)")

	# ⑩-⑫:三套建房载荷的私有键。
	_check(not page._create_payload(PvpSession.MODE_TEAM).has("disabled_weapons"),
			"⑩ _create_payload(3v3) 不含 disabled_weapons 键")
	var rp: Dictionary = page._create_payload(PvpSession.MODE_ROYALE)
	_check(rp.has("match_time") and typeof(rp["match_time"]) == TYPE_INT,
			"⑪ _create_payload(大乱斗) 含 match_time 且为整数(秒)")
	# - 此处为 builder 数据结构断言：1v1 分支并不直接下发该载荷，验证目的在于保障 _create_payload 的数据结构完整性。
	var pp: Dictionary = page._create_payload(PvpSession.MODE_PVP)
	_check(pp.has("is_public") and pp.has("invite_code"),
			"⑫ _create_payload(1v1) 含 is_public 与 invite_code 键(builder 形状断言;1v1 不传该 payload)")

	# ⑬ 三颗模式按钮各恰 1 个 handler。-  它抓的是"连接被删 / 被重复添加"这一类;
	#   不抓"lambda 捕错循环变量" —— 那种情况下计数仍是 1(⑯ 按真按钮看可见性才抓得到)。
	var counts_ok := true
	var counts_msg := ""
	for m: String in [PvpSession.MODE_PVP, PvpSession.MODE_TEAM, PvpSession.MODE_ROYALE]:
		var b: Button = page._create_mode_btns.get(m)
		var n := 0 if b == null else b.pressed.get_connections().size()
		if b == null or n != 1:
			counts_ok = false
			counts_msg += " %s=%s" % [m, "缺" if b == null else str(n)]
	_check(counts_ok, "⑬ 三颗模式按钮各恰 1 个 handler%s" % counts_msg)

	# ⑭ `×` 与 `取 消` 各恰 1 个 handler(两条关闭路径的接线面)。
	var xb := _find_button(page._create_panel, "×")
	var cb := _find_button(page._create_panel, "取 消")
	_check(xb != null and cb != null and xb.pressed.get_connections().size() == 1
			and cb.pressed.get_connections().size() == 1,
			"⑭ × 与 取 消 各恰 1 个 handler(×=%s,取消=%s)" % [
					"缺" if xb == null else str(xb.pressed.get_connections().size()),
					"缺" if cb == null else str(cb.pressed.get_connections().size())])

	page.free()


# ── ⑮-⑱:按钮行为(不加入场景树即可:emit `pressed` 走真实连接的 handler)──
func _phase_buttons(packed: PackedScene) -> void:
	var page = _page(packed)
	page._open_create_dialog()

	# ⑮ 按「大乱斗」按钮  ->  可见性真的重排(接线 + 变形一起验,不是只读 _apply_create_form)。
	page._create_mode_btns[PvpSession.MODE_ROYALE].pressed.emit()
	_check(page._form_rows["max_players"].visible and page._form_rows["match_time"].visible
			and page._form_rows["privacy"].visible
			and page._create_mode_btns[PvpSession.MODE_ROYALE].disabled
			and not page._create_mode_btns[PvpSession.MODE_PVP].disabled,
			"⑮ 按大乱斗按钮:人数/限时/隐私行可见 + 当前项置灰(其余不置灰)")
	# ⑯ 再按「3v3」 ->  禁用武器网格收起、隐私行仍在(同一个 handler 走第二次)。
	page._create_mode_btns[PvpSession.MODE_TEAM].pressed.emit()
	_check(not page._form_rows["weapons"].visible and page._form_rows["privacy"].visible,
			"⑯ 按 3v3 按钮:禁用武器网格收起、隐私行仍在")

	# ⑰ `×` 关闭(弹层 + 罩一起收)。
	_find_button(page._create_panel, "×").pressed.emit()
	_check((not page._create_panel.visible) and (not page._create_mask.visible), "⑰ 按 × :弹层 + 罩都关掉")

	# ⑱ `取 消` 关闭。
	page._open_create_dialog()
	_find_button(page._create_panel, "取 消").pressed.emit()
	_check(not page._create_panel.visible, "⑱ 按 取 消 :弹层关掉")

	page.free()


# ── ⑲-⑳:Beta 时间参数块(自门控,与模式无关)──
func _phase_beta(packed: PackedScene) -> void:
	# ⑲ 非 Beta(本探针跑时的默认态):不可见。
	var plain = _page(packed)
	plain._open_create_dialog()
	_check(not plain._form_rows["beta"].visible, "⑲ 非 Beta 态:时间参数块不可见")
	plain.free()

	# ⑳ Beta 态:弹层只建一次,故用新实例建(重建路径 = 新页面 + `_open_create_dialog`)。
	PvpSession.beta_mode = true
	var beta = _page(packed)
	beta._open_create_dialog()
	_check(beta._form_rows["beta"].visible and beta._form_rows["beta"].get_child_count() > 0,
			"⑳ Beta 态重建:时间参数块可见且已建出行(%d 行)"
					% beta._form_rows["beta"].get_child_count())
	beta.free()
	PvpSession.beta_mode = false   # - 还原,别污染同一进程里后面的相


# ── ㉑-㉔:ESC 与"按创建房间收起"(加入场景树;需要 viewport 与页面自己的 `_addr_edit`/`_status`/`_grid`)──
func _phase_live(packed: PackedScene) -> void:
	var live = packed.instantiate()
	# - 加入场景树  ->  `_ready` 会建 `_addr_edit`/`_status`/`_grid` 并排一句
	#   `_request_list.call_deferred`。本阶段在同一次同步调用栈内 `free()` 它  -> 
	#   那句 deferred 因对象已失效被 Godot 跳过,不会 `NetBus.start_client`(不碰用户服)。
	add_child(live)
	live._open_create_dialog()

	var esc := InputEventKey.new()
	esc.pressed = true
	esc.keycode = KEY_ESCAPE
	esc.physical_keycode = KEY_ESCAPE

	# ㉑ 弹层不可见时:ESC 一律不处理(不抢大厅页自己的返回语义)。
	live._set_create_visible(false)
	live._unhandled_input(esc)
	_check(not live.get_viewport().is_input_handled(),
			"㉑ 弹层不可见时 ESC 不被吞掉(大厅自己的返回语义不被抢)")

	# ㉒ 弹层可见时:关掉 + 标记已处理(不再往下传)。
	live._open_create_dialog()
	live._unhandled_input(esc)
	_check((not live._create_panel.visible) and live.get_viewport().is_input_handled(),
			"㉒ 弹层可见时 ESC:关弹层 + `set_input_as_handled`")

	# ㉓ 弹层主行动按钮「创 建 房 间」的接线面:恰 1 个 handler。
	# - 少了它:`create.pressed.connect(_on_create_pressed)` 被删  ->  ⑬/⑭ 覆盖了三颗模式按钮与
	#   两条关闭路径,唯独漏了主行动按钮 —— 断言全部断言通过而弹层永远提交不了(⑭ + ⑱ 的配对同形)。
	var ok_btn := _find_button(live._create_panel, "创 建 房 间")
	_check(ok_btn != null and ok_btn.pressed.get_connections().size() == 1,
			"㉓ 创 建 房 间 按钮恰 1 个 handler(%s)" % (
					"缺" if ok_btn == null else str(ok_btn.pressed.get_connections().size())))

	# ㉔ 走真按钮(`emit pressed`,与 ⑰/⑱ 相同处理逻辑) ->  弹层立即收起(不等异步应答)。
	#   - 上一版这里直接调 `_on_create_pressed()`,于是"主行动按钮的接线"整条没被覆盖。
	live._open_create_dialog()
	_find_button(live._create_panel, "创 建 房 间").pressed.emit()
	NetBus.stop()   # 拆掉 `_with_lobby` 刚建的 client:本帧就 quit,不发一个包出去
	_check(not live._create_panel.visible, "㉔ 按 创 建 房 间 后弹层立即收起")

	live.free()


# ── ㉕-㉖:Beta 会话下上报的 `time` 键(worker 侧唯一权威来源)──
# - 自动化回归测试保障：防止 options.get("time") 字段解析异常导致时间经济系统静默短路。
#   worker 侧 MatchHost 读取 options.get("time") 进行初始化。
# 注意事项：㉖(1v1 必须为空)是大厅统一之后才出现的新路:`beta_mode` 是会话级的,而统一
#   大厅让 Beta 会话里的玩家能切到 1v1 建局;1v1 的 `create_room` 是冻结签名、载荷里没有
#   beta 标记  ->  那间房没法按 beta 隔离  ->  一个没勾 Beta 的普通玩家能加进来打带时间经济
#   的 1v1。设计里 Beta 页没有 1v1  ->  1v1 退回普通局才是对的。
# - 两相各用一个新实例(避免上一相残留的弹层/连接);`beta_mode` 用完还原,别污染后面的相。
func _phase_time_options(packed: PackedScene) -> void:
	var page = _page(packed)
	PvpSession.beta_mode = true
	# ㉕ Beta 会话 + 大乱斗  ->  `time` 在、且非空(权威会上报给 worker)。
	page._current_mode = PvpSession.MODE_ROYALE
	var ro: Dictionary = page._player_options()
	_check(ro.has("time") and not (ro["time"] as Dictionary).is_empty(),
			"㉕ Beta 会话 + 大乱斗:`_player_options()[\"time\"]` 存在且非空(worker 侧唯一权威来源)")
	# ㉖ Beta 会话 + 1v1  ->  `time` 必须空(1v1 载荷无 beta 标记、无法隔离  ->  退回普通局)。
	page._current_mode = PvpSession.MODE_PVP
	var pv: Dictionary = page._player_options()
	_check(pv.has("time") and (pv["time"] as Dictionary).is_empty(),
			"㉖ Beta 会话 + 1v1:`time` 是**空字典**(1v1 无法按 beta 隔离 ⇒ 不启用时间经济)")
	page.free()
	PvpSession.beta_mode = false   # - 还原,别污染同一进程里后面的相


# ── 小工具 ──

# 树外页面实例(T1 起弹层启动即建)。
# 注意事项：为什么需要:三个弹层由 `_build_ui()` 建(启动即建、默认隐藏;`_ready` 调它),而本探针
#   前三段故意不加入场景树(`_ready` 不跑  ->  不建 socket、不排 deferred)。此前那几段靠
#   `_open_create_dialog` 里的懒建分支拿到弹层 —— T1 删掉懒建后,树外实例上
#   `_create_panel` / `_form_rows` 恒为 null。故夹具在此显式调一次 `_build_ui()`。
#   - 走这个生产缝而不是逐个调 `_build_*`:T2 把建树代码整体搬进 `.tscn` 时只要重写
#     `_build_ui()` 的方法体,本夹具不用再改;也保证隐藏态与生产一致。
#   - 这是"新契约的镜像",不是绕过断言:探针验的变形/载荷/接线一条没动。
#   - 同步义务:`_build_ui` 里若增删 UI,这里跟着走(见 `scenes/mp_lobby.gd`)。
func _page(packed: PackedScene):
	var page = packed.instantiate()
	page.call("_build_ui")
	return page


# 弹层子树里有没有一颗文案是 `×` 的 Button?(右上角那颗关闭键。)
# - 按子树的任何深度找:版式若把 × 挪进一层 HBox / 另一容器,断言不该跟着失效;
#   要断的是"有一颗 × 按钮",不是"它在第几层"。
func _has_close_button(page) -> bool:
	var panel: PanelContainer = page._create_panel
	return panel != null and _find_button(panel, "×") != null


# `_form_rows` 里某个键登记的行是否可见(null 键 = 没登记  ->  false,而不是让探针在 Nil 上炸)。
func _row_visible(page, key: String) -> bool:
	var row = page._form_rows.get(key)
	return row != null and row.visible


# 子树里第一颗 CheckButton(用于 ⑧c:那一行里必须真有一颗勾选框)。
func _find_check(n: Node) -> CheckButton:
	if n is CheckButton:
		return n
	for c in n.get_children():
		var r := _find_check(c)
		if r != null:
			return r
	return null


func _find_button(n: Node, text: String) -> Button:
	if n is Button and (n as Button).text == text:
		return n
	for c in n.get_children():
		var r := _find_button(c, text)
		if r != null:
			return r
	return null


# - 收尾两道:① 断言条数 `!= EXPECTED_CHECKS` 即红(少了 = 有断言没跑到;多了 = **多跑了一条
#   没登记的断言**,两者都是账目对不上 —— 故用 `!=` 而不是 `<`,2026-10-03 最终整体评审 Minor①);
#   ② 有失败即红。
func _finish() -> void:
	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 只跑了 %d 条断言(期望恰好 %d 条,多了少了都算账目对不上)—— 这个 ALL-OK 不算数"
				% [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("LOBBY CREATE FORM PROBE: ALL-OK(%d 条断言)" % _checks)
		get_tree().quit(0)
	else:
		print("LOBBY CREATE FORM PROBE: %d 条失败" % _fails.size())
		for f in _fails:
			print("  ✗ " + f)
		get_tree().quit(1)
