extends Node

# 阶段 3(spec §4 的 3.1/3.2/3.3/3.4)的**常驻守卫**。场景模式(headless 即可)。
#
# 跑法:
#   "$GODOT" --headless --path . --quit-after 3600 res://tests/probe/reconnect_status_probe.tscn
# 判据:末行 `KH RECON-UI PROBE: ALL-OK`(grep 文本,不看退出码)。
#
# ═══ 它守什么、为什么不能只靠真链路探针 ═══
# 本批四处改动的**接线**全都是"删掉不报错"的那一类:
#   - `server_main._notify_opponent_left()` 少调一次  ->  服务端不发,客户端看不出任何异常;
#   - `pvp_game._on_opponent_left` 少调 `_cancel_reconnect()`  ->  **只有**在"断开先到"那一半
#     时序里才暴露异常(竞态,真链路探针跑十次未必撞上一次);
#   - `pvp_match_client._subscribe_reconnect()` 少建横幅  ->  三个模式一起静默没有提示;
#   - 三个 `round_state` 生产者漏走 `_send_round_state()`  ->  `grace` 字段时有时无。
# 真链路探针(`reconnect_probe`)跑一次 ~72s 且要起子进程;本探针 **2 秒内跑完、不起子进程、
# 不占端口**,把上面那些接线变成机械可查的文本断言 + 两条真行为断言。
#
# - 断言计数(见 tests/lib/probe_base.gd 文件头:ALL-OK 只证明"没有失败",**不证明"都跑过"**)。
#   本探针是**活的**文件:Task 2 建它,Task 3/4/5 各往里加相 —— **每加一相就必须同步抬高这个数**,
#   判据是"**实跑条数 == EXPECTED_CHECKS** 且 ALL-OK"(不是"我猜的数是几")。
#   本 Task 落地的条数(逐项相加,别凭印象):
#     _check_opponent_left()  : 1(读得到 SRV_MAIN) + a/b/c/d/e 各 1 = **6**
#     _check_cancel_wiring()  : 1(读得到 CLIENT_BASE) + 1(missing 为空) + 9(三个生产者各 3) = **11**
#    ->  合计 **17**(Task 3 把 ②b 从"前瞻"提升为核心约束,那一圈由 3 条变 9 条)。
# - 本探针是**活的**文件:每加一相加一次这个数(见文件头),判断标准是"实跑 == 期望"。
#   本 Task 加的两相加 **10** 条(`_check_status_banner` 5 条 + `_check_status_call_sites` 5 条)
#    ->  17 + 10 = **27**。
# - 2026-09-28 复核批(Fix 1~5)的增减,逐项相加减:
#     _check_status_banner()     : 5 → **9**(+层位**次序** 1 条;+水平居中/不越界/顶边在记分条之下 3 条)
#     _check_status_call_sites() : 5 → **4**(手抄五个函数名  ->  改成推导:自检 + 赋值 -> 驱动 +
#                                   调用点 -> 在状态机里 + 亮/收判据,各 1 条)
#     _check_subscribe_wiring()  : 0 → **3**(三个模式的 `_ready` 各 1 条 —— 原先那句
#                                   "另有源码断言钉着这一点"是**空头支票**,这是补的那条)
#    ->  27 + 4 - 1 + 3 = **33**。
# - 2026-09-28 Task 5(3.1 的客户端半)加第 6 相 `_check_hud_consumers()`,逐项相加:
#     pvp_hud 本地倒计时更新 / `_refresh_grace` 的对手 role / 它的 `has(opp)` 判据
#     / royale_hud 引 `C_GRACE` / `_refresh_board` 收 `grace` / team_hud 的反向断言 = **6**
#    ->  33 + 6 = **39**。
#   ⚠ 计划里写的是"由 **27** 抬到 **33**" —— 那个 27 是本阶段**之前**的旧数;Task 4 的复核批
#     (Fix 1~5:横幅 5→9、调用点 5→4、新增 `_check_subscribe_wiring` 3 条)已经把 27 抬成了
#     **33**(见上面那段)。故 Task 5 的入口数是 33 而不是 27,落点是 **39**。
const EXPECTED_CHECKS := 39

const SRV_MAIN := "res://server/server_main.gd"
const CLIENT_BASE := "res://scenes/pvp_match_client.gd"
const PVP_GAME := "res://scenes/pvp_game.gd"
const ROYALE_GAME := "res://scenes/royale_game.gd"
const TEAM_GAME := "res://scenes/team_game.gd"
# 三个模式的**生产入口**(阶段 5逐个断言它们的 `_ready` 里调了 `_subscribe_reconnect()`)。
const CLIENTS := [PVP_GAME, ROYALE_GAME, TEAM_GAME]
const PRODUCERS := ["res://server/match/match_round.gd", "res://server/hosts/royale_host.gd",
		"res://server/hosts/team_host.gd"]
const PVP_HUD := "res://ui/hud/pvp_hud.gd"
const ROYALE_HUD := "res://ui/hud/royale_hud.gd"
const TEAM_HUD := "res://ui/hud/team_hud.gd"

# ── 阶段 4 的推导例外(唯一一处,理由见 `_check_status_call_sites`)──
# `_exit_tree` 是 Godot 的生命周期钩子:那一刻场景正在离开,横幅**随场景一起销毁**
# (`StatusBanner` 是客户端的子节点),在里面设文字是纯粹的空操作;而它上面那条
# `_abort_reconnect` 早已收过横幅。故它只停循环、不动横幅。
const TEARDOWN_EXEMPT := ["_exit_tree"]

var _checks := 0
var _fails: Array[String] = []


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if ok:
		print("  ok   " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


func _read(p: String) -> String:
	return ScanUtil.read(p)


func _code(p: String) -> String:
	return ScanUtil.code_only(_read(p))


func _body(p: String, fn: String) -> String:
	return ScanUtil.func_body(_code(p), fn)


func _ready() -> void:
	_check_opponent_left()
	_check_cancel_wiring()
	_check_status_banner()
	_check_status_call_sites()
	_check_subscribe_wiring()
	_check_hud_consumers()
	_finish()


# ── 阶段 1:3.3 —— `opponent_left` 的服务端发送点与客户端统一集中处理 ──
func _check_opponent_left() -> void:
	var srv := _code(SRV_MAIN)
	_check(not srv.is_empty(), "读不到 %s" % SRV_MAIN)
	# ①a 发送点存在,且走的是 `NetBus.reply`(定向发送的存活检测统一集中处理)
	# 注意： 判据**收在 `_notify_opponent_left` 的函数体里**(2026-09-29 收紧)。原写法是
	#   **两条文件级子串的合取**:`srv.contains("NetBus.reply(") and srv.contains("\"opponent_left\"")`
	#   —— 两者**各自**都能被文件里**别处**的代码喂饱:`NetBus.reply(` 在本文件另有**一处**调用点
	#   (`match_start` 的应答,`server_main.gd` 的 `_on_match_sync` 那一支),而带引号的字面量
	#   `"opponent_left"` 在下面那种改法里**仍然在**(只是换了调用它的函数)。
	#    ->  把这一行改成 **`NetBus.rpc_id(peer, "opponent_left")`**(绕开存活检测统一集中处理,正是本条要拦的
	#   那一件事)时,两条**同时**成立、断言**保持测试通过**,而消息读成"我验过了那次调用"。
	#   - 实测(2026-09-29):改 `rpc_id` 后 `grep -c 'NetBus.reply('` = **1**(命中另一处)、
	#     `grep -c '"opponent_left"'` = **1**(命中被改的那一行) ->  旧谓词 = true and true = 绿;
	#     而新谓词当场 FAIL。(纯粹删掉整行时旧谓词也会红 —— 它拦得住"没有",拦不住"换了".)
	#   - 这是 `tests/lib/probe_base.gd` 文件头那一族「读起来像覆盖、实际不覆盖」的空断言,
	#     ①e 已为此收紧过,本条是它当时漏掉的另一半。
	#   现在钉的是"**接收者 + 方法名**同时出现在这个函数体里",文件里别处再怎么写都喂不饱它。
	var notif := _body(SRV_MAIN, "_notify_opponent_left")
	_check(notif.contains("NetBus.reply(peer, \"opponent_left\")"),
			"★ `_notify_opponent_left` 里没有 `NetBus.reply(peer, \"opponent_left\")` —— "
			+ "这条 RPC 会退回「零调用点」,或退回绕过判活收口的 `rpc_id`(实得函数体「%s」)" % notif)
	# ①b 它被 1v1 收场那一支调用(**不是**只定义不调 —— 那正是本条要修的缺陷形状)
	var exp := _body(SRV_MAIN, "_expire_graces")
	_check(exp.contains("_notify_opponent_left()"),
			"★ `_expire_graces` 里没调 `_notify_opponent_left()` —— 发送点定义了却没人调,"
			+ "幸存者照样干等 60s")
	# ①c 调用必须排在收场**之前**(排在 quit 之后 = 永远发不出去)
	var i_notify := exp.find("_notify_opponent_left()")
	var i_quit := exp.find("get_tree().quit(0)")
	_check(i_notify >= 0 and i_quit >= 0 and i_notify < i_quit,
			"★ 通知必须排在 `get_tree().quit(0)` **之前**(notify=%d quit=%d)"
			% [i_notify, i_quit])
	# ①d 客户端侧:`_on_opponent_left` 里调了 `_cancel_reconnect()`
	var opp := _body(PVP_GAME, "_on_opponent_left")
	_check(opp.contains("_cancel_reconnect()"),
			"★ `pvp_game._on_opponent_left` 没调 `_cancel_reconnect()` —— "
			+ "「断开先到」那一半时序里,重连循环会继续跑满 60s")
	# ①e 反向:那条 `_match_ended` 闸仍在(它挡的是"通知先到"那一半)。
	# - 谓词必须咬住**闸自身的形状**,不能只找 `_match_ended` 这个标识符 —— 紧邻下一行的
	#   `_match_ended = true` 是一条**赋值**,单凭它就足以喂饱 `contains("_match_ended")`:
	#   删掉闸(甚至删掉整个 `if …: return` 块)时那种谓词保持测试通过,是一条**读起来像覆盖、
	#   实际不覆盖**的空断言(2026-09-28 复核实测)。
	_check(opp.contains("if _match_ended"),
			"★ `_on_opponent_left` 的 `_match_ended` 闸仍在(通知先到时靠它挡住重连)")


# ── 阶段 2:`_cancel_reconnect` 的行为面(它必须真的把循环停掉)──
func _check_cancel_wiring() -> void:
	var base := _code(CLIENT_BASE)
	_check(not base.is_empty(), "读不到 %s" % CLIENT_BASE)
	# ②a 函数体四件事一件都不能少(少一件 = 循环会从某个入口继续跑)
	var body := _body(CLIENT_BASE, "_cancel_reconnect")
	var missing: Array[String] = []
	for needle in ["_reconnecting = false", "_reconnect_started_ms = 0",
			"_reclaim_sent = false", "_attempt_started_ms = 0"]:
		if not body.contains(needle):
			missing.append(needle)
	_check(missing.is_empty(),
			"`_cancel_reconnect` 少复位了这些量(循环会从某个入口继续跑):%s" % str(missing))
	# ②b(-  Task 3 起是**核心约束**断言,不再是前瞻):三个 `round_state` 生产者都必须走唯一出口。
	#    漏一个  ->  那个模式的「掉线中」永远不亮,而且**不报错**。
	for p in PRODUCERS:
		var c := _code(p)
		_check(not c.is_empty(), "读不到 %s" % p)
		_check(c.contains("_send_round_state("),
				"★ %s 没走 `_send_round_state(`(那个模式的「掉线中」不会亮)" % p)
		_check(not c.contains("_rpc_all(\"round_state\""),
				"★ %s 里还有绕过出口的 `_rpc_all(\"round_state\"`" % p)


# ── 阶段 3:横幅的行为面(建得出来、层位对、能显能收)──
# - 它**必须真建一个** PvpMatchClient 子类实例:纯源码断言拦不住"`.new()` 出来的 layer 是 1"
#   这一类 —— 而那正是这条横幅最容易踩、且**完全静默**的坑(层位只住在 .tscn 里)。
# - 用桩子而不是真 `pvp_game.tscn`:真场景会建整个世界 + 连 NetBus 发 `match_sync`,
#   而本阶段要验的只是"横幅挂上去了没有、层位对不对"。桩子只提供基类的那一段接线。
class ClientStub extends PvpMatchClient:
	pass


func _check_status_banner() -> void:
	var stub := ClientStub.new()
	add_child(stub)
	# - 本阶段是**自己调** `_subscribe_reconnect()` 来验行为面的 —— 那**证明不了生产里有人调它**,
	#   三个模式各自的 `_ready` 那一半由**阶段 5**的源码断言钉着(Phase 3 复核时这里曾写着
	#   "Task 2 的守卫另有源码断言钉着这一点",而**当时并不存在那条断言** —— 那正是阶段 5补的洞)。
	stub._subscribe_reconnect()
	var banner := stub.get_node_or_null("StatusBanner") as StatusBanner
	_check(banner != null,
			"★ `_subscribe_reconnect()` 没有把横幅挂上去(三个模式会一起静默没有提示)")
	if banner == null:
		stub.queue_free()
		return
	# 注意： 层位:这是 `.tscn` 里那个 `layer = 140` 的**行为**判据。写成 `.new()`、或者有人
	#   从 .tscn 里删掉那一行,这里直接断言失败 —— 而源码断言一条都无法覆盖检测(值在 .tscn 里)。
	_check(banner.layer == 140,
			"★ 横幅层位必须是 140(实得 %d);层位只住在 ui/status_banner.tscn 里" % banner.layer)
	# 注意： **次序**也要钉(不只是今天的数值):140 的意义是"高于三个对局 HUD(130)与小地图(131)、
	#   低于暂停菜单(145)与结算页(150)"。把**那条理由本身**写成断言,而不是只钉今天的取值。
	#   区间取 (131, 145) 的**开区间**:小地图 131 与暂停菜单 145。
	#   ⚠ **它是 belt,不是主力(2026-09-28 复核实测)**,两点如实登记:
	#   ① 本条的界是**字面量**,故它**测不出"别的层动了"** —— 有人把暂停菜单降到 138
	#      (`ui/pause_menu.gd` 的 `layer = 145`)时**两条层位断言测试均通过**,而横幅照样会被模态画面
	#      盖住。要测那一档得把界改成从别处**读**出来(跨 4 个文件取层位),本批不做。
	#   ② 今天 `== 140` **蕴含**它(140 ∈ (131,145)) ->  它红的时候上一条一定也红,**不可能单独红**。
	#      它真正的用途是:那个确切数值将来被合法改掉(上一条随之放宽/删除)时,「为什么在
	#      这一带」这条理由仍在场 —— 与 `tests/smoke/grace_window_smoke` ⑧ 是同一种 belt。
	_check(banner.layer > 131 and banner.layer < 145,
			"★ 横幅层位必须在 (131, 145) 里 —— 高于 HUD/小地图(130/131)、低于暂停菜单/结算页"
			+ "(145/150);实得 %d" % banner.layer)
	# 显 / 收。-  这里刻意用**最长的那条生产文案** —— 它同时是下面那三条几何断言的量具
	#   (`_on_reconnect_retry_tick` 刚起飞那一刻的 `GraceWindow.DEFAULT_SECONDS` = 60s)。
	stub._set_status("与服务器断线,正在重连…(剩余 60s)")
	_check(banner._panel.visible and banner._label.text.contains("60s"),
			"设了文字就应该可见且文字正确(visible=%s text=%s)"
			% [str(banner._panel.visible), banner._label.text])
	# 注意： 几何(§Fix 1):**居中是真的能被断言的**。用**最长的那条生产文案**(倒计时到点那一句)
	#   量,因为宽度最大的那一档才是"会不会压到别的东西"的判据。
	#   - 这一相是 headless 的:层的 `layer` 与控件矩形都不需要渲染器,`get_global_rect()` 在
	#     headless 下给的就是布局算出来的矩形(视口 = 项目设置 1920×1440)。真渲染那一半
	#     (像素、颜色)不在本探针的射程内 —— 那类要显示器,归用户。
	var vw := get_viewport().get_visible_rect().size.x
	var rect := banner._panel.get_global_rect()
	_check(absf(rect.get_center().x - vw * 0.5) <= 1.0,
			"★ 横幅必须**水平居中**:面板中心 x 必须 = 视口半宽 %0.1f,实得 %0.1f(rect=%s)"
			% [vw * 0.5, rect.get_center().x, str(rect)])
	_check(rect.position.x >= 0.0 and rect.end.x <= vw,
			"★ 横幅必须整块落在视口里(rect=%s 视口宽=%0.1f);左缘钉在视口中心(即修复前那种"
			% [str(rect), vw] + "四个偏移量全 0 的形状)会让它在 1920 下从 x=960 往右长出去")
	# 注意： 阈值必须是**那条 GraceWrap 的真实底边**,不是"看起来差不多"的数(2026-09-29 订正)。
	#   本阶段此前写 `>= 120.0` 而消息里也说"到 120 结束" —— **两个 120 都是错的**:`GraceWrap`
	#   的 `offset_top = 72`、共用 Plate 的上下内容边距各 8、含 CJK 的标签高 36  ->  实测矩形
	#   `[P: (704.0, 72.0), S: (512.0, 52.0)]`,**底边 = 124**。错的那一版拦不住"把横幅放到
	#   122"——那会与掉线那条重叠 2px,而断言保持测试通过、消息还把人指向 120(阈值读起来像覆盖、
	#   实际不覆盖,与 `tests/lib/probe_base.gd` 文件头那一族同形)。
	#    ->  方向是**抬高到真值**:这条阈值的语义是"横幅不得与掉线那条重叠",故它**至少**要等于
	#     对方的底边(等于即恰好首尾相接、不算重叠)。今天横幅的 `TOP_OFFSET = 128`(128 > 124,
	#     留 4px 余量),权威登记在 `ui/status_banner.gd` 的 `TOP_OFFSET` 那一段。
	_check(rect.position.y >= 124.0,
			"★ 横幅顶边必须落在记分条(自 16 起、其下那条 GraceWrap 到 124 结束)之下:实得 y=%0.1f(rect=%s)"
			% [rect.position.y, str(rect)])
	stub._set_status("")
	_check(not banner._panel.visible, "空串必须收起横幅(visible=%s)" % str(banner._panel.visible))
	# - 反向:文字为空但面板仍可见 = "永远挂着一块空黑板",是本类最容易出的错
	stub._set_status("正在重连…")
	_check(banner._panel.visible, "非空文字必须重新亮出来(否则收起之后再也回不来)")
	stub.queue_free()


# ── 阶段 4:横幅的**驱动点**真的驱动了它(源码面,**全集由源码推导**)──
# 行为面只能验"设了文字会显示",验不了"状态机在那些转折点上真的调了它" ——
# 后者是"删掉不报错"的一类,必须机械钉住。
# 注意： 为什么**不手抄函数名**:手抄名单漏掉**第六个**转折点时一条断言都不会红(它只会"更可能"
#    被发现,不是"不可能漏掉")。这里改成**推导**:
#      - 转折点全集 = 「函数体里给 `_reconnecting` 赋值的函数」 —— 那正是"进 / 出重连态"
#        这件事的机械特征(状态机只有这一个布尔量);
#      - 后者 = 这些函数体里都得有 `_set_status(`。
#    反方向再钉一条:每个 `_set_status(` 调用点都必须落在**碰过 `_reconnecting`** 的函数里 ——
#    那正是 `_banner` 上方那句「它**只有一个数据源**」的机械判据(将来有人把别的事件也接到
#    这块横幅上,这里会红)。
func _check_status_call_sites() -> void:
	var fns := _func_names(_code(CLIENT_BASE))
	var transitions: Array[String] = []   # 进 / 出重连态的函数
	var drivers: Array[String] = []       # 调过 `_set_status(` 的函数
	for fn in fns:
		if _body(CLIENT_BASE, fn).contains("_reconnecting ="):
			transitions.append(fn)
		if _call_view(fn).contains("_set_status("):
			drivers.append(fn)
	# ④a 扫描器自检 —— -  **防空绿**:没有它,下面几条在"扫描词汇哪天失效"时会**恒绿地无效操作**
	#     (推导集空  ->  循环一次都不跑  ->  missing 恒空)。两个哨兵各自锚住一半:
	#     `_begin_reconnect`(赋值那半)、`_on_reconnect_retry_tick`(只刷倒计时、**不赋**
	#     `_reconnecting`  ->  推导规则够不到它,全靠 `_set_status(` 那半把它捞回来)。
	_check(transitions.has("_begin_reconnect") and drivers.has("_on_reconnect_retry_tick"),
			"★ 转折点推导集不对劲(transitions=%s / drivers=%s)—— 是扫描词汇失效,"
			% [str(transitions), str(drivers)] + "不是「没有转折点」")
	# ④b 每个"进出重连态"的函数都必须驱动横幅(唯一例外见 `TEARDOWN_EXEMPT` 及其理由)
	var silent: Array[String] = []
	for fn in transitions:
		if fn in TEARDOWN_EXEMPT:
			continue
		if not _call_view(fn).contains("_set_status("):
			silent.append(fn)
	_check(silent.is_empty(),
			"★ 这些函数改了 `_reconnecting` 却没调 `_set_status(`(那个转折点的提示会静默消失):%s"
			% str(silent))
	# ④c 反向:每个 `_set_status(` 调用点都必须落在重连状态机里(横幅只有一个数据源)
	var strays: Array[String] = []
	for fn in drivers:
		if not _body(CLIENT_BASE, fn).contains("_reconnecting"):
			strays.append(fn)
	_check(strays.is_empty(),
			"★ 这些函数调了 `_set_status(` 却完全不碰 `_reconnecting`(横幅的数据源不再唯一):%s"
			% str(strays))
	# ④d **亮 / 收**的判据(§Fix 3):非空**字面量** = 亮;空串 = 收起,而**只有**"离开重连态"
	#     的那几支(`_reconnecting = false`)才允许空串。只判 `_set_status(` 在不在的话,把任一处
	#     "亮"改写成 `_set_status("")` 是**测试全部通过**的 —— 横幅当场变成死的,而五条断言一条都不红。
	var bad: Array[String] = []
	for fn in drivers:
		var leaves := _body(CLIENT_BASE, fn).contains("_reconnecting = false")
		for arg in _status_args(_call_view(fn)):
			if arg == "\"\"":
				if not leaves:
					bad.append("%s:空串收起了横幅,但它不是「离开重连态」的那一支" % fn)
			elif not arg.begins_with("\""):
				bad.append("%s:实参不是字面量(%s)" % [fn, arg])
	_check(bad.is_empty(), "★ 横幅的亮/收判据不对(亮=非空字面量;只有离开重连态才允许空串):%s"
			% str(bad))


# ── 阶段 5:三个模式的**生产入口**(源码面)──
# - 阶段 3 是**自己调** `_subscribe_reconnect()` 验行为 —— 它证明不了生产里有人调。三个模式各自
#   在 `_ready` 里调一次,漏一个  ->  **那个模式**静默没有横幅,而阶段 3保持测试通过(2026-09-28 复核:
#   这里原先只有一句"另有源码断言钉着",**那条断言当时并不存在**)。
func _check_subscribe_wiring() -> void:
	for p in CLIENTS:
		_check(_body(p, "_ready").contains("_subscribe_reconnect("),
				"★ %s 的 `_ready` 里没调 `_subscribe_reconnect()` —— 那个模式静默没有状态横幅" % p)


# ── 阶段 6:两个 HUD 真的消费了 `grace`(阶段 3 的 3.1 客户端半)──
# - 3v3 **刻意不消费**(spec §4 的 3.1 只点了大乱斗与 1v1):6 人一队,单行"对手状态"没有意义。
#   这是一条**有意的不对称**,故这里也断言 `team_hud` 不掉进"顺手套一份"的坑 ——
#   它要是也消费了,说明有人把 `grace` 当成了通用字段。
func _check_hud_consumers() -> void:
	var pvp := _code(PVP_HUD)
	_check(pvp.contains("GraceWindow.tick_display("),
			"★ pvp_hud 没有本地走秒(`GraceWindow.tick_display` 是那份减法的唯一实现)")
	# (阶段 6 原先还有一句 `var roy := _code(ROYALE_HUD)` —— 它只喂那两条文件级子串,收紧后
	#  再无读者,已删;未使用的局部量会刷 `UNUSED_VARIABLE` 警告。)
	var body := _body(PVP_HUD, "_refresh_grace")
	_check(body.contains("3 - PvpSession.role"),
			"★ `_refresh_grace` 没按「对手 role = 3 - 自己」取数(实得「%s」)" % body)
	_check(body.contains("_grace.has(opp)"),
			"★ `_refresh_grace` 必须是 `has(opp)` 判定,不能「取第一个键」(多一个 role 时会印错人)")
	# 注意： 下面两条判据**全部收在 `_refresh_board` 的函数体里**(2026-09-29 收紧)。
	#   上一版那两条各有一半是**文件级**的,而那一半**读起来像覆盖、实际不覆盖**:
	#     - `roy.contains("UiFactory.C_GRACE")` 被**文件级那一行** `const COLOR_GRACE := UiFactory.C_GRACE`
	#       喂饱  ->  把「掉线」那一整支(`tag`/`col` 两行)删光它也保持测试通过;
	#     - `roy.contains("_refresh_board(")` 被**它自己的定义行**喂饱  ->  **恒真**、零信息,
	#       留着只会让人以为"这条验过调用点"。
	#   (另一半——"形参必须叫 `grace: Dictionary`"——本来就是按函数体判的,那半是对的;
	#    2026-09-28 变异实测:形参改名成 `grc: Dictionary` 时它确实红。)
	var board := _body(ROYALE_HUD, "_refresh_board")
	_check(board.contains("COLOR_GRACE"),
			"★ royale_hud 的「掉线」那一档没有引调色板的新色(判据在 `_refresh_board` 的**函数体**里 ——"
			+ " 文件级那句 `const COLOR_GRACE := UiFactory.C_GRACE` 不算数「用上了」)")
	_check(board.contains("grace: Dictionary") and board.contains("grace.has(")
			and board.contains("\"掉线 %ds\""),
			# - 消息里那个 `%%ds` 是**转义**:它是 `_refresh_board` 里那句标签的**字面量**,
			#   不转义会被本行的 `%` 运算当成第二个占位符(实测:`ERROR: String formatting error:
			#   a number is required.`,而断言本身照打 ok —— 一条**仅产生日志警告**的坑)。
			"★ `_refresh_board` 没有把 `grace` 收进去并真的画出来(形参 `grace: Dictionary` / "
			+ "`grace.has(role)` 判据 / 「掉线 %%ds」标签 —— 三者缺一;实得函数体「%s」)" % board)
	# 注意： 这一相**仍看不见什么**(照实登记,别把它读成"「掉线」那一档已被守卫盖住"):
	#    上面两条都是**函数体内的文本共现**,控制流一概看不见 —— 用 `if false:` 包住整支、
	#    或把 `col` 算完再在下游整体覆写,两条**照样测试全部通过**。
	#    真正钉住"这一档在**画面上**真的生效"的是**用户跑的真渲染探针**
	#    (`tests/probe/combat_hud_visual_probe.gd` 的态8:数像素差 + 念出「掉线 42s」+ 量文本宽度)。
	#    headless 这一侧**没有**等价物(本探针不看像素),故这条缺口是**登记的**,不是"已闭合"。
	_check(not _code(TEAM_HUD).contains("grace"),
			"★ team_hud 也在消费 `grace` —— 3v3 **刻意不做**(spec §4 的 3.1 只点大乱斗与 1v1);"
			+ "要做也是在结算/记分条上另设计,不是这条单行状态")


# ── 本阶段用的扫描小工具(ScanUtil 的通用词汇之上,只服务阶段 4)──
# 注意： "**调用点**视图" = 函数体**剥掉签名行**。签名行不是调用点:`func _set_status(text: String)`
#    里那一处 `_set_status(` 是**定义**,不是"谁调了它"。
#    不剥的话 `_set_status` 自己被算成自己的调用者,而它显然不碰 `_reconnecting`、形参也不是
#    字面量  ->  ④c 与 ④d **双双虚假失败（测试用例误报）**(2026-09-28 复核批实测:那两条虚假失败（测试用例误报）就是它)。
# - 为什么是"剥签名行"而不是"把 `_set_status` 加进一张例外名单":`ScanUtil.func_body` 的返回
#   一律**以签名行开头**,故"第一行不是调用点"对**任何**函数名都成立,与被扫的是谁无关 ——
#   这是一条**推导**,不是一张**手抄名单**(手抄名单漏名字的失效模式正是阶段 4改成推导要躲的那一个;
#   本文件里唯一的手抄例外是 `TEARDOWN_EXEMPT`,它另有理由且只有一条)。
func _call_view(fn: String) -> String:
	var body := _body(CLIENT_BASE, fn)
	var nl := body.find("\n")
	return body.substr(nl + 1) if nl >= 0 else ""


# 函数名表:只认顶层 `func xxx(`(入参已过 `code_only`,缩进与注释都剥掉了;
# lambda 写的 `func (` 没有名字,被 `p > 0` 挡掉)。
func _func_names(code: String) -> Array[String]:
	var out: Array[String] = []
	for line in code.split("\n"):
		if not line.begins_with("func "):
			continue
		var rest := line.substr(5)
		var p := rest.find("(")
		if p > 0:
			out.append(rest.substr(0, p).strip_edges())
	return out


# 取某函数体里**所有** `_set_status(` 的实参原文(按括号配对切;`match_paren` 会跳过字符串里的括号)
func _status_args(body: String) -> Array[String]:
	var out: Array[String] = []
	var from := 0
	while true:
		var i := body.find("_set_status(", from)
		if i < 0:
			break
		var open := i + "_set_status".length()
		var close := ScanUtil.match_paren(body, open)
		if close < 0:
			break
		out.append(body.substr(open + 1, close - open - 1).strip_edges())
		from = close + 1
	return out


func _finish() -> void:
	# 注意： 判据是 **`!=`** 而不是 `<`,**两个方向都要红**(与 `tests/probe/late_match_probe.gd` 相同机制):
	#    多跑一条**没登记的**断言同样是闸失守 —— 那说明 `EXPECTED_CHECKS` 已经与实况对不上,
	#    闸对**后加的那些**断言就成了恒绿的摆设(加断言忘抬这个数时,`<` 会**静默放行**)。
	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上 —— 要么有断言没跑到,"
				% [_checks, EXPECTED_CHECKS]
				+ "要么有新断言没登记进 EXPECTED_CHECKS(加断言忘抬这个数时,`<` 会静默放行)")
	if _fails.is_empty():
		print("KH RECON-UI PROBE: ALL-OK(%d 条断言)" % _checks)
		get_tree().quit(0)
	else:
		print("KH RECON-UI PROBE: FAIL(%d 条)" % _fails.size())
		for f in _fails:
			print("  ✗ " + f)
		get_tree().quit(1)
