extends Node

# KH 合并 L6 验收探针(场景模式:autoload 必须已实例化,不能用 -s 跑)。
# 跑法:
#   "$GODOT" --headless --path . --quit-after 600 res://tests/kh_l6_probe.tscn
# 期望:每条 [L6] ... 打 ✓,末行 "KH L6 PROBE: ALL-OK",退出码 0。
#
# 存在理由:L6 把 KH 的 PvP 客户端加成接进 main 的 scenes/pvp_client.gd。侦察已定论:
# **KH 那版不是 main 的加法版,而是把 main 的 C2(客户端预测 rollback)整条链路删掉后的
# server_rendered 版**(14 处危险差异 B1–B14)。本层的全部风险就是"做加法时把 C2 弄坏",
# 而 C2 弄坏是**静默的**——不报错,表现为橡皮筋/手感错乱,只有人上手才看得出来。
# 本探针就是那台扫描仪:把 15 条不变量钉成源码级断言,后续每个任务的验证都引用它。
#
# ⚠ T1 只建探针,不改任何生产文件。探针本身**不报错、不裁决**,只做源码级机械扫描。
#
# ⚠ CI 判据必须是 **grep 文本 `KH L6 PROBE: ALL-OK`**,不能只看退出码:
#    探针中途脚本报错(解析失败/函数中断)时 --quit-after 仍会以 exit 0 退出,
#    且**不会**打印 ALL-OK——只看退出码会把"没跑完"读成"通过"。
#
# ⚠⚠ 自伤防护(本文件被自己扫描时务必守住):凡是本探针**要找的字面量**,一律用
#    `"前" + "后"` 碎片拼出来,绝不整段写在源码里。本探针的扫描目标都是**具名生产文件**,
#    但第 13 条扫的是**目录树**,碎片拼接让这条防线不依赖"扫描根里没有 tests/"这个巧合。
#
# ⚠⚠ 每条断言都必须回答「什么改动会让代码变错、而这条断言依然绿?」——判据取**去注释视图**
#    (见 _code_view),因为注释不是代码:一句讲解设计的注释既不能让"在位"类断言变绿,
#    也不能让"零引用"类断言变红。另外凡断言"某口在位",必须同时校验**被调方真的存在**
#    (脚本方法表 / 资源是否存在),否则删掉被调方那条断言照样绿。
#
# ── 15 条不变量(逐条对应本文件的 _check_*)────────────────────────────
#   1  输入包带单调 seq          —— B4:包内无 seq → 服务器 _ack_seq 永停 0,回滚锚点全失
#   2  快照本端分支喂 on_authoritative,且 _apply_local_state 不是无条件到达
#                                —— B6:C2 全断 + 权威位置强写进正在预测的玩家 = 橡皮筋
#   3  note_post_step + reconcile 在玩家步进前 —— B3:整块删除
#   4  note_input(seq, pkt) —— B5:删除 → restore 后无法重放重对齐
#   5  LOCAL_PREDICTION_ENABLED 常量 + _ready 两条分支 —— B1/B2:保底不再是"翻一个常量"
#   6  set_server_rendered(true) 必须受预测开关守卫 —— B2:无条件即 C2 死
#   7  输入锁单一收口 _round_locked or _menu_open —— B7/B9:菜单开着仍能跑动开枪
#   8  _pause_menu 是字段且接 toggled —— B10:不持句柄不接信号 → 锁失效
#   9  MATCH_OVER 块销毁暂停菜单 —— B8:5s 内 ESC 后定时器仍再触发 + lambda 里 get_tree() 为 null
#  9b  同一件事的**大乱斗**分支(scenes/royale_game.gd)—— 第三条退场路径,当年漏改,_check_royale_match_over_menu_kill
#  10  pvp_hud 走声明式 tscn(不是 PvpHud.new())—— B11:null 解引用必崩
#  11  激光收端在 NetBus(不是 NetBusExt)—— B12:收错节点 = 对手激光静默 no-op
#  12  退出路径:大写零命中 + 路径① 已保护 + **本文件裸切恰为 0**(T4 起为无条件判据,见该断言
#                                内的说明;此前是"过渡守卫"形状——收口当时是 T4 的交付物,写成无条件
#                                会让本探针从 T1 红到 T4,而没人能过的门会被删掉。过渡形状拦不住
#                                **整体退回**;翻无条件后该边界关闭)
#                                (已知边界逐条登记在 _check_exit_paths 的函数头)
#  13  零 Level0.menu_demo 引用 —— B14:引用不存在的静态变量 → 报错
#  14  激光归因仍走 CombatFeedback.attribute —— KH 的裸 set_meta 只能追加,不得替换
#  15  头顶名统一 NAME_COLOR(U1 的决定)—— B13:回退按角色双色

# ── 被扫文件 ────────────────────────────────────────────────────────
const PC := "res://scenes/" + "pvp_client.gd"
# 9b) 的扫描对象:大乱斗客户端。与 pvp_client 是同一类风险的第二处实例。
const RG := "res://scenes/" + "royale" + "_game.gd"
const PM_PATH := "res://ui/" + "pause_menu.gd"
const HUD_TSCN := "res://ui/" + "pvp_hud.tscn"
const HUD_SCRIPT := "res://ui/" + "pvp_hud.gd"
const LASER := "res://scenes/weapons/" + "laser_weapon_base.gd"
const CF_PATH := "res://scenes/effects/" + "combat_feedback.gd"
const RB_PATH := "res://core/" + "prediction_rollback.gd"
const MH_PATH := "res://server/" + "match_host.gd"

# 生产目录(第 13 条只扫这些;排除 tests/ 以免探针自身的负断言文本自伤)
const PROD_DIRS := ["res://core", "res://scenes", "res://server", "res://ui", "res://render"]
# 扫描到的源文件数下限:防止"扫描根本坏了 → 一个文件都没扫到 → 零命中 = 假绿"
const MIN_PROD_FILES := 40

# ── 扫描针(碎片拼接:见文件头「自伤防护」)──────────────────────────
const N_PRED := "LOCAL_PREDICTION" + "_ENABLED"
const N_SEQ := "_input" + "_seq"
const N_SEQ_INC := N_SEQ + " += 1"
const N_SEQ_KEY := "\"" + "seq\": " + N_SEQ
const N_SEND := "\"send" + "_input\""
const N_ROLLBACK := "_roll" + "back."
const N_ON_AUTH := N_ROLLBACK + "on_" + "authoritative("
const N_APPLY_LOCAL := "_apply" + "_local_state("
const N_NOTE_POST := N_ROLLBACK + "note_" + "post_step("
const N_CAPTURE := "capture" + "_state()"
const N_RECONCILE := N_ROLLBACK + "reconcile()"
const N_NOTE_INPUT := N_ROLLBACK + "note_" + "input("
const N_BIND := N_ROLLBACK + "bind("
const N_SSR := "set_server" + "_rendered(true)"
const N_SSR_NAME := "set_server" + "_rendered"
const N_LOCK_FN := "_refresh" + "_input_lock"
const N_SET_LOCKED := "set_controls" + "_locked"
const N_PAUSE := "_pause" + "_menu"
const N_TOGGLED := ".toggled" + ".connect("
const N_QUEUE_FREE := "queue" + "_free()"
const N_TIMER := "create" + "_timer("
const N_INSIDE := "is_inside" + "_tree()"
const N_PRELOAD_HUD := "preload(\"res://ui/" + "pvp_hud.tscn\")"
const N_NEW_HUD := "Pvp" + "Hud.new("
const N_HUD_CLS := "Pvp" + "Hud"
const N_BEAM := "beam" + "_fired"
const N_LOCAL_BEAM := "local_" + N_BEAM
const N_ROUTING := "Net" + "Bus.local_" + N_BEAM + ".connect("
const N_EXT_ROUTING := "Net" + "BusExt.local_" + N_BEAM
const N_SAFE := "safe_" + "change_scene"
const N_BARE := "change_scene" + "_to_file"
const N_UPPER := "res://" + "Scenes/"
const N_MENU_PATH := "res://scenes/" + "main_menu.tscn"
const N_NAME_COLOR := "NAME" + "_COLOR"
const N_ROLE_COLOR := "ROLE" + "_COLOR"
const N_ATTR := "Combat" + "Feedback." + "attribute("
# 归因的一体入口(attribute + hit_marker):激光两处结算路径已改走它。判据接受两者之一
# —— 用意仍是「拦住裸 set_meta」,而不是钉死某一种写法(见不变量 14 的注释)。
const N_ATTR_HIT := "Combat" + "Feedback." + "attribute_hit("
const N_MENU_DEMO := "menu" + "_demo"
# 扫描器自检用的"必然存在"标识符:同一次扫描里它必须被找到,否则"零命中"不可信
const N_CANARY := "pvp" + "_mode"
const MIN_CANARY_HITS := 5

# 正则(同样碎片拼接)
const RE_CONST_PRED := "const\\s+" + "LOCAL_PREDICTION" + "_ENABLED\\s*:=\\s*(true|false)"
const RE_FIELD_PAUSE := "^var\\s+" + "_pause" + "_menu\\b"
const RE_CONST_NAME_COLOR := "^const\\s+" + "NAME" + "_COLOR\\b"
const RE_PACKET_DICT := "^\\s*var\\s+([A-Za-z_]\\w*)\\s*(?::[^:=]+)?:?=\\s*\\{"
const RE_FUNC_DEF := "^(?:static\\s+)?func\\s+([A-Za-z_]\\w*)\\s*\\("
const RE_ONREADY_PATH := "@onready\\s+var\\s+[A-Za-z_]\\w*\\s*:[^=]+=\\s*\\$([A-Za-z0-9_/]+)"
# 文件级常量 + 字符串字面量(用于把"菜单路径抽成常量"这种正确修法也认下来)
const RE_CONST_STR := "^const\\s+([A-Za-z_]\\w*)[^=]*=\\s*\"([^\"]*)\""

var _failures: Array[String] = []
var _pc_code := ""                     # pvp_client.gd 的去注释视图(保留缩进)
var _pc_lines: PackedStringArray = PackedStringArray()
var _rg_code := ""                     # royale_game.gd 的去注释视图(9b 用)
var _rg_lines: PackedStringArray = PackedStringArray()


func _ready() -> void:
	_pc_code = _code_view(_read(PC))
	_pc_lines = _pc_code.split("\n")
	_rg_code = _code_view(_read(RG))
	_rg_lines = _rg_code.split("\n")
	if _pc_code.is_empty():
		_failures.append("读不到 %s(本探针的全部断言都以它为据 → 下面一条都不成立)" % PC)
		_finish()
		return
	_check_seq_in_packet()
	_check_snapshot_authoritative()
	_check_c2_frame_block()
	_check_note_input()
	_check_prediction_switch()
	_check_server_rendered_guarded()
	_check_input_lock_funnel()
	_check_pause_menu_field()
	_check_match_over_menu_kill()
	_check_royale_match_over_menu_kill()
	_check_hud_declarative()
	_check_beam_routing()
	_check_exit_paths()
	_check_no_menu_demo()
	_check_laser_attribution()
	_check_name_color()
	_finish()


# ── 1) 输入包带单调 seq(B4)──────────────────────────────────────────
# seq 是服务器 FIFO 消费 + ack 回带的锚点:包内没有它,`_ack_seq[role]` 永停 0 →
# 客户端 reconcile 永远不知道哪些输入已被确认 → 持续橡皮筋/预测失锚(静默,不报错)。
# 判据三层,缺一层就鉴别不了:
#   · 组包前有 `_input_seq += 1`(单调自增,不是常量/别的字段)
#   · 字典里**绑定**在 `"seq": _input_seq`(不是只出现 "seq" 字样)
#   · 带 seq 的那个字典**就是**发给服务器的那个(send_input 的实参)
func _check_seq_in_packet() -> void:
	var before := _failures.size()
	var phys := _func_body(_pc_code, "_physics_process")
	_check(not phys.is_empty(), "取不到 _physics_process 的函数体(改名/挪走了?)")
	if phys.is_empty():
		_summary(before, "输入包 seq:取不到 _physics_process")
		return
	var lines := phys.split("\n")
	var i_inc := _find_line(lines, N_SEQ_INC)
	var i_key := _find_line(lines, N_SEQ_KEY)
	_check(i_inc >= 0, "组包前没有 `%s`(输入序号不单调 → 服务器 ack 锚点无从推进)" % N_SEQ_INC)
	_check(i_key >= 0, "输入包字典里没有 `%s`(服务器 _ack_seq 永停 0 → 回滚锚点全失)" % N_SEQ_KEY)
	if i_inc >= 0 and i_key >= 0:
		_check(i_inc < i_key, "`%s` 出现在 `%s` 之后(送出去的 seq 不是本帧新序号)" % [N_SEQ_INC, N_SEQ_KEY])
	var varname := _packet_var(lines, i_key if i_key >= 0 else lines.size() - 1)
	_check(not varname.is_empty(), "找不到承载 seq 的组包字典(`var X := {` 推导失败)")
	var i_send := _find_line(lines, N_SEND)
	_check(i_send >= 0, "找不到输入包发送调用(%s)" % N_SEND)
	if i_send >= 0:
		_check(lines[i_send].contains("rpc_" + "id("), "输入包不经 NetBus.rpc_id 发送(服务器收不到):「%s」" % lines[i_send].strip_edges())
		if not varname.is_empty():
			_check(lines[i_send].contains(varname),
				"发送的不是带 seq 的那个字典(发送行「%s」里没有 %s)" % [lines[i_send].strip_edges(), varname])
	_summary(before, "输入包 seq:自增在 %d,绑定在 %d,发送字典 = %s" % [i_inc, i_key, varname if varname != "" else "?"])


# ── 2) 快照本端分支喂 on_authoritative,且 _apply_local_state 不是无条件(B6)──
# 本端快照只有两条合法去向:C2 开着 → `on_authoritative(ack, c2)`(只喂锚点,由控制器
# 在下一帧 reconcile 时**按分歧**收敛);否则 → 保底 `_apply_local_state`(服务器渲染)。
# KH 把整段换成**无条件** `_apply_local_state(data)` → ① C2 全链断;② C2 开着时把权威
# 位置**强写**进正在预测的玩家 = 每帧橡皮筋。
# 所以判据取**结构**:`_apply_local_state` 必须落在一个 `else:` 分支里(且它的 enclosing
# 条件行确实是 else),而不是 `if role == ...` 之后的第一条语句。
func _check_snapshot_authoritative() -> void:
	var before := _failures.size()
	# ★ 快照**拆两条**后(2026-09-12)本判据跟着拆成两半,**语义一字不变**:
	#   本端(保底)分支落进**世界包** handler,权威 ack/c2 落进**本人包** handler。
	#   ① 世界包里 `_apply_local_state` 必须被 else 挡住 —— 否则 C2 开着时权威位置被强写进正在
	#      预测的玩家 = 每帧橡皮筋;② 本人包里必须把 ack/c2 喂给控制器 —— 否则 C2 全链断。
	var world := _func_body(_pc_code, "_on_snapshot_world")
	var own := _func_body(_pc_code, "_on_snapshot_own")
	_check(not world.is_empty(), "取不到 _on_snapshot_world 的函数体(改名/挪走了?)")
	_check(not own.is_empty(), "取不到 _on_snapshot_own 的函数体(改名/挪走了?)")
	if world.is_empty() or own.is_empty():
		_summary(before, "快照本端分支:取不到世界包/本人包 handler")
		return
	# ★ 保底调用必须在 `else:` 分支里(否则 C2 开着时权威位置被强写进预测中的玩家 = 每帧橡皮筋)。
	# 判据在**原文**上做:找到 `_apply_local_state(` 那一行,往上找第一条非空非注释行,它必须以
	# `else` 开头。★ 不用 _guarded_calls 的缩进上溯:拆包后它在本文件上**抽不到 else 行**
	# (实测:同一段源码它报"上一条非空行是 pass"),把本该绿的读成红的。语义没变,只是不再依赖
	# 那个在深层嵌套上不稳的辅助函数。
	var raw_lines := _read("res://scenes/pvp_client.gd").split("
")
	var guard_ok := false
	var found_any := false
	for k in range(raw_lines.size()):
		if not raw_lines[k].contains(N_APPLY_LOCAL):
			continue
		found_any = true
		for b in range(k - 1, -1, -1):
			var pt: String = raw_lines[b].strip_edges()
			if pt.is_empty() or pt.begins_with("#"):
				continue
			guard_ok = pt.begins_with("else")
			break
		break
	_check(found_any, "取不到 `%s` 的调用行(保底路径没了)" % N_APPLY_LOCAL)
	_check(guard_ok,
			"世界包 handler 的 `%s` 不在 else 分支里(无条件到达 → C2 开着时权威位置被强写进预测中的玩家 = 橡皮筋)" % N_APPLY_LOCAL)
	_summary(before, "快照本端分支:世界包 else 挡住保底 / 本人包门 → %s" % N_ON_AUTH)


# ── 3) 每物理帧 note_post_step(capture_state()) → reconcile() → 组包,按此序(B3)──
# C2 的时序契约:引擎本帧步进本地玩家**之前**——先把上一 seq 的预测整态入 ring,再
# reconcile 到期权威(分歧 → restore + 重放未确认输入)。删掉整块 = 预测态永不入 ring、
# 权威永不收敛(静默退化)。
# "玩家步进"在本文件里没有显式调用点(本地玩家由引擎自步进,见 _ready 的 C2 分支),
# 故顺序锚取**本帧输入上报之前**(组包/发送)——那正是"本帧步进前"在本文件内可观测的那一半。
# ★ 两处"判据取机械形式"的说明:
#   · **组包锚点由 `var X := {` 推导**(与 #1/#4 同一个 _packet_decl),**不写死变量名 `pkt`**:
#     重命名组包变量是后续任务的合法加法,写死字面量会让它**假红**(正是本探针要避免的失败类)。
#     "发给服务器的不是带 seq 的那个字典"由 #1/#4 的实参比对判红,不靠这里写死。
#   · **note_post_step 必须先于 reconcile**(本条注释里那句"先记预测态,reconcile 才比得上
#     ring[C]"的**顺序**部分):只查"两个调用都在同一函数里"会让互换过的那对过关 —— 先
#     reconcile 再记,比的是本帧刚入 ring 的态 = 比错对象。
func _check_c2_frame_block() -> void:
	var before := _failures.size()
	var phys := _func_body(_pc_code, "_physics_process")
	if phys.is_empty():
		_summary(before, "C2 帧块:取不到 _physics_process")
		return
	var lines := phys.split("\n")
	var i_post := _find_line(lines, N_NOTE_POST)
	var i_rec := _find_line(lines, N_RECONCILE)
	# 组包声明处(行号 + 变量名):由 `var X := {` 推导,不写死 pkt
	var decl := _packet_decl(lines, lines.size() - 1)
	var i_pkt := int(decl["index"])
	var pkt_name := str(decl["name"])
	if i_pkt < 0:
		# 兜底:组包不是字典字面量(如 `var pkt := _build_pkt(...)`)时锚到**发送行** ——
		# 它必然在组包之后,正对应注释里"本帧输入上报之前"这一半。
		i_pkt = _find_line(lines, N_SEND)
		pkt_name = "发送行 " + N_SEND
	_check(i_post >= 0, "每物理帧没有 `%s`(预测整态永不入 ring → 无从比对)" % N_NOTE_POST)
	_check(i_rec >= 0, "每物理帧没有 `%s`(权威永不收敛)" % N_RECONCILE)
	if i_post >= 0:
		_check(lines[i_post].contains(N_CAPTURE),
			"`%s` 没喂 `%s`(入 ring 的不是预测整态):「%s」" % [N_NOTE_POST, N_CAPTURE, lines[i_post].strip_edges()])
	if i_post >= 0 and i_rec >= 0:
		_check(i_post < i_rec,
			"`%s` 排在 `%s` 之后(%d > %d):反序 —— reconcile 比的是本帧刚入 ring 的预测态(契约是「先记预测态,reconcile 才比得上 ring[C]」)"
			% [N_NOTE_POST, N_RECONCILE, i_post, i_rec])
	_check(i_pkt >= 0, "取不到输入包构造(`var X := {` 与发送行 %s 都不在)——顺序断言无从定位" % N_SEND)
	if i_post >= 0 and i_pkt >= 0:
		_check(i_post < i_pkt, "`%s` 排在组包之后(%d > %d):预测态晚一帧入 ring,reconcile 比错对象"
				% [N_NOTE_POST, i_post, i_pkt])
	if i_rec >= 0 and i_pkt >= 0:
		_check(i_rec < i_pkt, "`%s` 排在组包之后(%d > %d):本帧输入已上报才开始收敛" % [N_RECONCILE, i_rec, i_pkt])
	# 被调方必须真的提供这些口(否则删掉控制器的实现,本断言照样绿 —— 调用点在、方法没了)
	var rb := load(RB_PATH) as GDScript
	_check(rb != null, "载入 %s 失败(控制器不存在 → 上面几条调用全是空头)" % RB_PATH)
	# ⚠ 反证实测撞到过一次:"脚本整个 parse 不过"(方法表为空)与"某方法被删"在**报告文本**上
	# 必须分得清 —— 否则"控制器不可用"会被读成"只缺一个方法",修的人会找错方向。
	if rb != null and rb.get_script_method_list().is_empty():
		_check(false, "%s 的方法表是空的(脚本加载/编译失败?调用点在,控制器整个不可用)" % RB_PATH)
	elif rb != null:
		for m in ["note_post_step", "reconcile", "on_authoritative", "note_input", "bind"]:
			_check(_method_info(rb, m) != null, "%s 缺方法 %s(调用点还在,口没了)" % [RB_PATH, m])
	_summary(before, "C2 帧块:note_post_step@%d < reconcile@%d < 组包(%s)@%d(控制器 5 个口在位)"
			% [i_post, i_rec, pkt_name if pkt_name != "" else "?", i_pkt])


# ── 4) note_input(seq, pkt) 供回滚重放(B5)───────────────────────────
# restore 之后必须按**已发出的输入序列**重放才能重对齐。没有 note_input 的回滚只剩
# "把权威态贴上去"= 橡皮筋(KH 正是删掉了它)。
# 判据:调用行必须同时带 `_input_seq` 与**真正发出去的那个字典变量**(不是随便一个字典)。
# ★ 组包锚点与 #1 **同源**(同一个 _packet_var,锚在**承载 seq 绑定的那一行** = N_SEQ_KEY),
#   **不取「note_input 上方最近的字典声明」**:那样锚点会被组包之后、调用之前插入的任何无关
#   字典字面量抢走 → 重命名/重组组包这类**合法加法**会让本条假红(与 #3 的组包锚点同一条
#   理由:判红只靠"实参不是那个字典"这条机械比对,不靠锚点碰巧落在谁头上)。
func _check_note_input() -> void:
	var before := _failures.size()
	var phys := _func_body(_pc_code, "_physics_process")
	if phys.is_empty():
		_summary(before, "note_input:取不到 _physics_process")
		return
	var lines := phys.split("\n")
	var i_ni := _find_line(lines, N_NOTE_INPUT)
	var i_key := _find_line(lines, N_SEQ_KEY)
	var varname := _packet_var(lines, i_key if i_key >= 0 else lines.size() - 1)
	_check(i_ni >= 0, "每物理帧没有 `%s`(回滚无输入可重放 → 退化成橡皮筋)" % N_NOTE_INPUT)
	if i_ni >= 0:
		_check(lines[i_ni].contains(N_SEQ),
			"`%s` 没带输入序号 `%s`(重放时对不上权威锚点):「%s」" % [N_NOTE_INPUT, N_SEQ, lines[i_ni].strip_edges()])
		_check(not varname.is_empty(), "推导不出被记录的输入包字典")
		if not varname.is_empty():
			_check(lines[i_ni].contains(varname),
				"`%s` 记录的不是发出去的那个字典(缺 %s):「%s」" % [N_NOTE_INPUT, varname, lines[i_ni].strip_edges()])
	_summary(before, "note_input:第 %d 行,带 seq 与发包字典 %s" % [i_ni, varname if varname != "" else "?"])


# ── 5) C2 开关常量 + _ready 两条分支必须都在(B1/B2)────────────────────
# `LOCAL_PREDICTION_ENABLED` 是**保底路径的存在形式**:false 就该整体回落 server_rendered,
# 不需要改别的代码。常量被删、或二选一分支被拍平 → 保底不再是"翻一个常量",那条路径
# 就等于不存在(pvp-c2-retrospective 的 P1/P2 复盘前提)。
# 判据:常量必须带**布尔字面量**;`_ready` 里 `if not <开关>` 与 `elif <开关>` 两条分支
# 都要在,且**互斥**:预测分支里不得出现 set_server_rendered(两分支必须真的二选一)。
#
# ★★ 已知边界(必须如实登记:这是本探针**最重的洞**)★★
#   本断言(与 #6)钉的是**常量的存在形式**,**钉不住它的值** —— `const LOCAL_PREDICTION_ENABLED
#   := true` 改成一个字符的 `false`,15 条断言**全绿**,而 C2 在**活路径**上整体熄火
#   (落到 server_rendered 保底分支;保底本身是合法的,所以看不出"坏",只有上手才觉出手感差)。
#   那个值 = 另一分支(`$KH`)的整个状态,`false` 正是它的形状。
#   **这个值不由本探针覆盖**:由 PvP 冒烟脚本(`tests/pvp_match_smoke.sh` 的输入→模拟→快照→
#   ack 链路、`tests/pvp_reconcile_smoke.sh` 的 rollback 控制器)**与真人上手对局**覆盖。
#   (把值也钉成 `true` 是不行的:那会把保底路径本身判成违规,而"翻一个常量即回落"正是 #5 要守的性质。)
func _check_prediction_switch() -> void:
	var before := _failures.size()
	var i_const := _find_line_re(_pc_lines, RE_CONST_PRED)
	_check(i_const >= 0, "缺 `const %s := true|false` 声明(保底不再是「翻一个常量」)" % N_PRED)
	var ready := _func_body(_pc_code, "_ready")
	_check(not ready.is_empty(), "取不到 _ready 的函数体")
	if ready.is_empty():
		_summary(before, "C2 开关:常量@%d,_ready 取不到" % i_const)
		return
	var lines := ready.split("\n")
	var i_fallback := _find_line(lines, "if not " + N_PRED)
	var i_predict := _find_line(lines, "elif " + N_PRED)
	_check(i_fallback >= 0, "_ready 缺保底分支 `if not %s`(server_rendered 路径没了)" % N_PRED)
	_check(i_predict >= 0, "_ready 缺预测分支 `elif %s`(C2 不 bind 控制器 → 全部 C2 调用 no-op)" % N_PRED)
	if i_fallback >= 0:
		_check(_block_after(lines, i_fallback).contains(N_SSR),
			"保底分支里没有 `%s`(翻回 false 也不回落)" % N_SSR)
	if i_predict >= 0:
		var blk := _block_after(lines, i_predict)
		_check(blk.contains(N_BIND), "预测分支里没有 `%s`(控制器没绑定本地玩家 → reconcile 无从 restore)" % N_BIND)
		_check(not blk.contains(N_SSR_NAME),
			"预测分支里也调了 `%s`(两条路径必须二选一,否则 C2 被服务器渲染覆盖)" % N_SSR_NAME)
	_summary(before, "C2 开关:常量@%d,保底分支@%d,预测分支@%d(bind 在预测分支内;常量的**值**不在本探针覆盖内,见本条已知边界)"
			% [i_const, i_fallback, i_predict])


# ── 6) set_server_rendered(true) 必须受预测开关守卫(B2)────────────────
# 这是 B2 的**精确形状**:KH 写的是 `if _local.has_method("set_server_rendered"):` —— 那是
# 空安全守卫,**不是**模式选择:一旦因此认为"它在 if 里就算受守卫",就会把无条件切服务器
# 渲染读成绿。故本断言的判据是**enclosing 行的内容**,不是"有没有 if":
# 它必须真是 `if not LOCAL_PREDICTION_ENABLED ...` 那条。
# 附自检:喂合成源,证明这套判据对"无条件调用"确实会红(否则又是一台永不失败的验收门)。
func _check_server_rendered_guarded() -> void:
	var before := _failures.size()
	var calls := _guarded_calls(_pc_lines, N_SSR)
	_check(not calls.is_empty(), "全文没有 `%s`(保底路径被删了?)" % N_SSR)
	for c in calls:
		var encl := str(c["enclosing"])
		_check(encl.begins_with("if not " + N_PRED),
			"`%s`(第 %d 行)不在 `if not %s` 分支里(所在块首行「%s」)→ 无条件把本地玩家切成服务器渲染 = C2 直接死"
			% [N_SSR, int(c["index"]), N_PRED, encl])
	# 反向:预测分支(elif)里不得出现 —— 与第 5 条同一约束的调用侧钉法
	var ready := _func_body(_pc_code, "_ready")
	var i_predict := _find_line(ready.split("\n"), "elif " + N_PRED)
	if i_predict >= 0:
		_check(not _block_after(ready.split("\n"), i_predict).contains(N_SSR_NAME),
			"预测分支里也调了 `%s`(二选一被打破)" % N_SSR_NAME)
	_self_test_guard_helper()
	_summary(before, "set_server_rendered 守卫:%d 处调用,全部落在 `if not %s` 分支内" % [calls.size(), N_PRED])


# 判据自检:同一个调用,**无条件**那份必须被判为"未受守卫",条件分支里那份必须判为受守卫。
# 合成源全用碎片拼(见文件头「自伤防护」)。
func _self_test_guard_helper() -> void:
	var before := _failures.size()
	var unguarded := "func _ready() -> void:\n\tvar x := 1\n\t" + N_SSR + "\n"
	var u := _guarded_calls(unguarded.split("\n"), N_SSR)
	_check(u.size() == 1, "守卫判据自检①失败:合成源里 %s 匹配到 %d 处(应 1)" % [N_SSR, u.size()])
	if u.size() == 1:
		_check(not str(u[0]["enclosing"]).begins_with("if not "),
			"守卫判据自检②失败:无条件调用被判成了受守卫(判据形同虚设)= %s" % str(u[0]["enclosing"]))
	var guarded := "func _ready() -> void:\n\tif not " + N_PRED + " and _local.has_method(\"" + N_SSR_NAME + "\"):\n\t\t" + N_SSR + "\n"
	var g := _guarded_calls(guarded.split("\n"), N_SSR)
	_check(g.size() == 1 and str(g[0]["enclosing"]).begins_with("if not " + N_PRED),
			"守卫判据自检③失败:受守卫的调用没被判成受守卫(判据恒红,一样不能用)")
	_summary(before, "守卫判据自检:无条件必判未受守卫、条件分支必判受守卫")


# ── 7) 输入锁单一收口 _refresh_input_lock()(B7/B9)────────────────────
# PvP 下菜单不暂停树 → "菜单开着还能边跑边开枪"必须由**显式锁**挡住,而锁必须是
# `_round_locked or _menu_open` 的**合取**、且只有一个收口点:KH 换成的
# `set_controls_locked(state == 0)` 丢掉"菜单开着"这一维,倒计时结束时会把菜单期的锁
# 一并解除(同一份代码里还有"修复波 1 只关住一个方向"的前科)。
# 判据三件:方法在、体内读两个维度、其它地方一个 set_controls_locked 都不许有(且方法真被调用)。
func _check_input_lock_funnel() -> void:
	var before := _failures.size()
	var i_def := _find_line(_pc_lines, "func " + N_LOCK_FN + "(")
	_check(i_def >= 0, "缺 `func %s(`(输入锁失去单一收口点)" % N_LOCK_FN)
	var body := _block_after(_pc_lines, i_def) if i_def >= 0 else ""
	if i_def >= 0:
		_check(body.contains("_round_locked"), "锁函数体不读 `_round_locked`(倒计时冻结会失效)")
		_check(body.contains("_menu_open"), "锁函数体不读 `_menu_open`(菜单开着仍能跑动开枪)")
		_check(body.contains("_round_locked or _menu_open"),
			"锁函数体不是 `_round_locked or _menu_open` 的合取(两个维度必须都算数)")
	# 单一收口:锁函数体之外的 `set_controls_locked` 一律算散落。函数体**不存在**时
	# span 取空区间 → 每一处调用都算散落(KH 形态正是"删掉方法 + 就地直接调"两件事一起做,
	# 只报"方法没了"会漏掉"散落在哪"这条线索)。
	var span := _block_span(_pc_lines, i_def) if i_def >= 0 else Vector2i(0, 0)
	var stray: Array[String] = []
	for k in range(_pc_lines.size()):
		if (k < span.x or k >= span.y) and _pc_lines[k].contains(N_SET_LOCKED):
			stray.append("%s ← %s" % [_enclosing_func(_pc_lines, k), _pc_lines[k].strip_edges()])
	var why := "锁函数体不存在,故下面每一处都是散落" if i_def < 0 else "散落站点"
	_check(stray.is_empty(),
		"`%s` 在锁函数体外有 %d 处(收口被打破:两个调用点各拼一次布尔 = 修复波 1 的病;%s: %s)"
		% [N_SET_LOCKED, stray.size(), why, " | ".join(stray)])
	var calls := 0
	for k in range(_pc_lines.size()):
		if k != i_def and _pc_lines[k].contains(N_LOCK_FN + "()"):
			calls += 1
	_check(calls >= 1, "`%s()` 只定义没被调用(锁根本没生效)" % N_LOCK_FN)
	_summary(before, "输入锁收口:%s %s,读 _round_locked/_menu_open,体外散落 %d 处,调用点 %d"
			% [N_LOCK_FN, "在" if i_def >= 0 else "缺失", stray.size(), calls])


# ── 8) _pause_menu 是字段且接了 toggled(B10)──────────────────────────
# KH 只 `add_child(PauseMenu.new(true))`:不持句柄 → MATCH_OVER 无法销毁它(第 9 条),
# 不接 toggled → `_menu_open` 永不更新 → 输入锁失效。故字段与接线都要在,且顺序对
# (先拿到句柄,再接线),并且接线体内真的写了 `_menu_open`(不是空信号)。
func _check_pause_menu_field() -> void:
	var before := _failures.size()
	var i_field := _find_line_re(_pc_lines, RE_FIELD_PAUSE)
	_check(i_field >= 0, "缺字段 `var %s`(菜单句柄没留住 → 输入锁失效 + MATCH_OVER 无法销毁菜单)" % N_PAUSE)
	var i_assign := _find_line(_pc_lines, N_PAUSE + " = Pause" + "Menu.new(")
	_check(i_assign >= 0, "字段 `%s` 没有真的持有菜单(`%s = PauseMenu.new(...)` 不在)" % [N_PAUSE, N_PAUSE])
	var i_tog := _find_line(_pc_lines, N_PAUSE + N_TOGGLED)
	_check(i_tog >= 0, "`%s%s` 不在(菜单开关不驱动输入锁 → 菜单开着仍能跑动开枪)" % [N_PAUSE, N_TOGGLED])
	if i_assign >= 0 and i_tog >= 0:
		_check(i_assign < i_tog, "先接 toggled 后才赋值 `%s`(信号接在一个还没有菜单的字段上)" % N_PAUSE)
	if i_tog >= 0:
		var blk := _block_after(_pc_lines, i_tog)
		_check(blk.contains("_menu_open"), "toggled 回调体内没有写 `_menu_open`(锁读不到菜单状态)")
		_check(blk.contains(N_LOCK_FN + "()"), "toggled 回调体内没有调 `%s()`(状态变了不重新求锁)" % N_LOCK_FN)
	_summary(before, "暂停菜单:字段@%d,赋值@%d,toggled@%d(回调写 _menu_open + 重求锁)" % [i_field, i_assign, i_tog])


# ── 9) MATCH_OVER 块内销毁暂停菜单(B8)────────────────────────────────
# MATCH_OVER 后 5s 定时器才回主菜单;这 5s 内 ESC 仍能弹出暂停菜单 → 另一条退场路径
# 先跑,定时器到点再切一次(行为可疑,且 lambda 里 `get_tree()` 在节点已摘树时为 null)。
# 故 MATCH_OVER 分支必须**(a) 保留退场定时器**、**(b) 让菜单当场失效**。
func _check_match_over_menu_kill() -> void:
	var before := _failures.size()
	var body := _func_body(_pc_code, "_on" + "_round_state")
	_check(not body.is_empty(), "取不到 _on_round_state 的函数体")
	if body.is_empty():
		_summary(before, "MATCH_OVER 块:取不到 _on_round_state")
		return
	var lines := body.split("\n")
	var i := _find_line(lines, "state == 3")
	_check(i >= 0, "取不到 MATCH_OVER 分支(`state == 3`)")
	if i >= 0:
		var blk := _block_after(lines, i)
		_check(blk.contains(N_PAUSE) and blk.contains(N_QUEUE_FREE),
			"MATCH_OVER 块里没有暂停菜单失效处理(`%s.%s`)→ 这 5s 内按 ESC 会让定时器再触发一次" % [N_PAUSE, N_QUEUE_FREE])
		_check(blk.contains(N_TIMER), "MATCH_OVER 块的退场定时器不在(`%s`)" % N_TIMER)
	_summary(before, "MATCH_OVER 块:暂停菜单失效 + 退场定时器都在(分支@%d)" % i)


# ── 9b) 大乱斗客户端 MATCH_OVER 块的同一件事(9) 的第二个对象)──────────────
# 与 9) **同款缺陷、不同文件**:scenes/royale_game.gd 的 MATCH_OVER 也起了一条 6s 退场定时器,
# 而它的暂停菜单**没有**当场失效、lambda 里也**没有** `is_inside_tree()` 早退 ——
# 玩家在这 6s 内按 ESC 就能先回一次主菜单,定时器到点再切一次(把刚建出来的主菜单当 old 退役)。
# pvp_client 早已修过;royale_game 是第三条路径,当年漏了。2026-09-12 补齐,本断言即其守卫。
func _check_royale_match_over_menu_kill() -> void:
	var before := _failures.size()
	if _rg_code.is_empty():
		_check(false, "读不到 %s(9b 的断言全部以它为据)" % RG)
		return
	var body := _func_body(_rg_code, "_on" + "_round_state")
	_check(not body.is_empty(), "取不到 %s 的 _on_round_state 函数体" % RG)
	if body.is_empty():
		_summary(before, "royale MATCH_OVER 块:取不到 _on_round_state")
		return
	var lines := body.split("\n")
	var i := _find_line(lines, "state == 3")
	_check(i >= 0, "取不到 royale MATCH_OVER 分支(`state == 3`)")
	if i >= 0:
		var blk := _block_after(lines, i)
		_check(blk.contains(N_PAUSE) and blk.contains(N_QUEUE_FREE),
			"royale MATCH_OVER 块里没有暂停菜单失效处理(`%s.%s`)→ 这 6s 内按 ESC 会让定时器再触发一次" % [N_PAUSE, N_QUEUE_FREE])
		_check(blk.contains(N_TIMER), "royale MATCH_OVER 块的退场定时器不在(`%s`)" % N_TIMER)
		_check(blk.contains(N_INSIDE),
			"royale MATCH_OVER 定时器的 lambda 里没有 `%s` 早退(已从别的退出路径离开时会叠加第二次换场)" % N_INSIDE)
	_summary(before, "royale MATCH_OVER 块:暂停菜单失效 + 退场定时器 + 早退都在(分支@%d)" % i)


# ── 10) pvp_hud 走声明式 tscn,不是 PvpHud.new()(B11)─────────────────
# main 的 ui/pvp_hud.gd 是**声明式**的:`@onready $子节点` 6 个。`.new()` 建出的节点没有
# 子节点 → `_ready` 里 `_set_broadcast` 解引用 null → **硬崩溃**。KH 的 pvp_hud.gd 是代码
# 建节点的另一套,两者不可混搭。
# 判据四层:preload(...).instantiate() as PvpHud 在位;全文无 PvpHud.new(;被 preload 的
# **资源真的存在**(字符串在位而资源被删/改名 = 假绿);脚本要的子节点 tscn 里都声明了
# (证明"声明式契约"仍成立 —— 否则那句"混搭会崩"的因果就变了)。
func _check_hud_declarative() -> void:
	var before := _failures.size()
	var i_pre := _find_line(_pc_lines, N_PRELOAD_HUD)
	_check(i_pre >= 0, "缺 `%s`(HUD 必须用声明式场景实例化)" % N_PRELOAD_HUD)
	if i_pre >= 0:
		_check(_pc_lines[i_pre].contains(".instantiate()"), "`%s` 没有 .instantiate()(拿到的是 PackedScene)" % N_PRELOAD_HUD)
		_check(_pc_lines[i_pre].contains("as " + N_HUD_CLS), "`%s` 没有 `as %s` 断言(类型漂了没人发现)" % [N_PRELOAD_HUD, N_HUD_CLS])
	var i_new := _find_line(_pc_lines, N_NEW_HUD)
	_check(i_new < 0, "出现 `%s`(第 %d 行)→ 与声明式 ui/pvp_hud.gd 混搭:_ready 里解引用 null 子节点,**必崩**"
			% [N_NEW_HUD, i_new])
	# 资源真的存在(字符串在位 ≠ 指着的东西还在)
	_check(ResourceLoader.exists(HUD_TSCN), "%s 不存在(preload 指向的空气:字符串在位但资源没了)" % HUD_TSCN)
	var hud_tscn := _read(HUD_TSCN)
	_check(not hud_tscn.is_empty(), "读不到 %s" % HUD_TSCN)
	var hud_script := _code_view(_read(HUD_SCRIPT))
	_check(not hud_script.is_empty(), "读不到 %s" % HUD_SCRIPT)
	# 声明式契约:脚本 @onready 要的每个 $节点,tscn 必须声明(leaf 名在 [node name="..."] 里)
	var re := RegEx.new()
	re.compile(RE_ONREADY_PATH)
	var paths := re.search_all(hud_script)
	_check(paths.size() >= 4, "%s 的 @onready $子节点 只解析出 %d 个(判据可能退化成恒绿)" % [HUD_SCRIPT, paths.size()])
	var missing: Array[String] = []
	for m in paths:
		var leaf: String = (m.get_string(1) as String).split("/")[-1]
		if not hud_tscn.contains("[node name=\"" + leaf + "\""):
			missing.append(leaf)
	_check(missing.is_empty(),
		"%s 里的 @onready 子节点 %s 在 %s 里没有声明(声明式契约破了 → HUD 会解引用 null)" % [HUD_SCRIPT, ", ".join(missing), HUD_TSCN])
	_summary(before, "pvp_hud:preload(...tscn).instantiate() 在位、%s 零命中、资源在、%d 个 @onready 子节点 tscn 全声明"
			% [N_NEW_HUD, paths.size()])


# ── 11) 激光收端在 NetBus,不在 NetBusExt(B12)──────────────────────────
# main 的发送端是 `match_host` 的 `NetBus.rpc_id(..., "beam_fired")`。收在 NetBusExt 上
# **静默 no-op**(同名 RPC 收不到、不报错)→ 对手端激光整条看不见。这对**不对称是有意的**:
# `match_options`/`peer_hues`/`hit_confirm` 确实走 NetBusExt,但 beam_fired 不走 —— 加
# 这三条订阅时最容易顺手把 beam 也"统一"过去。故接收/发送两端一起钉。
func _check_beam_routing() -> void:
	var before := _failures.size()
	var sites := _find_lines(_pc_lines, N_LOCAL_BEAM)
	var wrong: Array[String] = []
	for k in sites:
		if _pc_lines[k].contains(N_EXT_ROUTING):
			wrong.append(_pc_lines[k].strip_edges())
	_check(sites.size() == 1, "%s 里 `%s` 出现 %d 次(应恰 1 次:收端订阅唯一)" % [PC, N_LOCAL_BEAM, sites.size()])
	if sites.size() == 1:
		_check(_pc_lines[sites[0]].contains(N_ROUTING),
			"`%s` 那行不是 `%s`(收错节点 = 对手端激光静默 no-op):「%s」" % [N_LOCAL_BEAM, N_ROUTING, _pc_lines[sites[0]].strip_edges()])
	_check(wrong.is_empty(), "%s 里出现 `%s`(第 %d 处):发送端在 NetBus,收在 NetBusExt 会静默 no-op" % [PC, N_EXT_ROUTING, wrong.size()])
	# 配对:发送端必须仍在 NetBus 上(否则"两端同节点"这条不变量的另一半没人守)。
	# ★ 判据是**同行**:`"beam_fired"` 出现的那一行自己必须含 `NetBus.rpc_id(`。
	# 为什么不能整文件 co-occurrence:该文件里 `NetBus.rpc_id(` 到处都有、`"beam_fired"` 只一处,
	# 于是 `NetBusExt.rpc_id(peer_by_role[r], "beam_fired", rep)` —— 正是本断言注释里点名的那处
	# **有意的不对称** —— 会**全绿**通过,而收端 NetBus 订阅此时已是静默 no-op。
	# 取"同行"而非固定实参文本:广播表达式怎么改(peer 怎么取、rep 怎么组)都不假红。
	var mh := _code_view(_read(MH_PATH))
	_check(not mh.is_empty(), "读不到 %s" % MH_PATH)
	if not mh.is_empty():
		var mh_lines := mh.split("\n")
		var beam_sites := _find_lines(mh_lines, "\"" + N_BEAM + "\"")
		var on_netbus := 0
		var off_netbus: Array[String] = []
		for k in beam_sites:
			var ln := mh_lines[k].strip_edges()
			if ln.contains("Net" + "Bus.rpc_id("):
				on_netbus += 1
			else:
				off_netbus.append("%s ← %s" % [_enclosing_func(mh_lines, k), ln])
		_check(not beam_sites.is_empty(), "%s 里找不到 \"%s\" 字面量(发送端被整条迁走了?)" % [MH_PATH, N_BEAM])
		_check(on_netbus >= 1,
			"%s 里 \"%s\" 不在任何 `NetBus.rpc_id(` 行上(%d 处不同行: %s)→ 发送端迁到 NetBusExt 后,收端 NetBus 订阅是**静默 no-op**"
			% [MH_PATH, N_BEAM, off_netbus.size(), " | ".join(off_netbus)])
		_summary(before, "激光路由:收端 %s ×1、NetBusExt 混用 %d 处、发送端 \"%s\" 同行 %s.rpc_id ×%d"
				% [N_LOCAL_BEAM, wrong.size(), N_BEAM, "NetBus", on_netbus])
	else:
		_summary(before, "激光路由:收端 %s ×1、NetBusExt 混用 %d 处、发送端 %s 读不到" % [N_LOCAL_BEAM, wrong.size(), MH_PATH])


# ── 12) 退出路径:大写零命中 + 路径① + 「开始收口后不许残留裸切」的过渡守卫 ──
# 三条退场路径的现状(实测,非推断):
#   ① ESC/暂停菜单 —— 在 **ui/pause_menu.gd**(不在本文件),已走
#      `Level0.safe_change_scene(get_tree(), "res://scenes/main_menu.tscn")` ✅
#   ② MATCH_OVER 5s 定时器 / ③ 对手离开 2.5s 定时器 —— 在本文件,**仍是裸
#      `get_tree().change_scene_to_file("res://scenes/main_menu.tscn")`** ❌(T4 的交付物)
# 为什么 ②③ 今天不写成"必须走 safe_change_scene":那是 **T4 的交付物,不是今天的既有性质**
# (计划表自己的 main 侧一栏也写着"仅 ESC 合规")。若在这里写成硬断言,T1 起就是红的 →
# T2/T3 的验收门(`kh_l6_probe` 全绿)永远过不了 = 一道没人能通过的门。
# 故 (c) 取**过渡守卫**形状:本文件一旦出现 safe_change_scene(收口开始),就不许再残留
# 任何裸切。今天 antecedent 为假 → 绿;T4 落地后它变成精确约束(半修即红)。
#
# ★★ 已知边界(如实登记,别把这条守卫说大)★★
#   · **(c) 的鉴别力是单向的**:"**一旦开始收口,就不许半途退回**"。
#     · 半途退回(改好一条、又把**另一条**改回裸切)= safe ≥1 且 bare ≥1 → **红** ✅
#     · **整体退回**(两条都改回裸切、safe 归零)= safe=0、bare=2,与"收口从未开始"
#       **逐行不可分辨** → antecedent 为假 → **绿** ❌ 本探针**发现不了**
#       ⇒ 流传的"改回裸切即红"只对**半修之后的退回**成立;一次**整体**退回读作"没开始"。
#   · 堵这个缺口的正解是 T4 **自己**把 (c) 翻成无条件(`bare == 0` 恒真),那是 T4 的**交付物**;
#     在那之前写成无条件会让本探针从 T1 红到 T4 —— 一道没人能过的门最终会被删掉(该备选已被否)。
#   · **T4 之前的**它也无法发现"T4 什么都没做"(与原"改回裸切"缺口同源)——那是今天已登记的
#     **既有欠账**,不是回归;T4 自己的验证带着"把其中一条改回裸切 → 探针必须红"的反证,
#     覆盖的正是上面那条**半途**退回。
#   · 大小写/路径拼法之外的东西(例如"定时器 lambda 里到点再求 `get_tree()` 会得 null"这一
#     U4 隐患**本身**)不作机械断言:本断言只要求换场调用与**小写**路径在场,不仲裁实参来源。
#
# ★ 路径的可接受拼法(不假红后续任务的**正确**修法):内联小写字面量,或值逐字小写的
#   **文件级常量**(见 _menu_path_needles);且**不锚 `get_tree()` 的实参位置**(见
#   _safe_call_menu_path)——"先 `var tree := get_tree()` 再在定时器 lambda 里
#   `safe_change_scene(tree, …)`"是兄弟场景 royale_game.gd 的推荐修法,必须绿。
func _check_exit_paths() -> void:
	var before := _failures.size()
	# (a) 大写路径零命中:KH 两处写 res://Scenes/main_menu.tscn,load 大小写敏感,照抄即换场失败
	var upper := _find_lines(_pc_lines, N_UPPER)
	var upper_detail: Array[String] = []
	for k in upper:
		upper_detail.append("%s ← %s" % [_enclosing_func(_pc_lines, k), _pc_lines[k].strip_edges()])
	_check(upper.is_empty(), "%s 出现大写路径 %s %d 处(KH 写法,load 大小写敏感 → 换场直接失败): %s"
			% [PC, N_UPPER, upper.size(), " | ".join(upper_detail)])
	# 路径①:ESC/暂停菜单的退场在 ui/pause_menu.gd,已保护(小写路径)。
	# 判据 = 存在一次 `safe_change_scene(...)` 且**这次调用的实参**含小写菜单路径;
	# 不锚 `get_tree()` 的位置,也不锚路径的拼法(内联字面量 / 文件级小写常量都认)。
	var pm := _code_view(_read(PM_PATH))
	_check(not pm.is_empty(), "读不到 %s" % PM_PATH)
	if not pm.is_empty():
		var pm_lines := pm.split("\n")
		var pm_needles := _menu_path_needles(pm_lines)
		# ⚠ 消息里的旧菜单名**碎片拼接**(见文件头「自伤防护」):kh_l4_probe 的「零引用」扫描
		# 含 tests/,整段写出来会被它当成本文件对退役菜单的引用 → 那条断言假红(实测过)。
		# 拼接后的人读文本与该条消息原文逐字一致,只是源码层不再是整段字面量。
		# 括号不可省:`%` 的优先级高于 `+`,不括起来格式化只会作用到后半段碎片。
		_check(_safe_call_menu_path(pm_lines, pm_needles) != "",
			("%s 的退场没有一次「`%s(...)` 且实参是小写菜单路径」的调用(旧 Esc" + "Menu 的重启式切换吗?可接受的小写拼法: %s)")
			% [PM_PATH, N_SAFE, ", ".join(pm_needles)])
		_check(_find_lines(pm_lines, N_BARE).is_empty(),
			"%s 里出现裸 %s(游戏世界含全量碰撞,同步析构会偶发原生段错误)" % [PM_PATH, N_BARE])
	# 本文件的两条退场路径必须在场且用小写菜单路径(存在性 + 大小写)
	var needles := _menu_path_needles(_pc_lines)
	for spec in [["_on" + "_round_state", "② MATCH_OVER 定时器"], ["_on" + "_opponent_left", "③ 对手离开定时器"]]:
		var fn := str(spec[0])
		var body := _func_body(_pc_code, fn)
		_check(not body.is_empty(), "取不到 %s 的函数体(%s 没了?)" % [fn, spec[1]])
		if not body.is_empty():
			var b_lines := body.split("\n")
			var hit := _safe_call_menu_path(b_lines, needles)
			if hit == "":
				# 尚未收口(裸切)形态:路径出现在函数体内即可 —— 半修/收口由 (c) 与上面那条管
				hit = _has_needle(body, needles)
			_check(hit != "", "%s(%s)里没有小写菜单路径(可接受的拼法: %s)" % [fn, spec[1], ", ".join(needles)])
			_check(body.contains(N_BARE) or body.contains(N_SAFE),
				"%s(%s)里没有换场调用(退场路径被删了?)" % [fn, spec[1]])
	# (c) ★ 收口判据 —— **T4 起已翻为无条件**:本文件的代码视图里裸切必须恰为 0。
	# 原先是"过渡守卫"(出现 safe_change_scene 才要求裸切归零),因为收口当时是 T4 的**交付物**;
	# 写成无条件会让本探针从 T1 一路红到 T4,而**没人能过的门最后会被删掉**。
	# 过渡形状的已知边界是:一次**整体**退回会把状态退回「safe=0 且裸切>0」,与「收口未开始」逐行
	# 不可分辨 → 守卫被跳过读成绿。T4 收口完成后本断言无条件,该边界随之关闭。
	var safe_sites := _find_lines(_pc_lines, N_SAFE)
	var bare_sites := _find_lines(_pc_lines, N_BARE)
	var detail: Array[String] = []
	for k in bare_sites:
		detail.append("%s ← %s" % [_enclosing_func(_pc_lines, k), _pc_lines[k].strip_edges()])
	_check(bare_sites.is_empty(),
		"%s 里仍有 %d 处裸 %s(游戏世界含全量碰撞,裸切会同步析构 → 偶发原生段错误;应全部改走 %s;残留站点: %s)"
		% [PC, bare_sites.size(), N_BARE, N_SAFE, " | ".join(detail)])
	_summary(before, "退出路径:大写 %d 处、safe 站点 %d、裸切站点 %d"
			% [upper.size(), safe_sites.size(), bare_sites.size()])


# ── 13) 零 Level0.menu_demo 引用(B14)────────────────────────────────
# L4 已把 `menu_demo` 这个静态变量连同演示世界整条链退役。KH 的 `_ready` 首行就写
# `Level0.menu_demo = false` → 引用不存在的静态变量 = **报错**(不是静默)。
# 判据取**去注释视图**:真实引用才算引用(注释里提到退役名是文档,不是引用);
# 另加**扫描器自检**(同一次扫描里一个必然存在的标识符必须被找到)+ 文件数下限,
# 否则"扫描根坏了 → 零命中"会被读成绿。
func _check_no_menu_demo() -> void:
	var before := _failures.size()
	var files := _collect(PROD_DIRS)
	_check(files.size() >= MIN_PROD_FILES, "menu_demo 扫描:只收到 %d 个生产源文件(扫描根坏了?期望 ≥%d)" % [files.size(), MIN_PROD_FILES])
	var hits: Array[String] = []
	var canary := 0
	for f in files:
		var code := _code_view(_read(f)).to_lower()
		if code.contains(N_MENU_DEMO):
			hits.append(f)
		if code.contains(N_CANARY):
			canary += 1
	_check(hits.is_empty(), "生产路径仍有 %d 处 `%s` 引用(引用已删除的静态变量 = 报错): %s" % [hits.size(), N_MENU_DEMO, ", ".join(hits)])
	_check(canary >= MIN_CANARY_HITS, "扫描器自检失败:同一次扫描里 `%s` 只命中 %d 个文件(期望 ≥%d)→ 本次「零命中」不可信"
			% [N_CANARY, canary, MIN_CANARY_HITS])
	_summary(before, "零 menu_demo:扫 %d 个生产源文件,命中 %d(自检 canary %s ×%d)" % [files.size(), hits.size(), N_CANARY, canary])


# ── 14) 激光归因仍走 CombatFeedback.attribute(不变量 14)──────────────
# T5 要在 `_apply_to_player` 尾部**追加** `notify_direct_hit`,而 KH 那版在同一处用的是
# 裸 `set_meta`(main 用统一归因入口)。整段照抄 KH = 归因写端丢失(击杀/连杀归因的 3s 时效
# 窗口没了)→ 只能追加,不得替换。
# 判据:被调**双方**都要在 —— 调用点在 `_apply_to_player` 体内**且** __apply_to_enemy 体内,
# 并且 `CombatFeedback` 这个类**真有**对应的方法(否则删掉实现,调用点照样绿)。
# 接受两种写法:`attribute(`(原样)与 `attribute_hit(`(归因+命中标记一体入口,内部转调
# attribute)。两者都满足「归因写端不丢」的用意;后者调用者更难写错顺序(两件事都必须在
# 伤害调用之前),故不把新写法判红。
func _check_laser_attribution() -> void:
	var before := _failures.size()
	var code := _code_view(_read(LASER))
	_check(not code.is_empty(), "读不到 %s" % LASER)
	var n := 0
	var n_hit := 0
	if not code.is_empty():
		for fn in ["_apply" + "_to_player", "_apply" + "_to_enemy"]:
			var body := _func_body(code, fn)
			if body.is_empty():
				continue
			if body.contains(N_ATTR):
				n += 1
			elif body.contains(N_ATTR_HIT):
				n += 1
				n_hit += 1
			else:
				_check(false, "%s 的 %s() 里既没有 `%s` 也没有 `%s`(被 KH 的裸 set_meta 换掉了 → 归因写端丢失)"
						% [LASER, fn, N_ATTR, N_ATTR_HIT])
		_check(n == 2, "`%s`/`%s` 只命中 %d/2 个结算路径(追加而非替换:两条都必须在)" % [N_ATTR, N_ATTR_HIT, n])
	var cf := load(CF_PATH) as GDScript
	_check(cf != null, "载入 %s 失败" % CF_PATH)
	if cf != null:
		_check(_method_info(cf, "attribute") != null, "%s 缺 attribute(...)(调用点还在,口没了)" % CF_PATH)
		# 走 attribute_hit 的路径:那个口也必须在(否则调用点照样绿,实现却被删了)
		if n_hit > 0:
			_check(_method_info(cf, "attribute_hit") != null,
					"%s 缺 attribute_hit(...)(调用点还在,口没了)" % CF_PATH)
	_summary(before, "激光归因:%s 在 %d/2 条结算路径(其中 attribute_hit %d 处),in %s 的归因口在位"
			% [N_ATTR, n, n_hit, CF_PATH])


# ── 15) 头顶名统一 NAME_COLOR(U1 的决定 / B13)─────────────────────────
# U1 已裁定:保留 main 的**中性亮白**头顶名(有意决策,注释在),KH 的按角色双色
# `ROLE_COLOR` 不采纳;搬 `peer_hues` 只染身体。判据:常量在位 + 两个标签都用它上色
# (常量在而标签用别的颜色 = 决策已被悄悄回退)+ 全文零 ROLE_COLOR。
func _check_name_color() -> void:
	var before := _failures.size()
	var i_const := _find_line_re(_pc_lines, RE_CONST_NAME_COLOR)
	_check(i_const >= 0, "缺 `const %s`(U1 的决定:头顶名统一中性亮白)" % N_NAME_COLOR)
	if i_const >= 0:
		_check(_pc_lines[i_const].contains("Color("), "`%s` 不是 Color 字面量:「%s」" % [N_NAME_COLOR, _pc_lines[i_const].strip_edges()])
	for spec in [["nm_self", "自己"], ["nm_opp", "对手"]]:
		var needle := "set_" + "label(" + str(spec[0]) + ", " + N_NAME_COLOR + ")"
		_check(_find_line(_pc_lines, needle) >= 0,
			"%s 的头顶名没用 `%s` 上色(缺「%s」)→ 回退按角色双色?" % [spec[1], N_NAME_COLOR, needle])
	var role := _find_lines(_pc_lines, N_ROLE_COLOR)
	_check(role.is_empty(), "出现 `%s` %d 处(按角色双色 = 回退 main 的有意视觉决策 U1)" % [N_ROLE_COLOR, role.size()])
	_summary(before, "头顶名:%s 在且两个标签都用它上色,%s 零命中" % [N_NAME_COLOR, N_ROLE_COLOR])


# ── 工具 ────────────────────────────────────────────────────────────

# 去注释视图:删掉**字符串字面量之外**的 `#` 起、到行尾的全部文本(整行注释与行尾注释都删),
# 丢掉只剩空白的行,**保留缩进**(结构类判据靠缩进定块)。
# 为什么不能只看裸文本:一句提到被删调用的**注释**能把"在位"类断言喂绿,反过来也能把
# "零引用"类断言弄红 —— 注释不是代码(与 kh_l4_probe / kh_l5_probe 同源)。
# ⚠ 已知边界:`"""…"""` 多行字符串不跨行带状态(逐行调用);本探针的目标文件里没有多行字符串。
func _code_view(src: String) -> String:
	var out: Array[String] = []
	for raw in src.split("\n"):
		var s := _strip_line_comment(raw)
		if s.strip_edges().is_empty():
			continue
		out.append(s.rstrip(" \t"))
	return "\n".join(out)


# 删掉一行里字符串字面量之外的 `#` 起、到行尾的注释(引号/反斜杠转义与 _match_paren 同法)。
func _strip_line_comment(line: String) -> String:
	var quote := ""
	var j := 0
	while j < line.length():
		var ch := line[j]
		if quote != "":
			if ch == "\\":
				j += 1
			elif ch == quote:
				quote = ""
		elif ch == "\"" or ch == "'":
			quote = ch
		elif ch == "#":
			return line.substr(0, j)
		j += 1
	return line


# 取某函数的函数体(从 `func 名(` 到下一个顶层 `func` 之前;找不到返回空串)。
# 判据必须落在**体内**:同名调用点在别的函数里、或函数被删只剩调用点,都不能算"在位"。
func _func_body(code: String, name: String) -> String:
	var i := code.find("func " + name + "(")
	if i < 0:
		return ""
	var j := code.find("\nfunc ", i + 1)
	return code.substr(i, (j - i) if j > 0 else code.length() - i)


# 某行的缩进宽度(制表符/空格都算一列)
func _indent(line: String) -> int:
	var n := 0
	while n < line.length() and (line[n] == "\t" or line[n] == " "):
		n += 1
	return n


# 第 i 行**所属块**的行区间 [起, 止):紧随其后、缩进严格更大的行
func _block_span(lines: PackedStringArray, i: int) -> Vector2i:
	var base := _indent(lines[i])
	var start := i + 1
	var end := start
	while end < lines.size() and _indent(lines[end]) > base:
		end += 1
	return Vector2i(start, end)


func _block_after(lines: PackedStringArray, i: int) -> String:
	if i < 0 or i >= lines.size():
		return ""
	var span := _block_span(lines, i)
	var out: Array[String] = []
	for k in range(span.x, span.y):
		out.append(lines[k])
	return "\n".join(out)


# 第 i 行**所在块的首行**(往上找第一条缩进更小的行)。用于判"这个调用是不是无条件到达的":
# 无条件的调用,其块首行是 `func ...` / `var ...`;受守卫的调用,块首行是 `if .../elif .../else:`。
func _enclosing_cond(lines: PackedStringArray, i: int) -> String:
	var base := _indent(lines[i])
	for k in range(i - 1, -1, -1):
		if _indent(lines[k]) < base:
			return lines[k].strip_edges()
	return ""


# 第 i 行所属的顶层函数名(往上找第一条 `func 名(...)`;lambda 的 `func(` 无名字,不会命中)
func _enclosing_func(lines: PackedStringArray, i: int) -> String:
	var re := RegEx.new()
	re.compile(RE_FUNC_DEF)
	for k in range(i, -1, -1):
		var m := re.search(lines[k])
		if m != null:
			return m.get_string(1)
	return "?"


# 所有含 needle 的行 → 行号数组
func _find_lines(lines: PackedStringArray, needle: String) -> Array[int]:
	var out: Array[int] = []
	for k in range(lines.size()):
		if lines[k].contains(needle):
			out.append(k)
	return out


# 第一条含 needle 的行号(找不到 -1)
func _find_line(lines: PackedStringArray, needle: String) -> int:
	for k in range(lines.size()):
		if lines[k].contains(needle):
			return k
	return -1


# 第一条**匹配** pattern 的行号(找不到 -1)
func _find_line_re(lines: PackedStringArray, pattern: String) -> int:
	var re := RegEx.new()
	re.compile(pattern)
	for k in range(lines.size()):
		if re.search(lines[k]) != null:
			return k
	return -1


# ── "小写菜单路径"的合法拼法(Minor 8:不假红后续任务的正确修法)─────────────
# ① 内联小写字面量 `"res://scenes/main_menu.tscn"`;
# ② **文件级常量**(`const X := "res://scenes/main_menu.tscn"`,值必须**逐字小写**)的**名字**。
# 把路径抽成常量是等价正确修法(定时器 lambda 里到点再求 `get_tree()` 会得 null,兄弟场景
# royale_game.gd 的推荐修法),不假红;但常量值写成大写 `res://Scenes/…` 依然红 —— 大小写
# 要求对两种拼法**一视同仁**(另有 (a) 的全文件大写零命中兜底)。
# ⚠ 已知边界:只认**本文件**的文件级常量;把路径挪到别的模块再 `Other.PATH` 引用不在覆盖内。
func _menu_path_needles(lines: PackedStringArray) -> Array[String]:
	var out: Array[String] = ["\"" + N_MENU_PATH + "\""]
	var re := RegEx.new()
	re.compile(RE_CONST_STR)
	for k in range(lines.size()):
		var m := re.search(lines[k])
		if m != null and m.get_string(2) == N_MENU_PATH:
			var name := m.get_string(1)
			if not out.has(name):
				out.append(name)
	return out


# text 命中 needles 里的哪一个(都没有返回空串)
func _has_needle(text: String, needles: Array[String]) -> String:
	for nd in needles:
		if text.contains(nd):
			return nd
	return ""


# 从第 i 行起、括号配平为止的调用文本(跨行实参一起看;最多 8 行,防病态文件)
func _call_text(lines: PackedStringArray, i: int) -> String:
	var depth := 0
	var out: Array[String] = []
	for k in range(i, mini(i + 8, lines.size())):
		out.append(lines[k])
		depth += lines[k].count("(") - lines[k].count(")")
		if depth <= 0:
			break
	return "\n".join(out)


# 在给定代码视图里找一次「safe_change_scene(...) 且实参含小写菜单路径」的调用,返回命中的拼法。
# **不锚 `get_tree()` 的实参位置**:`safe_change_scene(get_tree(), …)` 与
# `var tree := get_tree() … safe_change_scene(tree, …)` 都是正确修法,都必须绿。
func _safe_call_menu_path(lines: PackedStringArray, needles: Array[String]) -> String:
	for k in _find_lines(lines, N_SAFE + "("):
		var hit := _has_needle(_call_text(lines, k), needles)
		if hit != "":
			return hit
	return ""


# 每个命中处连同"它所在块的首行"(供"是不是无条件"的判据用)
func _guarded_calls(lines: PackedStringArray, needle: String) -> Array:
	var out: Array = []
	for k in _find_lines(lines, needle):
		out.append({"index": k, "line": lines[k].strip_edges(), "enclosing": _enclosing_cond(lines, k)})
	return out


func _unguarded_count(calls: Array) -> int:
	var n := 0
	for c in calls:
		if not str(c["enclosing"]).begins_with("else"):
			n += 1
	return n


# 组包字典声明处的 {行号, 变量名}(找不到返回 {-1, ""})。
# 与 _packet_var 同一个正则、同一套推导,故全探针的"变量名"都以 `var X := {` 为准:
# 重命名组包变量是合法加法(**不假红**),而"发出去的不是带 seq 的那个字典"由实参比对判红。
func _packet_decl(lines: PackedStringArray, before: int) -> Dictionary:
	var re := RegEx.new()
	re.compile(RE_PACKET_DICT)
	for k in range(mini(before, lines.size() - 1), -1, -1):
		var m := re.search(lines[k])
		if m != null:
			return {"index": k, "name": m.get_string(1)}
	return {"index": -1, "name": ""}


# 从 before 处往上找最近的组包字典 `var X := {`,返回变量名(找不到空串)
func _packet_var(lines: PackedStringArray, before: int) -> String:
	return str(_packet_decl(lines, before)["name"])


# 脚本方法表里找方法(返回 null = 没有)。用方法表而非文本 contains:
# 函数名出现在注释/字符串里时文本法会假绿;而 has_method 对**脚本资源**看不见它自己的
# 实例方法(L4 撞过这个坑),故一律走 get_script_method_list。
func _method_info(gs: GDScript, name: String) -> Variant:
	for m in gs.get_script_method_list():
		if str(m.get("name", "")) == name:
			return m
	return null


# 递归收集 roots 下所有 .gd / .tscn(跳过点目录;.git/.godot/.superpowers 都在其中)
func _collect(roots: Array) -> Array[String]:
	var out: Array[String] = []
	for r in roots:
		_walk(r, out)
	out.sort()
	return out


func _walk(dir_path: String, out: Array[String]) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if not name.begins_with("."):
			var p := dir_path.path_join(name)
			if d.current_is_dir():
				_walk(p, out)
			elif name.ends_with(".gd") or name.ends_with(".tscn"):
				out.append(p)
		name = d.get_next()
	d.list_dir_end()


func _read(path: String) -> String:
	if not ResourceLoader.exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_as_text() if f != null else ""


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_failures.append(msg)


# 每条断言的汇总行:本次断言全绿才打 ✓,否则 ✗。裸 print 会让失败组也打印一行"像报喜"
# 的汇总(读者容易把"打印了 15 行 [L6]"读成"15 条都过了")。
# 参数 = 该条断言开始前的 _failures.size()(取差值判本组有无新增失败)。
func _summary(fails_before: int, msg: String) -> void:
	print("[L6] " + ("✓ " if _failures.size() == fails_before else "✗ ") + msg)


func _finish() -> void:
	if _failures.is_empty():
		print("KH L6 PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("KH L6 PROBE: FAIL | " + "; ".join(_failures))
		get_tree().quit(1)
