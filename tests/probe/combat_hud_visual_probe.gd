extends Control

# 对局内 HUD(PvpHud / RoyaleHud / TeamHud)视觉验收探针(必须带真实渲染,不能加 --headless)。
#   - 配置充足的超时保护帧数(3600 帧):探针正常跑完会自己 quit(),这个值只在探针阻塞挂起时才用得上 ——
#     适当放宽超时保护可避免环境负载波动引发误报。原先的 600/900 在机器负载重时可能先耗尽、探针来不及跑完
#     就被意外中断(表现为"一行 ALL-OK 都没有",看着像功能坏了)。
# 运行方式：
#   "$GODOT" --path . --quit-after 3600 res://tests/probe/combat_hud_visual_probe.tscn
# 把两块对局 HUD 的关键状态定格成 PNG 交给控制者读图,同时打数值断言:
#   _hud_1_pvp_playing.png  1v1 记分条 + 延迟(PLAYING)
#   _hud_2_pvp_broadcast.png 1v1 中央广播(倒计时巨字)
#   _hud_3_royale_board.png 大乱斗排行榜(4 行:自己/他人/复活中/离开)
#   _hud_4_royale_over.png  大乱斗终局广播
#   _hud_5_team_playing.png 3v3 记分条(scores/rounds_won 的键是队号,不是 role)
#   _hud_6_team_tie.png     3v3 终局平局广播(match_winner == 0 —— 3v3 特有的可达值)
#   _hud_7_pvp_grace.png    1v1「对手掉线中,等待重连… 剩余 42s」(阶段 3 的 3.1)
#   _hud_8_royale_grace.png 大乱斗排行榜的「掉线 42s」那一行(阶段 3 的 3.1)
# PNG 落 res://.superpowers/sdd/(该目录自带 .gitignore = *,不入库)。
#
# - 背景故意铺地图开阔区的浅灰蓝(#78969F),不是深色底:
#   对局 HUD 是直接叠在地图上的,垫深底取图会把「浅底上读不出来」这类问题整个遮掉 ——
#   单机 HUD 就是这么漏掉 1.9:1 的生命条的(见 ui/ui_factory.gd 的 C_PLATE 注释)。
const MAP_OPEN_COLOR := Color(0.47, 0.588, 0.624)   # ≈#78969F,实测取的地图开阔区色

const OUT_DIR := "res://.superpowers/sdd"
const PVP_HUD_SCENE := "res://ui/hud/pvp_hud.tscn"
const ROYALE_HUD_SCENE := "res://ui/hud/royale_hud.tscn"
const TEAM_HUD_SCENE := "res://ui/hud/team_hud.tscn"

var _failures: Array[String] = []

# 断言断言计数门禁(2026-10-04,R41 —— 与 `kh_l3_visual_probe` 相同处理逻辑)。
# - 为什么必须有:`ALL-OK` 只证明没有任何断言失败,不证明每条断言都跑过 —— 脚本错误只结束
#   出错的那个函数、调用方继续  ->  后面的断言静默跳过,而 verdict 照打 `ALL-OK`。
#   本文件整段断言都在同一个函数(`_run_round`)里,而且它里面充满了无防御性校验的属性访问
#   (`pvp._big` / `pvp._mask` / `royale._rows` …)—— 任何一个被改名或搬走,`_run_round` 都会中途抛错,
#   于是它之后的全部断言(含本轮新加的两条几何断言)一起静默失效。这正是 R19 那条测试漏报的相同处理逻辑。
const EXPECTED_CHECKS := 22
# - 22 是逐个数出来的,不是估的(全部 18 处 `_check(` 调用点都在 `_run_round()` 里):
#   - 函数体顶层 15 处(记分条 / 大字 / 外框 / 标题带 / 遮罩 / 掉线 / 掉线像素差 / 掉线位置 /
#     榜行数 / 终局大字 / 掉线行文案 / 态8 像素差 / 3v3 记分条 / 3v3 大字 / 平局文案);
#   - `if royale._rows.size() == 4:` 里 1 处(榜首行文本)—— 执行通过的那条路上成立;
#   - `if grace_row != null:` 里 1 处(掉线行没被 clip_text 裁)—— 同上;
#   - `for pair in [ … 5 组 … ]` 里 1 处  ->  跑 5 次(态 1 -> 2 / 2 -> 3 / 3 -> 4 / 4 -> 5 / 5 -> 6)。
#   15 + 1 + 1 + 5 = 22。
#   - 那两个条件分支:条件不成立时既红那条断言、又少一条计数  ->  两条信号,不是漏报。
#   - `_shot()` 里的两处失败是直接 `_failures.append`(截图失败/写盘失败),不经过 `_check`
#      ->  不计入 22,与 `kh_l3_visual_probe` 同一口径。
#   - 用 `!=` 而不是 `<`:新增断言忘了登记同样要红(`tests/probe/late_match_probe.gd` 相同处理逻辑)。
var _checks := 0

# 态2 广播面板的两条布局尺寸(见 `_run_round` 里那段 R18 注释)。
# 注意事项：量具(这一条比数字本身重要):`Control.size`,即布局尺寸。
#    不要用 `get_global_rect().size` 做判定条件 —— 它把父级缩放算进去,而本面板每次弹出都会走
#    `_apply_punch()` 把 `_panel.scale` 抬到 1.06 再逐帧衰减(`broadcast.gd` 的 PUNCH_SCALE/PUNCH_DECAY)
#     ->  脉冲相位是运行时状态:同一块面板在弹出后第 N 帧与第 M 帧量出来不等,而每一轮的倍率都不同
#    (实测样本:1.029455 / 1.028278 / 1.030635 / 1.028797 / 1.029709 / 1.030077 / …);
#    同一份代码的 `size` 则每一轮都逐位相同。
#    (R18 账本原先那组 865×387 / 720×201 就是用 `get_global_rect()` 量的  ->  绝对值被脉冲污染;
#     R36 已判定结果:按本探针的实测值订正,结论"菜单尺度漏进 HUD"不变。)
# 注意事项：约束的是 `671e610` 之后被接受的值,不是它之前的值(那一提交把 `header_strip()` 的内边距
#    28/14 -> 40/20,本面板复用它  ->  被连带改大;R18 判定结果接受这档漂移,故钉新值)。
# - 这是本探针实测的值(1920×1440 视口、真实渲染),不是照抄任何二手数字:
#   - 外框 `_panel.size` = 866×371;标题带 `strip.size` = 720×185;
#   - 宽度那一维与旧记录的两种量法互相印证:标题带 696 -> 720 = +24、外框 841 -> 865/866 = +24/+25,
#     正好是内边距左右各 +12 的两倍  ->  "菜单尺度经 `header_strip()` 漏进对局内 HUD"这个结论不变;
#     差的只有高度那一维(那一维在 rect 量法里还叠着 `_punch` 缩放,见上)。
#   - 算式自洽:Label `get_height(144)` = 145,标题带 = 145 + 内容边距 40(20+20)= 185 ✓;
#     外框 = 标题带 + 186(Box 间距 24 + 副文案 + `menu_panel(72,44)` 的双边距 88 + 内外各 1px 线)。
#   - 与旧记录的高度差 +16 整条落在标题带的内容高上(旧记录隐含 Label 高 161;而
#     `BIG_FONT` 自 `5e0e025` 起就是 144,`PixelFont`/`style_control`/`header_strip` 自 `671e610`
#     起逐字未改  ->  那个 161 复现不出)。差异原文见 T3b 报告 §2。
const BROADCAST_OUTER_W := 866.0
const BROADCAST_OUTER_H := 371.0
const BROADCAST_STRIP_W := 720.0
const BROADCAST_STRIP_H := 185.0


func _ready() -> void:
	Level0.pvp_mode = false   # 对局 HUD 与单机 HUD 会同时在场,量的是对局 HUD 自己的元素
	await _run_round()
	_finish()


func _run_round() -> void:
	# 地图色底:整个视口铺满,两块 HUD 都叠在它上面
	var bg := ColorRect.new()
	bg.color = MAP_OPEN_COLOR
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# 两块 HUD 分别在场:它们都常驻同一屏(1v1 与 大乱斗 各一套),但取图必须分开 ——
	# 否则 PvP 的中央倒计时广播会串进大乱斗那张,读图时无法判断哪条属于哪套。
	var pvp: CanvasLayer = (load(PVP_HUD_SCENE) as PackedScene).instantiate()
	add_child(pvp)
	# - 声明式场景实例化,不能 RoyaleHud.new():.new() 建出来的节点没有子节点,
	#   HUD 的 @onready 全是 null、_ready 解引用必崩(B11)。
	var royale: RoyaleHud = (load(ROYALE_HUD_SCENE) as PackedScene).instantiate() as RoyaleHud
	add_child(royale)
	royale.visible = false
	# 3v3 那一套同样先建后藏:它 _ready 就会弹出「对战开始」广播,不藏会串进态1~4 的取图
	# (那 4 张是既有基线,本探针加 TeamHud 时必须逐字不变)。
	var team: TeamHud = (load(TEAM_HUD_SCENE) as PackedScene).instantiate() as TeamHud
	add_child(team)
	team.visible = false
	await _frames(3)

	# ── 态1:1v1 PLAYING ──
	pvp._on_round_state({"state": 1, "round": 2, "scores": {1: 3, 2: 5},
			"rounds_won": {1: 1, 2: 0}, "timer": 0.0})
	pvp._on_ping(72)
	await _frames(2)
	var img1 := await _shot("_hud_1_pvp_playing.png")
	_check(_bright_in(img1, pvp._score_label) > 0, "态1:1v1 记分条画出了文本")
	print("[HUD-VISUAL] 态1 记分条 = 「%s」" % pvp._score_label.text)

	# ── 态2:1v1 中央广播(倒计时)──
	pvp._on_round_state({"state": 0, "round": 2, "scores": {1: 3, 2: 5},
			"rounds_won": {1: 1, 2: 0}, "timer": 3.0})
	await _frames(2)
	var img2 := await _shot("_hud_2_pvp_broadcast.png")
	_check(_bright_in(img2, pvp._big) > 0, "态2:中央大字画出来了")
	# 大字那条 Label 的字体度量(解释标题带高度从哪来;也只是印出来,不做断言)。
	var big_f: Font = pvp._big.get_theme_font("font")
	var big_fs: int = pvp._big.get_theme_font_size("font_size")
	print("[HUD-VISUAL] 态2 大字度量:font_size=%d get_height=%s label.size=%s"
			% [big_fs, "<无字体>" if big_f == null else str(big_f.get_height(big_fs)),
			str(pvp._big.size)])
	# ── 态2 的显式几何断言(R18:把漂移严格校验,别让它继续无防御性校验) ──
	# 注意事项：约束的是 `671e610`("全局尺度再提一档")之后被接受的值,不是它之前的值:
	#    那一提交把 `UiFactory.header_strip()` 的内容边距 28/14 -> 40/20,而本面板复用它
	#    (见 `broadcast.gd` 文件头那条"刻意的菜单语汇例外"登记)—— 这就是"改菜单尺度会连带改
	#    对局内 HUD"那条耦合。R18 的判定结果是接受并固定绑定当前的值(把 HUD 改回去等于再动一次
	#    HUD 像素) ->  这里约束的是本探针实测的那组数,不是任何二手数字(见下面的常量注释)。
	# - 为什么非钉不可:三条 HUD 探针都不做基线比对  ->  这条耦合没有任何自动化防御性校验看得见
	#    (671e610 那次是靠人眼比图才发现的)。`broadcast.gd` 文件头登记的边界只写到"改这几个
	#    菜单 token(颜色)会连带",没写尺度 —— 本断言把尺度的那一半也钉上。
	# 注意事项：量的是布局尺寸(`Control.size`),不是 `get_global_rect().size`:广播每次弹出都会
	#    走 `_apply_punch()` 把 `_panel.scale` 抬到 1.06 再逐帧衰减(`broadcast.gd` 的
	#    PUNCH_SCALE/PUNCH_DECAY),而 `get_global_rect()` 把父级缩放算了进去  ->  同一块面板
	#    在弹出后第 N 帧与第 M 帧量出来不等(本探针实测:rect 891.5×381.9 而布局 866×371,
	#    两处比值同为 ×1.029455  ->  差异整个来自脉冲相位)。判定条件要约束的是版式,不是脉冲相位。
	# - 量具 = `Control.size`(R36 已裁):账本原先那组 865×387 / 720×201 是用 `get_global_rect()`
	#   量的  ->  绝对值被脉冲污染,已按本探针的实测值订正;两处宽度互印的 +24/+25 说明
	#   "菜单尺度漏进 HUD"那个结论没变。
	# - 尺寸比的是逻辑单位(视口 1920×1440),不是截图里的像素数:截图尺寸随窗口缩放变。
	# 注意事项：节点在不在先判(R41):`pvp._broadcast` / 它的 `_panel` 都是无防御性校验的属性访问 ——
	#    被改名/搬走时会直接抛错,`_run_round` 在那一行断掉,于是它之后的全部断言(含下面
	#    这两条)静默跳过而 verdict 照打 —— R19 那条测试漏报的相同处理逻辑。故这两跳都走 `get()` 显式取,
	#    取不到就给 null(下面的断言会红,而不是整个函数断在半路)。
	#    - `pvp._big`(`:103` 与本行)是既有的同类暴露(R41 评审:可以留,不是本 diff 的面);
	#      它现在也跑不掉了 —— 真出了事,下面那道 `_checks != EXPECTED_CHECKS` 会红。
	# - 另一层理由：未获取到节点时 `.size` 返回 0×0，直接与 0 比较会将“路径错误或节点迁移”
	#    误判为“尺寸偏移”，导致错误诊断信息误导排查；优先判定 null 才能提供精准的失败断言信息。
	var bcast = pvp.get("_broadcast")
	var panel: Control = null if bcast == null else bcast.get("_panel") as Control
	var strip: Control = pvp._big.get_parent() as Control
	print("[HUD-VISUAL] 态2 广播外框 size = %s rect = %s;标题带 size = %s rect = %s;panel.scale = %s"
			% ["<无节点>" if panel == null else str(panel.size),
			"<无节点>" if panel == null else str(panel.get_global_rect()),
			"<无节点>" if strip == null else str(strip.size),
			"<无节点>" if strip == null else str(strip.get_global_rect()),
			"<无节点>" if panel == null else str(panel.scale)])
	_check(panel != null and panel.size.is_equal_approx(
			Vector2(BROADCAST_OUTER_W, BROADCAST_OUTER_H)),
			"态2:广播**外框**布局尺寸 = %d×%d(实得 %s;671e610 之后被接受的值)"
			% [BROADCAST_OUTER_W, BROADCAST_OUTER_H,
			"无节点" if panel == null else str(panel.size)])
	_check(strip != null and strip.size.is_equal_approx(
			Vector2(BROADCAST_STRIP_W, BROADCAST_STRIP_H)),
			"态2:广播**标题带**布局尺寸 = %d×%d(实得 %s;菜单尺度一改它就跟着变)"
			% [BROADCAST_STRIP_W, BROADCAST_STRIP_H,
			"无节点" if strip == null else str(strip.size)])
	_check(pvp._mask.visible, "态2:广播遮罩可见")

	# ── 态7:1v1「对手掉线中」(阶段 3 的 3.1)──
	# `grace` 的键是对手的 role(1v1 恒为 `3 - 自己`);缺键 = 此刻没人掉线。
	# - 与态1 同一个 PLAYING 态、同一份比分,唯一差别就是这一条 —— 故 `_diff(img1, img7)`
	#   量到的差异只可能来自它(取图前 1v1 是可见的、大乱斗那两套都藏着,与态1 一致)。
	pvp._on_round_state({"state": 1, "round": 2, "scores": {1: 3, 2: 5},
			"rounds_won": {1: 1, 2: 0}, "grace": {3 - PvpSession.role: 42.0}})
	await _frames(2)
	var img7 := await _shot("_hud_7_pvp_grace.png")
	_check(pvp._grace_wrap.visible and pvp._grace_label.text.contains("42"),
			"态7:1v1 的「对手掉线中」画出来了(role %d / 「%s」)"
			% [3 - PvpSession.role, pvp._grace_label.text])
	print("[HUD-VISUAL] 态7 掉线条 = 「%s」 rect=%s(记分条 rect=%s)"
			% [pvp._grace_label.text, str(pvp._grace_wrap.get_global_rect()),
			str(pvp.get_node("ScoreWrap").get_global_rect())])
	var d17 := _diff(img1, img7)
	_check(d17 > 500, "态7:相对态1(同态、无 grace)的像素差异 = %d(应当只来自这一条)" % d17)
	_check(pvp._grace_wrap.get_global_rect().position.y
			>= pvp.get_node("ScoreWrap").get_global_rect().end.y,
			"态7:掉线条必须落在记分条**之下**、不与它重叠")

	# ── 态3:大乱斗排行榜 ──
	pvp.visible = false    # 收起 1v1(含它的中央广播),只留大乱斗这一套
	royale.visible = true
	# names 键是 int role —— 与生产端逐字一致:`server/royale_host.gd` 的 `_broadcast_round_state`
	# 就是 `names[int(role)] = …`(整数值键)。消费端 `_refresh_board` 走 `for role_s in names`
	# + `int(role_s)`,两种键都吃得下,故写错也照样跑、看不出区别 —— 唯二的判定条件就是这里的
	# 夹具与那句注释,两者必须同口径(2026-09-29 修订说明:本行此前写"协议里就是字符串键",
	# 与下面态8 的 int 夹具自相矛盾,且与生产端不符)。
	royale._on_round_state({
		"state": 1, "timer": 187.0,
		"names": {"1": "Anon", "2": "一个很长很长的昵称", "3": "Bob", "4": "Carol"},
		"scores": {1: 7, 2: 5, 3: 5, 4: 0},
		"deaths": {1: 2, 2: 4, 3: 1, 4: 3},
		"alive": {1: true, 2: false, 3: true, 4: true},
		"left": [4],
	})
	await _frames(2)
	var img3 := await _shot("_hud_3_royale_board.png")
	_check(royale._rows.size() == 4, "态3:排行榜行数 = %d(期望 4)" % royale._rows.size())
	if royale._rows.size() == 4:
		_check(_bright_in(img3, royale._rows[0]) > 0, "态3:排行榜首行画出了文本")
		print("[HUD-VISUAL] 态3 首行 = 「%s」" % royale._rows[0].text)
		print("[HUD-VISUAL] 态3 底板 = %s" % str(royale._board_bg.get_rect()))

	# ── 态4:大乱斗终局广播 ──
	royale._on_round_state({
		"state": 3, "timer": 0.0, "match_winner": 1,
		"names": {"1": "Anon", "2": "一个很长很长的昵称"},
		"scores": {1: 9, 2: 5}, "deaths": {1: 2, 2: 4},
		"alive": {1: true, 2: true}, "left": [],
	})
	await _frames(2)
	var img4 := await _shot("_hud_4_royale_over.png")
	_check(_bright_in(img4, royale._big) > 0, "态4:终局大字画出来了")

	# ── 态8:大乱斗排行榜的「掉线 42s」(阶段 3 的 3.1)──
	# role 2 掉线中(grace 表里有它),而它照旧 `alive = false` —— **同一个载荷去掉 `grace`
	# 那一行会念「复活中」**,故本阶段同时是"grace 档压过 alive 档"的鉴别器。
	# - `grace` 缺键 = 此刻没人掉线(服务端空表不带键),故上面态3 那几次载荷不改也合法。
	royale._on_round_state({"state": 1, "round": 1, "scores": {1: 7, 2: 3, 3: 1},
			"deaths": {1: 0, 2: 1, 3: 2}, "rounds_won": {}, "timer": 214.0,
			"names": {1: "阿甲", 2: "bob", 3: "电脑玩家3-computer"},
			"alive": {1: true, 2: false, 3: true}, "left": [], "grace": {2: 42.0}})
	await _frames(2)
	var img8 := await _shot("_hud_8_royale_grace.png")
	var grace_row: Label = null
	for r in royale._rows:
		if r.text.contains("掉线"):
			grace_row = r
	_check(grace_row != null and grace_row.text.contains("掉线 42s"),
			"态8:排行榜里掉线那行念「掉线 42s」;实得「%s」"
			% ("(没有任何一行带「掉线」)" if grace_row == null else grace_row.text))
	if grace_row != null:
		# - 末段真的没被裁:`clip_text = true` 是静默裁的(不报错,`row.text` 也照旧是
		#   完整的那一句  ->  只判 `contains` 是看不出裁没裁的),故只能量文本宽与裁剪界比。
		#   裁剪界就是 `_refresh_board` 建行时钉的那个 `BOARD_W - 8`(= 712)。
		var gf: Font = grace_row.get_theme_font("font")
		var tw: float = gf.get_string_size(grace_row.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
				grace_row.get_theme_font_size("font_size")).x
		var clip_w: float = RoyaleHud.BOARD_W - 8.0
		_check(tw <= clip_w,
				"态8:掉线那行没被 clip_text 裁掉(文本宽 %0.1f ≤ 裁剪界 %0.1f)" % [tw, clip_w])
		print("[HUD-VISUAL] 态8 掉线行 = 「%s」 文本宽=%0.1f 裁剪界=%0.1f 行宽=%0.1f"
				% [grace_row.text, tw, clip_w, grace_row.size.x])
	# 注意事项：登记(2026-09-29 复核,留而不改):下一条比的是态8 vs 态4,而两者是**两个不同的
	#   屏幕状态**(态4 = 终局广播 + 2 行板,态8 = 进行中 + 3 行板 + 掉线行)—— 那个像素差里
	#   真正来自"掉线行"的只是一小部分,校验区分度较弱:把「掉线 42s」换成「复活中」它照样绿
	#   (行数/广播/计时那几处差异已经远超 500)。真正具有有效校验能力的是上面那条念「掉线 42s」的断言,
	#   以及态7 那条同态对照(态7 vs 态1:同一个屏,只多一条掉线行 —— 那才是"这一档画出来了"
	#   的像素判定条件)。
	#    ->  保留它只是当一条粗略的"该测试阶段确实画出了东西"的兜底保护(全黑/全空的屏会红),
	#     别把它读成"掉线那一档被像素验证过了"。要真验,得补一张"同态、只去掉 `grace` 键"
	#     的对照图(与态7 相同处理逻辑),本批不做。
	var d48 := _diff(img4, img8)
	_check(d48 > 500, "态8:相对态4(终局广播)的像素差异 = %d(★ 弱鉴别力,见上方登记)" % d48)

	# ── 态5:3v3 记分条(scores/rounds_won 的键是队号)──
	royale.visible = false   # 收起大乱斗那一套(含它的终局广播),只留 3v3 这套
	team.visible = true
	team.set_my_team(1)      # 外部在 match_sync 到达后写入;两队的文案都按它判"我方/对方"
	team._on_round_state({"state": 1, "round": 2, "scores": {1: 4, 2: 6},
			"rounds_won": {1: 1, 2: 0}, "timer": 0.0})
	team._on_ping(48)
	await _frames(2)
	var img5 := await _shot("_hud_5_team_playing.png")
	_check(_bright_in(img5, team._score_label) > 0, "态5:3v3 记分条画出了文本")
	print("[HUD-VISUAL] 态5 记分条 = 「%s」" % team._score_label.text)

	# ── 态6:3v3 终局平局(match_winner == 0)──
	# - 0 在 3v3 是新可达值(两队都走光),而 pvp_hud 对 0 用的是 1v1 口径的兜底保护
	#   (`"P%d 获胜!" % (1 if w1 > w2 else 2)`) ->  照抄会把平局念成「P2 获胜」。本阶段钉的就是文案。
	team._on_round_state({"state": 3, "round": 3, "scores": {1: 12, 2: 11},
			"rounds_won": {1: 1, 2: 1}, "match_winner": 0, "timer": 0.0})
	await _frames(2)
	var img6 := await _shot("_hud_6_team_tie.png")
	_check(_bright_in(img6, team._big) > 0, "态6:3v3 终局大字画出来了")
	_check(team._big.text.contains("平"), "态6:平局文案是「平 局」(照抄 1v1 的 P%d 兜底会把平局念成「P2 获胜」)")
	print("[HUD-VISUAL] 态6 终局大字 = 「%s」/ 副文案 = 「%s」" % [team._big.text, team._sub.text])

	# ── 各态两两不同(证明"切了状态"而不是"拍了六张一样的")──
	for pair in [[img1, img2, "1→2"], [img2, img3, "2→3"], [img3, img4, "3→4"],
			[img4, img5, "4→5"], [img5, img6, "5→6"]]:
		var d := _diff(pair[0], pair[1])
		_check(d > 500, "态%s 画面有差异(%d)" % [pair[2], d])
		print("[HUD-VISUAL] 态%s 像素差异 = %d" % [pair[2], d])

	bg.queue_free()
	pvp.queue_free()
	royale.queue_free()
	team.queue_free()
	await _frames(2)


# ── 截图与数值工具 ──
func _shot(png_name: String) -> Image:
	await _frames(2)
	var img := get_viewport().get_texture().get_image()
	if img == null or img.get_width() == 0:
		_failures.append("截图 %s 失败(是不是误加了 --headless?)" % png_name)
		return Image.new()
	var path := OUT_DIR.path_join(png_name)
	if img.save_png(path) != OK:
		_failures.append("截图 %s 写入失败(%s)" % [png_name, path])
	else:
		print("[HUD-VISUAL] 已存 %s  %dx%d" % [
				ProjectSettings.globalize_path(path), img.get_width(), img.get_height()])
	return img


func _frames(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


# 控件矩形内"比底板明显更亮"的像素计数 —— 证明文本真的画出来了,
# 而不是"底板自己就够亮"。
#
# 注意事项：为什么基准必须从图里量、不能用绝对阈值(2026-09-29,未认领欠账 A7):
#   旧实现是 `(r+g+b)/3 > 0.5`,而本探针的底板 = `C_PLATE`(黑 0.1)压在
#   `MAP_OPEN_COLOR`(#78969F)上,合成后三通道均值 = (0.47+0.588+0.624)×0.9/3 = 0.5047
#   —— 只比阈值高 0.0047。后果不是"判得松一点",而是判定条件整个无效操作:
#   只要控件矩形非空就恒 ≥1,六处 `_bright_in(...) > 0` 在"文本一个都没画出来"时照样全部断言通过。
#   反方向也脆:底板色/地图底色/取图口径任一微调,底板会被判成"亮文本"。
#   (大乱斗排行榜那块底更暗 —— `_board_bg` 是 0.25 的例外  ->  0.4205,同一族的另一个数。)
#  ->  基准改为从本矩形量:取像素亮度的 25 百分位当底板(文本只占矩形一小部分,
#   且像素字体笔画细、字形框内大片是底,故 25 百分位稳稳落在底板上;取百分位而不是最小值,
#   是为了不被边框/描边那类少数暗像素带跑),要求像素比它亮出 `BRIGHT_MARGIN`。
#
# 实测两个数(2026-09-29,按颜色算,不是取图 —— 本探针是真实视口渲染的,这一轮由用户跑图验收):
#   - 底板:记分条/大字的底(黑 0.1 压 #78969F)= 0.5047;大乱斗排行榜板底(黑 0.25)= 0.4205;
#   - 本探针点亮的最暗文本:排行榜首行的 `C_TEXT` = 0.9137;其余各处更高
#     (`_big` 的 0.95、`_score_label` 的主题默认 0.875、`C_GRACE` 0.7467、`C_ACCENT` 0.7007)。
#    ->  `BRIGHT_MARGIN = 0.10` 时门限落在 0.52~0.61:离底板 ≥0.10、离最暗被点亮文本 ≥0.09。
# - 已知边界:25 百分位当底板的前提是「文本的墨迹面积 < 矩形的 ~75%」。本探针量到的六个控件
#   全是这种形状(像素字体笔画细、字形框内大片是底),今天是安全的;若将来去量一个
#   墨迹占满的小控件,基准会落到文本上、门限随之抬高  ->  那条断言会测试误报(方向是红,
#   不是静默放行)。
const BRIGHT_MARGIN := 0.10


func _bright_in(img: Image, ctrl: Control) -> int:
	if img == null or img.get_width() == 0 or ctrl == null or not is_instance_valid(ctrl):
		return 0
	var s := Vector2(img.get_width(), img.get_height()) / get_viewport().get_visible_rect().size
	var r := ctrl.get_global_rect()
	var x0 := clampi(int(r.position.x * s.x), 0, img.get_width())
	var y0 := clampi(int(r.position.y * s.y), 0, img.get_height())
	var x1 := clampi(int((r.position.x + r.size.x) * s.x), 0, img.get_width())
	var y1 := clampi(int((r.position.y + r.size.y) * s.y), 0, img.get_height())
	return count_bright(img, Rect2i(x0, y0, x1 - x0, y1 - y0))


# 计数本体(纯函数:图 + 像素矩形进,整数出)。
# 注意事项：抽成 `static` 的唯一理由是可单独验证:本探针整体是真实视口渲染的(headless 下
#   `_shot` 直接 FAIL),故"这个阈值到底分不分得开底板与文本"这件事在 headless 里没有别的判定条件。
#   2026-09-29 的变异反证就是直接调它跑的(合成图:纯底板色  ->  0;底板 + 一个近白像素  ->  1;
#   同一张图交给旧阈值 0.5  ->  恒 ≥1,即无效操作)。
static func count_bright(img: Image, rect: Rect2i) -> int:
	if img == null or img.get_width() == 0:
		return 0
	var x0 := clampi(rect.position.x, 0, img.get_width())
	var y0 := clampi(rect.position.y, 0, img.get_height())
	var x1 := clampi(rect.position.x + rect.size.x, 0, img.get_width())
	var y1 := clampi(rect.position.y + rect.size.y, 0, img.get_height())
	var lums: Array[float] = []
	for y in range(y0, y1):
		for x in range(x0, x1):
			var c := img.get_pixel(x, y)
			lums.append((c.r + c.g + c.b) / 3.0)
	if lums.is_empty():
		return 0
	lums.sort()
	var base: float = lums[int(float(lums.size() - 1) * 0.25)]
	var thresh := base + BRIGHT_MARGIN
	var n := 0
	for l in lums:
		if l > thresh:
			n += 1
	return n


func _diff(a: Image, b: Image) -> int:
	if a.get_width() == 0 or b.get_width() == 0 or a.get_width() != b.get_width():
		return 0
	var n := 0
	for y in range(0, a.get_height(), 4):
		for x in range(0, a.get_width(), 4):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			if absf(ca.r - cb.r) > 0.05 or absf(ca.g - cb.g) > 0.05 or absf(ca.b - cb.b) > 0.05:
				n += 1
	return n


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if ok:
		print("[HUD-VISUAL] ✓ %s" % msg)
	else:
		_failures.append(msg)
		print("[HUD-VISUAL] ✗ %s" % msg)


func _finish() -> void:
	# - 断言计数门禁先于 verdict:跑少了 = 有断言被静默跳过(见文件头那条说明) ->  必须红,
	#   而不是照打 ALL-OK —— 那正是本文件里"无防御性校验属性访问  ->  中途抛错"那一族的形状。
	if _checks != EXPECTED_CHECKS:
		_failures.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上"
				% [_checks, EXPECTED_CHECKS]
				+ "(要么有断言被静默跳过 —— 脚本错误只结束出错的那个函数、调用方继续;"
				+ "要么新加的断言没登记进 EXPECTED_CHECKS)")
	if _failures.is_empty():
		print("COMBAT HUD VISUAL PROBE: ALL-OK(%d 条断言)" % _checks)
		get_tree().quit(0)
	else:
		print("COMBAT HUD VISUAL PROBE: FAIL")
		for f in _failures:
			print("  - %s" % f)
		get_tree().quit(1)
