extends ProbeBase

# 声明式 HUD 契约守卫(阶段:UI 代码生成节点搬进 .tscn)。
#
# 守的是什么:凡「由 .tscn 声明节点、脚本只 @onready 取」的界面,
#   ① 宿主必须用 (load/preload(...tscn)).instantiate() 建,**绝不** <类>.new();
#   ② 脚本里每个 `@onready var x = $A/B/C` 的**叶子名** C,必须在配套 .tscn 里
#      有 `[node name="C"` 声明。
#   ③ **`TeamHud` 的 `_my_team` 契约**(语义面,见 `_check_team_my_team_contract`):那是
#      个"外部不写就静默判错胜负"的口 —— 结构断言(①②)一个都照不到它。
#   ④ **`res://scenes/` 下零 `MatchResult.new(`**(源码面,见 `_check_result_scene_instantiation`):
#      结算页的 `layer = 150` **只住在** `ui/match_result.tscn` 里,`.new()` 建出来的是默认的
#      layer 1 ⇒ 画在三个 HUD(130)/小地图(131)**底下**,压暗罩也盖不住(静默)。
#      ★ 扫描面**走盘**、判据**剥注释** —— 两条理由都写在那个函数上方,别化简回去。
#   ⑤ **`_show_result()` 不得早退**(源码面,见 `_check_result_refresh_not_gated`):
#      结算页是「挂载一次、**每次都刷新**」。恢复 `if _result != null: return` 会把"挂载幂等"
#      顺手变成"更新也只一次" ⇒ 第二条 MATCH_OVER 载荷静默丢掉,而 `MatchResult.show_result`
#      的清场重建(`ui/match_result.gd` 的 remove_child→queue_free 那段)在生产里**一次都不跑**。
#      ★ 判据**必须剥注释** —— 正确实现的注释里就写着这行字面量(见那个函数上方)。
#
# ★ ② 的**适用前提**(2026-09-20,加 `ui/match_result` 那一行时补):② 守的是「@onready
#   取回声明节点」这件事,而**不是**每个 tscn 都必须声明节点。所以本文件先问一句
#   `_scene_declares_nodes(tscn)`:
#     · 声明了子节点 ⇒ 脚本必须至少取回一个(原判据,三个 HUD 一字未动);
#     · **裸骨架**(tscn 除根之外不声明任何节点)⇒ 0 个 @onready 是**正确形状**。
#       `ui/match_result.tscn` 正是这一种:面板由 `_ready()` 用 `UiFactory` 全建 ——
#       那是该文件**刻意**的取舍("手写锚点是'改错了不报错'的一类")。
#   ⚠ 别把这一段读成"放宽":它对**声明了节点的**场景一字未改。反过来,若谁把一个
#     声明式脚本的 @onready 全删了,只要 tscn 里还留着节点,② 照旧报红。
# 为什么值一条探针:.new() 建出来的节点**没有子节点**,而声明式脚本的 _ready 会直接
#   解引用它们 → 硬崩溃。这不是假设 —— tests/kh_l6_probe.gd 第 10 条记的正是 B11
#   (pvp_hud 那次)。本探针把同一份契约扩到后续搬的三套;kh_l6 第 10 条仍只守 pvp_hud,
#   **不要去改它**(改一条已绿的探针收益低于风险)。
#
# 跑法:
#   "$GODOT" --headless --path . --quit-after 3600 res://tests/hud_declarative_probe.tscn
# 判据:末行 "KH HUD PROBE: ALL-OK"(grep 文本,不看退出码)。
#
# ★ 注意本文件是源码级探针,但被 kh_l4/kh_l5 的字号扫描覆盖(res://tests 在 ALL_DIRS 里)
#   —— 正文里不许出现非 16 倍数的字号载体字面量。本文件没有字号,安全。

# [脚本, 配套 tscn, 类名] —— 每搬一套加一行
const PAIRS := [
	["res://ui/royale_hud.gd", "res://ui/royale_hud.tscn", "RoyaleHud"],
	["res://ui/combat_feedback.gd", "res://ui/combat_feedback.tscn", "CombatFeedback"],
	["res://ui/team_hud.gd", "res://ui/team_hud.tscn", "TeamHud"],
	["res://ui/match_result.gd", "res://ui/match_result.tscn", "MatchResult"],
]

# 参数下限:防止 PAIRS 被误删成空表 → 零循环 → 恒绿
const MIN_PAIRS := 2

# @onready var <名>[: 类型] = $<路径>   → 捕获组 2 = 路径
const RE_ONREADY := "@onready\\s+var\\s+(\\w+)\\s*(?::\\s*[\\w\\[\\]]+\\s*)?=\\s*\\$([\\w/]+)"


func probe_id() -> String:
	return "HUD"


func _ready() -> void:
	var before := _failures.size()
	_check(PAIRS.size() >= MIN_PAIRS,
			"PAIRS 只剩 %d 组(判据退化:至少要有 %d 组,否则本探针变成恒绿)" % [PAIRS.size(), MIN_PAIRS])
	for p in PAIRS:
		_check_pair(str(p[0]), str(p[1]), str(p[2]))
	_summary(before, "声明式契约:扫 %d 组「脚本 ↔ 场景」,零 .new()、@onready 路径全声明" % PAIRS.size())
	_check_team_my_team_contract()
	_check_result_scene_instantiation()
	_check_result_refresh_not_gated()
	_finish()


# ── ③ TeamHud 的 `_my_team` 契约(语义面)─────────────────────────────
# ★ 为什么必须有这一段:上面那一组守的是**结构**(tscn 里有没有那些子节点),语义一个都照不到。
#   `ui/team_hud.gd` 判"我方胜负"读的是**外部写进来的** `_my_team`(**不是** `PvpSession.role` ——
#   3v3 的 role 号由大厅「最小空闲号」分配,可与队号错开),而全项目**唯一**的写入方是
#   `scenes/team_game.gd` 的 `_apply_teams`(它写在 `match_sync` 到达之后)。
# ★ 漏写那条接线的后果**不报错**:`_my_team` 恒 0 ⇒ `mwinner == _my_team and _my_team != 0`
#   恒假 ⇒ 「本局胜利!」/「胜利!」**两条文案一次都不会出现**,赢的局一律报成
#   「本局落败」/「失败」。(平局那一支**不受影响** —— 它走 `else`,别把契约写成"平局不可达"。)
# ★ 判据必须**依赖** `_my_team`,且必须配**反向对照**:喂同样的载荷但**不写入** `_my_team`,
#   断言"不得念胜利"。没有反向对照的话,一条恒真的断言(比如"大字里有字")也能绿。
# ★ 别拿 `ST_ROUND_OVER` 的 `winner == 0` 那一支来试:它在 3v3 **不可达**
#   (`TeamHost._broadcast_round_state` 只在 `_last_round_winner != 0` 时才下发 `winner`)
#   ⇒ 拿它做断言会得到一条**恒绿的空断言**。
#   生产那一半(team_game 到底调没调)另有源码级断言:`tests/team_room_smoke.gd` 的 ⑨。
#   两半缺一不可:只钉 HUD 这一半,`team_game` 永不调用照样全绿。
const TEAM_HUD_SCENE := "res://ui/team_hud.tscn"   # PAIRS 里那个路径的**用法**在这里,不是重复定义

func _check_team_my_team_contract() -> void:
	var before := _failures.size()
	_check(ResourceLoader.exists(TEAM_HUD_SCENE), "%s 不存在(_my_team 契约无从成立)" % TEAM_HUD_SCENE)
	if not ResourceLoader.exists(TEAM_HUD_SCENE):
		_summary(before, "TeamHud:场景缺失,跳过")
		return
	# 载荷:ROUND_OVER 的 `winner` 支 + MATCH_OVER 的 `match_winner` 支,两条**都**依赖 `_my_team`
	var round_win := {"state": 2, "round": 1, "scores": {1: 9, 2: 3}, "rounds_won": {}, "winner": 1}
	var match_win := {"state": 3, "round": 3, "scores": {1: 12, 2: 11}, "rounds_won": {1: 2}, "match_winner": 1}

	var with_team: TeamHud = (load(TEAM_HUD_SCENE) as PackedScene).instantiate() as TeamHud
	add_child(with_team)
	with_team.set_my_team(1)   # = `team_game._apply_teams` 那一步
	with_team._on_round_state(round_win)
	_check(with_team._big.text == "本局胜利!",
			"TeamHud(set_my_team(1)) 收到 winner=1 应念「本局胜利!」(实得「%s」)" % with_team._big.text)
	with_team._on_round_state(match_win)
	_check(with_team._big.text == "胜利!",
			"TeamHud(set_my_team(1)) 收到 match_winner=1 应念「胜利!」(实得「%s」)" % with_team._big.text)

	# 反向对照:**同一份载荷**、但从不写入 `_my_team`(默认 0)—— 上面两条若不依赖它就恒真
	var no_team: TeamHud = (load(TEAM_HUD_SCENE) as PackedScene).instantiate() as TeamHud
	add_child(no_team)
	no_team._on_round_state(round_win)
	_check(not no_team._big.text.contains("胜利"),
			"反向对照:未写入 _my_team 时 winner=1 不得念「胜利」(实得「%s」)—— 它绿着上面那条就恒真" % no_team._big.text)
	no_team._on_round_state(match_win)
	_check(not no_team._big.text.contains("胜利"),
			"反向对照:未写入 _my_team 时 match_winner=1 不得念「胜利」(实得「%s」)" % no_team._big.text)

	with_team.queue_free()
	no_team.queue_free()
	_summary(before, "TeamHud 的 _my_team 契约:写入队号才念得出「本局胜利!/胜利!」;不写入时两条都不出现")


# ── ④ 结算页必须从 `.tscn` 实例化:`res://scenes/` 下零 `MatchResult.new(` ──────
# ★★ 为什么住在**这里**,以及为什么**这两处写法都不能"化简"**(2026-09-21 评审后从
#    `tests/match_result_probe.gd` 整段搬来 —— 那边是**放错了地方**,理由见 ①②):
#
#   ① **扫描面必须在「接线真正落地的地方」**。结算页的挂载点在**基类**
#      `scenes/pvp_match_client.gd`:三个客户端(`pvp_game`/`royale_game`/`team_game`)
#      全部 `extends PvpMatchClient`,接线(`const RESULT_SCENE := preload(...)` +
#      `_result = RESULT_SCENE.instantiate()`)加在那**一个**文件里。
#      此前那份判据用的是**手写**的三文件清单(恰好是三个子类)⇒ 缺陷真正会出现的那一行
#      **一处都扫不到**,而探针照样全绿。手写清单正是它当初出错的成因,所以这里**走盘**。
#   ② **判据必须剥注释**(`_code_only`)。基类里那句注释原文就写着
#      「必须走场景实例化,不能用 `MatchResult.new()`」—— 裸 `contains` 会把这条
#      **完全正确**的代码判成红的(comment-blind 的假红)。
#   ③ 这条是**源码级**规则,不该住在需要真渲染的窗口探针里:那种探针**只在有人开窗口时**
#      才跑,而本文件是 headless、已在例行扫描轮转里,且已经拥有「零 `<类>.new(`」这个概念
#      —— ①②两条 `.new(` 守卫就在上面几步之外。
#   ⚠ 别把它"简化"回「裸 contains + 固定路径清单」:①②两条会**同时**回来,而且都是静默的
#      (假红要人去查、漏扫要等缺陷上线)。
const RESULT_SCAN_ROOT := "res://scenes"      # 目录,不是文件清单(理由见上 ①)
const RESULT_FORBIDDEN := "MatchResult.new("  # `.new()` 建出来的是 layer 1(理由见文件头 ④)


func _check_result_scene_instantiation() -> void:
	var before := _failures.size()
	var all := _collect([RESULT_SCAN_ROOT])
	var files: Array[String] = []
	for p in all:
		if str(p).ends_with(".gd"):
			files.append(p)
	# ★ 下限守卫:走盘走空(目录改名/被排除)时下面那条 `for` 一次都不转 ⇒ 恒绿。
	_check(files.size() >= 1,
			"%s 下扫到 0 个 .gd(判据退化:走盘走空 ⇒ 「零 MatchResult.new(」恒真)" % RESULT_SCAN_ROOT)
	var hits: Array[String] = []
	var unreadable: Array[String] = []
	for p in files:
		var code := _code_only(_read(p))
		if code.is_empty():
			unreadable.append(p)
			continue
		if code.contains(RESULT_FORBIDDEN):
			hits.append(p)
	# ★ 读不到源文件 = 这类探针最典型的失明方式(contains 恒假),必须单独报红。
	_check(unreadable.is_empty(), "读不到这些源文件(contains 断言在它们身上恒假):%s" % ", ".join(unreadable))
	_check(hits.is_empty(),
			"这些文件用了 MatchResult.new():%s —— layer = 150 只写在 ui/match_result.tscn 里,用 .new() 会落到 CanvasLayer 默认的 layer 1,结算页画在 HUD(130)/小地图(131)下面且压暗罩盖不住(静默,只能靠眼睛看出来)。要从场景实例化。" % ", ".join(hits))
	_summary(before, "结算页实例化:扫 %s 下 %d 个 .gd,零 MatchResult.new( (已剥注释)" % [
			RESULT_SCAN_ROOT, files.size()])


# ── ⑤ `_show_result()` 不得早退(结算页"挂载一次、每次都刷新")──────────────
# ★ 守的是什么:`scenes/pvp_match_client.gd` 的 `_show_result()` 正确形状是
#     `if _result == null:` **只包住「建 + 连线」**,而 `_result.show_result(...)` 在 if **之外**。
#   恢复 `if _result != null: return` 会把"挂载幂等"顺手变成"**更新也只一次**":
#     第二条 MATCH_OVER 载荷**永远到不了屏幕上**,结算页留着一份过期数据,而
#     `MatchResult.show_result` 的清场重建(`ui/match_result.gd` 的 remove_child→queue_free
#     那段)**在生产里一次都不会跑**。这个缺陷 2026-09-21 修过,但当时唯一的守卫是**一次性**
#   探针(跑完已删)⇒ 谁把它改回去,今天没有任何探针会红。
#   `tests/match_result_probe.gd` 抓不到:**它直接调 `MatchResult.show_result`**,
#   从不经过生产入口 `_show_result()` —— 于是"探针比产品更绿"。
# ★★ **判据必须剥注释(`_code_only`),这是本检查唯一的实现难点**:正确实现自己的注释里
#    (该文件 `_show_result()` 上方那段,原文写着「写成 `if _result != null: return` 会…」)
#    **就含这行字面量** ⇒ 裸 `contains` 会把**完全正确**的代码判成红的(comment-blind 的假红,
#   与上面 ④ 里 `MatchResult.new()` 那条是同一个坑)。剥注释后:正确文件里该串**只出现在
#   注释里** ⇒ 绿;一旦真写成早退 ⇒ 落到代码里 ⇒ 红。★ 别"化简"成裸 contains。
# ★ 反向断言(`show_result(` 必须在)同样不能省:没有它的话,**把整个 `_show_result()` 删掉**
#   会让上面那条早退断言恒真(空文件当然"不含 `_result != null`")—— 那是假绿不是修复。
const RESULT_HOST := "res://scenes/pvp_match_client.gd"
const RESULT_STALE_GATE := "_result != null"   # 早退闸门的形状(`if _result != null: return`)
const RESULT_REFRESH_CALL := "show_result("    # 刷新调用:`_result.show_result(payload)`


func _check_result_refresh_not_gated() -> void:
	var before := _failures.size()
	var code := _code_only(_read(RESULT_HOST))
	# ★ 读不到源文件 = 这类探针最典型的失明方式(两条 contains 一真一假都无意义),必须单独报红。
	_check(not code.is_empty(), "读不到 %s(下面两条 contains 断言在它身上都无意义)" % RESULT_HOST)
	if code.is_empty():
		_summary(before, "%s:读文件失败,跳过" % RESULT_HOST)
		return
	# 先钉"刷新调用还在":否则删掉整个函数(= 结算页根本不挂)也能让下面那条绿 —— 判据退化。
	_check(code.contains(RESULT_REFRESH_CALL),
			"%s 的代码里找不到 `%s`(判据退化:`_show_result()` 被删/改名时,下面那条早退断言恒真)" % [
					RESULT_HOST, RESULT_REFRESH_CALL])
	_check(not code.contains(RESULT_STALE_GATE),
			"%s 的**代码**里出现 `%s` —— 这是恢复了「`if _result != null: return`」那种早退:第二条 MATCH_OVER 载荷(1v1 重连重播 / 3v3 收场后再广播)会被**静默丢掉**,而 MatchResult.show_result 的清场重建在生产里一次都不跑。正确形状是 `if _result == null:` 只包住「建 + 连线」,刷新调用在 if 之外。" % [
					RESULT_HOST, RESULT_STALE_GATE])
	_summary(before, "结算页刷新:%s 无早退闸门、%s 仍在(已剥注释)" % [RESULT_HOST, RESULT_REFRESH_CALL])


# 该 .tscn 除根节点外还声明了节点吗?(决定 ② 是否适用 —— 理由见文件头。)
# 数 `[node ` 出现次数:>1 ⇔ 除根之外还有节点。(逐行判 begins_with 而不是整串 contains,
# 是因为 `[node name="X"` 一定顶格;`contains` 会把注释里引用的示例也算进来。)
func _scene_declares_nodes(tscn: String) -> bool:
	var n := 0
	for line in tscn.split("\n"):
		if line.begins_with("[node "):
			n += 1
	return n > 1


func _check_pair(script_path: String, tscn_path: String, cls: String) -> void:
	var before := _failures.size()
	var exists := ResourceLoader.exists(tscn_path)
	_check(exists, "%s 不存在(%s 声称自己走声明式场景,却没有配套 tscn)" % [tscn_path, script_path])
	if not exists:
		_summary(before, "%s:场景缺失,跳过" % script_path)
		return
	var code := _code_only(_read(script_path))
	var tscn := _read(tscn_path)
	_check(not code.is_empty(), "读不到 %s" % script_path)
	if code.is_empty() or tscn.is_empty():
		_summary(before, "%s:读文件失败" % script_path)
		return

	# ① 全文不得出现 <类>.new(
	var re_new := RegEx.new()
	re_new.compile("\\b" + cls + "\\.new\\(")
	var hits := re_new.search_all(code)
	_check(hits.is_empty(),
			"%s 里出现 %s.new( 共 %d 处(声明式脚本不能用 .new():建出来的节点没有子节点,_ready 解引用必崩)" % [
					script_path, cls, hits.size()])

	# ② @onready $路径 的叶子名必须在 tscn 里声明
	var re := RegEx.new()
	re.compile(RE_ONREADY)
	var paths := re.search_all(code)
	# ★ ② 只在「tscn 声明了子节点」的前提下适用(理由见文件头那条)。
	var declares_nodes := _scene_declares_nodes(tscn)
	_check(not declares_nodes or paths.size() >= 1,
			"%s 的 tscn 声明了子节点,但 @onready $子节点解析出 0 个(判据退化成恒绿:一个 $路径都没有)" % script_path)
	var missing: Array[String] = []
	for m in paths:
		var leaf: String = (m.get_string(2) as String).split("/")[-1]
		if not tscn.contains("[node name=\"" + leaf + "\""):
			missing.append(leaf)
	_check(missing.is_empty(),
			"%s 的 @onready 子节点 %s 在 %s 里没有声明(契约破了 → 运行期解引用 null)" % [
					script_path, ", ".join(missing), tscn_path])
	_summary(before, "%s ↔ %s:%d 个 @onready 子节点全声明、零 %s.new(" % [
			script_path, tscn_path, paths.size(), cls])
