extends ProbeBase

# 色相 shader / 1v1 双色 / 队色的**常驻守卫**(场景模式 + **真渲染**:
# headless 下 get_viewport().get_texture().get_image() 返回 null,量不到像素)。
# 跑法:
#   "$GODOT" --path . --quit-after 3600 res://tests/probe/hue_tint_probe.tscn
# 判据:grep 文本 `KH HUE-TINT PROBE: ALL-OK`(不看退出码;探针挂住时一行都不打印)。
#
# 存在理由(2026-09-19 用户裁定那一批 + 2026-09-20 的机制统一):
#   · `player_p2_hue.gdshader` 曾有 `COLOR = tex * COLOR` 的**重复乘纹理** bug —— 而当时
#     **全仓没有一个探针会因它复活而变红**(改回去一切照旧绿,只有人眼看图才发现)。
#     守卫 A 把"入参 COLOR 已含纹理"这条**语义**钉成像素级断言:shader 一旦退回 tex*COLOR、
#     或 Godot 改了 COLOR 的语义,它都会红。
#     ★ 2026-09-20 起这条守的是**个人色相**那条路(大乱斗的对手色 / 大乱斗+3v3 自己的自选色)——
#       1v1 的 P2 已改走 modulate 比值,**不再经过本 shader**;shader 本身仍在生产里,故守卫照旧。
#   · 1v1 的个人色相**整体停用**后,"P1 恒蓝 / P2 恒青"成了硬口径;守卫 B 从
#     **生产的 `_apply_p2_tint()`** → 渲染像素 → 队色 token 整条链钉住。
#     ★ 2026-09-20 起 P2 与 3v3 队 2 用的是**同一个 token、同一个机制**(比值法),不再是
#       "两个机制凑出近色";守卫 B 因此同时钉住三条:① role 1 不染本地那具(蓝)、
#       ② role 1 染对手副本(青)、③ role 2 染本地那具(青 == 队 2 token)。
#   · 守卫 D 钉 `C_TEAM_A == BODY_BASE_COLOR == player.png 众数`:改了本体主色却没改队色 ⇒
#     两队一起偏,但**仍分得出谁是谁**,所以最容易漏(team_room_smoke 登记过这条局限)。
#   · 守卫 C 是**反向**的:大乱斗必须**继续**消费 peer_hues(别被"1v1 停用"顺手删掉)。
#   · 守卫 E(2026-09-21,用户报「3v3 青队玩家还是看见自己是蓝色的」):3v3 的**自己**那具
#     必须也是队色 —— 它此前传的是 `Settings.pvp_color_hue`(默认 0 = 不改色 ⇒ 身体恒为本体蓝
#     = 队 1 色)。这条同时补上 CLAUDE.md 登记过的那个**守卫缺口**(`team_game` 把颜色来源改错时
#     **一个探针都不会红**):① 走生产的 `_refresh_team_colors()` 看像素;② `team_game.gd` 对
#     `pvp_color_hue` 零引用;③ 颜色钩子必须消费 `teams` 且不进 `_apply_peer_hues`。
#
# ★ 染色一律走**生产那份代码**:
#   · 1v1 那三具调用 `pvp_game._apply_p2_tint()` 本体(离线 `.new()`,把 `PvpSession.role` /
#     `_local` / `_remote_replica` 摆好即可)—— 探针**不抄**"染哪一具、染成什么"。
#   · 3v3 那两具走 `PvpMatchClient._apply_tint`(与生产同一个入口)。
#   只抄公式的话会出现"探针和生产各自漂移、仍全绿"。

const OUT_DIR := "res://.superpowers/sdd"
const PLAYER_SCENE := "res://scenes/player/player.tscn"
const SHADER_PATH := "res://scenes/player/player_p2_hue.gdshader"
const PVP_GAME := "res://scenes/pvp_game.gd"
const ROYALE_GAME := "res://scenes/royale_game.gd"
const TEAM_GAME := "res://scenes/team_game.gd"
const BODY_TEXTURE := "res://assets/textures/player.png"

# 头顶 ID 的底板实色(`ui/world_label.gd` 的 `黑 0.1` 压在 ui/ui_factory.gd 的 C_PLATE 注释记的地图开阔区
# #78969F 上)= #6C8790。用它当探针底 ⇒ 取到的色就是实机上那一条(与队色对比度同源)。
const BACKDROP := Color(0x6C / 255.0, 0x87 / 255.0, 0x90 / 255.0)
const BODY_SCALE := 4.0        # 48×48 的帧 → 192px
const ROW1_Y := 340.0          # 1v1:P1 本地 / P2 本地 / 控制组
const ROW2_Y := 900.0          # 3v3:队 1 / 队 2 / role 1 眼里的对手副本
const ROW3_Y := 1240.0         # 3v3:**自己**(队 2)那具 —— 守卫 E 用
const XS := [280.0, 960.0, 1640.0]

# 守卫 E 的**确定性**前提:探针把自选色相临时摆成 120°(绿)。
# 旧实现(`_apply_tint(sprite, Settings.pvp_color_hue)`,即"自己仍是自选色")会把身体染成绿 ⇒
# 与队 2 的青**不同** ⇒ 守卫 E ① 红;而若自选色相停在默认 0(不改色),旧实现留下的身体是本体蓝
# —— 那**同样**不等于队 2 的 token,故两种情况都红。摆 120° 只是让"红"更显眼、不依赖存档值。
const FALSIFY_HUE_DEG := 120.0

# 「青」区间(用户 2026-09-19 裁定:青绿区间 165~185 的偏绿侧;2026-09-20 把队 2 / P2 的色相
# 定到 185 整)。★ 上界那 +0.5° 是 **8bit 量化余量**,不是放宽口径:`#80F4FF` 是 H185 S50 V100
# 量化到 8bit 的结果,把它读回 HSV 得到 **185.20°**(量化前恰是 185.00)——
# 上界卡死在 185.0 会把**用户指定的那个色**判成越界。真正硬的那条是守卫 B ③(逐字节等于 token),
# 这条只管"它还在青色区间里"(token 漂到绿 / 漂到浅蓝时它才该红)。
const GREEN_CYAN_HUE_MIN := 165.0
const GREEN_CYAN_HUE_MAX := 185.5

var _img: Image = null
var _spr: Dictionary = {}      # 名 -> AnimatedSprite2D
var _roots: Dictionary = {}    # 名 -> 那具 player.tscn 的根(生产的 _apply_p2_tint 要它)


func probe_id() -> String:
	return "HUE-TINT"


func _ready() -> void:
	await _run()
	_finish()


func _run() -> void:
	# ── 前置:两样都要在(缺一个就早退,别让后面 deref 崩成"没跑完")──
	var ps: PackedScene = load(PLAYER_SCENE)
	if ps == null:
		_check(false, "player.tscn 载入失败(守卫无从成立)")
		return
	var pvp_script: GDScript = load(PVP_GAME)
	if pvp_script == null:
		_check(false, "pvp_game.gd 载入失败(调不到生产的 _apply_p2_tint,守卫 B 无从成立)")
		return

	# ── 场景:六具身体,底 = 头顶名底板实色 ──
	var bg := ColorRect.new()
	bg.color = BACKDROP
	bg.position = Vector2.ZERO
	bg.size = get_viewport().get_visible_rect().size
	add_child(bg)
	# ── 第 1 行(1v1)──
	# ① P1:role 1 的**本地玩家** —— 生产那一趟只染对手副本,这一具必须**一点没染**(= 本体蓝)
	_spr["P1"] = _spawn(ps, "P1", Vector2(XS[0], ROW1_Y))
	# ② P2:role 2 的**本地玩家** —— 生产染它(实测色须 == `C_TEAM_B`)
	_spr["P2"] = _spawn(ps, "P2", Vector2(XS[1], ROW1_Y))
	# ③ 控制组:同一个 shader 但 `hue_shift = 0` —— **语义探针**专用配置
	#    (它要与 P1 逐像素相同;生产路径在 0 时早退、不挂 shader,故 P1 就是"不挂 shader"那一份)
	_spr["控制组"] = _spawn(ps, "控制组", Vector2(XS[2], ROW1_Y))
	var mat := ShaderMaterial.new()
	mat.shader = load(SHADER_PATH)
	mat.set_shader_parameter("hue_shift", 0.0)
	(_spr["控制组"] as AnimatedSprite2D).material = mat
	# ── 第 2 行(3v3)──
	# ④/⑤ 两队:走的是 modulate **比值**那条路(与 shader 无关)
	_spr["队1"] = _spawn(ps, "队1", Vector2(XS[0], ROW2_Y))
	_tint(_spr["队1"], 0.0, UiFactory.C_TEAM_A)
	_spr["队2"] = _spawn(ps, "队2", Vector2(XS[1], ROW2_Y))
	_tint(_spr["队2"], 0.0, UiFactory.C_TEAM_B)
	# ⑥ role 1 眼里的**对手副本**(1v1 的另一半):生产该染**它**,而不是染本地那具
	_spr["P2副本"] = _spawn(ps, "P2副本", Vector2(XS[2], ROW2_Y))
	# ⑦ 3v3 的**自己**(守卫 E):队 2 的人看自己那具 —— 生产该把它染成队 2 色
	_spr["3v3自己"] = _spawn(ps, "3v3自己", Vector2(XS[2], ROW3_Y))

	# ★★ 1v1 那三具的染色**由生产自己做**(见 `_apply_production_p2_tint`)。
	_apply_production_p2_tint(pvp_script)
	# ★★ 3v3「自己」那具同样由**生产**做(见 `_apply_production_team_self_tint`)。
	_apply_production_team_self_tint()

	await _frames(6)
	_img = await _shot("_hue_guard_p1_p2.png")
	if _img == null:
		_check(false, "截图失败 —— 是不是误加了 --headless?(真渲染是本探针的前提)")
		return

	_guard_a_semantics()
	_guard_b_two_colors()
	_guard_c_royale_still_consumes_hues()
	_guard_d_token_sources()
	_guard_e_team_self_tint()


# ── ★★ 染色**不抄**:把 `pvp_game._apply_p2_tint()` 本体的两个分支各走一遍 ──
# 离线 `.new()`(不进树;该函数只读 `PvpSession.role` / `_local` / `_remote_replica` 三个输入,
# 不读别的成员状态)⇒ 测的就是生产那份代码:改坏"染哪一具 / 染成什么 / 用什么机制"都会红。
# ★ 为什么不能由探针自己调 `_apply_tint(..., C_TEAM_B)`:那样③就退化成"把 token 传进去、
#   再把 token 读出来"(恒真),**验不到生产到底有没有这么染**。
func _apply_production_p2_tint(pvp_script: GDScript) -> void:
	var game: Node2D = pvp_script.new()
	if game == null:
		_check(false, "pvp_game.gd 实例化失败(生产那条染色路径无从执行)")
		return
	var saved_role := PvpSession.role
	# ① role 1:应染 `_remote_replica`(**对手副本**),且**不碰** `_local`
	PvpSession.role = 1
	game.set("_local", _roots.get("P1"))
	game.set("_remote_replica", _roots.get("P2副本"))
	game.call("_apply_p2_tint")
	# ② role 2:应染 `_local`(自己那具)
	PvpSession.role = 2
	game.set("_local", _roots.get("P2"))
	game.set("_remote_replica", null)
	game.call("_apply_p2_tint")
	PvpSession.role = saved_role
	game.free()
	# 早退守卫:三具根都在,否则上面 `game.set(..., null)` 会让生产静默什么都不染
	_check(_roots.has("P1") and _roots.has("P2") and _roots.has("P2副本"),
			"探针自己没备齐三具身体根(生产染色断言无从成立)")


# ── ★★ 3v3「自己」那具的染色也**不抄**:把 `team_game._refresh_team_colors()` 本体走一遍 ──
# 只摆好它要读的四个输入(`_local` / `_replicas` / `_teams` / `PvpSession.role`),其余不碰
# —— 该函数只读这些(`_refresh_names` 里那张 `_id_labels` 表默认是空的,不触任何节点)。
# ★ 为什么必须走生产函数而不是探针自己调 `_apply_tint(..., C_TEAM_B)`:后者恒真,
#   **验不到"生产到底有没有这么染"** —— 而本守卫要守的正是那一处(2026-09-21 用户报的
#   「3v3 青队玩家还是看见自己是蓝色的」就是那里传错了来源)。
func _apply_production_team_self_tint() -> void:
	var tg_script: GDScript = load(TEAM_GAME)
	if tg_script == null:
		_check(false, "team_game.gd 载入失败(3v3 自身队色断言无从成立)")
		return
	var game: Node2D = tg_script.new()
	if game == null:
		_check(false, "team_game.gd 实例化失败(生产那条染色路径无从执行)")
		return
	var saved_role := PvpSession.role
	var saved_hue := Settings.pvp_color_hue
	PvpSession.role = 5                       # 本探针把它摆在**队 2**
	Settings.pvp_color_hue = FALSIFY_HUE_DEG  # 旧实现会把身体染成这个色(见常量注释)
	game.set("_local", _roots.get("3v3自己"))
	game.set("_replicas", {})
	game.set("_teams", {5: 2})
	game.call("_refresh_team_colors")
	PvpSession.role = saved_role
	Settings.pvp_color_hue = saved_hue
	game.free()
	_check(_roots.has("3v3自己"), "探针自己没备齐 3v3「自己」那具身体根(守卫 E ① 无从成立)")


# ── 守卫 A:shader 的 `COLOR` 语义(入参已含纹理)──
# 判据:`hue_shift = 0` 的 shader 必须与"不挂 shader"**逐像素相同**。
#   · 若入参 COLOR.rgb 里没有纹理(只有白 modulate),shift 0 会输出**纯白** ⇒ 红;
#   · 若 shader 退回 `COLOR = tex * COLOR`,输出是 `tex²`(更暗) ⇒ 红。
# 基线(2026-09-19 实测):修复后 36864 点 0 差异 / 旧实现 17424 点不同(47.3%)。
# ★ 本 shader 2026-09-20 起只服务**个人色相**(大乱斗对手色 / 大乱斗+3v3 自己的自选色),
#   1v1 的 P2 已改走 modulate 比值 ⇒ 对照用的"不挂 shader"那一份就是 P1(生产不染它)。
func _guard_a_semantics() -> void:
	var before := _failures.size()
	var ra := _rect_px(_spr["P1"])
	var rb := _rect_px(_spr["控制组"])
	var n := 0
	var diff := 0
	for y in range(mini(ra.size.y, rb.size.y)):
		for x in range(mini(ra.size.x, rb.size.x)):
			var ca := _img.get_pixel(ra.position.x + x, ra.position.y + y)
			var cb := _img.get_pixel(rb.position.x + x, rb.position.y + y)
			n += 1
			if absf(ca.r - cb.r) > 0.004 or absf(ca.g - cb.g) > 0.004 or absf(ca.b - cb.b) > 0.004:
				diff += 1
	_check(n > 10000, "比较点数只有 %d(身体没画出来?rect 算错了?)" % n)
	_check(diff == 0,
			("★ shader 的 hue_shift=0 与「不挂 shader」不再逐像素相同(比较 %d 点,不同 %d 点)"
			+ " —— COLOR 入参不再等于「顶点色 × 纹理」:要么 shader 被改回 `COLOR = tex * COLOR`"
			+ "(纹理乘两次、颜色被压灰),要么 Godot 改了 COLOR 的语义。见 player_p2_hue.gdshader 的注释。")
			% [n, diff])
	_summary(before, "守卫 A:shift=0 ≡ 不挂 shader(逐像素 %d 点,不同 %d 点)" % [n, diff])


# ── 守卫 B:1v1 的**两条**分支 + 队色(生产函数 → 像素 → token)──
# ★ 三具体身体都是被 `pvp_game._apply_p2_tint()` 染的(或**没**被染的),不是探针自己摆的姿势:
#   ① P1(role 1 的本地玩家)**必须没被染**,② `_remote_replica`(role 1 眼里的对手)必须被染,
#   ③ role 2 的本地玩家必须被染 —— 三条一起才说明"role → 染哪一具"这条分支是对的。
func _guard_b_two_colors() -> void:
	var before := _failures.size()
	var base: Color = PvpMatchClient.BODY_BASE_COLOR
	var p1 := _modal(_spr["P1"])
	var opp := _modal(_spr["P2副本"])
	var p2 := _modal(_spr["P2"])
	# ① P1 恒蓝:role 1 那一趟染的是**对手副本**,本地这具必须一点没染(就是本体主色)
	#    (能红的实现:`_apply_p2_tint` 改成无条件染 `_local`、或把 role 判断写反)
	_check(_same_rgb(p1, base),
			"★ 1v1 的 P1 身体应恰好是本体主色 %s(实测 %s)——「P1 是蓝」被破坏了(role 1 那一趟不该染本地那具)"
			% [_hex(base), _hex(p1)])
	# ② role 1 眼里的**对手副本**必须被染成队 2 色(这是 1v1 里"看见对手"的那一具)
	_check(_same_rgb(opp, UiFactory.C_TEAM_B),
			"★ 1v1 里 role 1 看到的对手副本身体应是 C_TEAM_B %s(实测 %s)—— 生产没染对手那具"
			% [_hex(UiFactory.C_TEAM_B), _hex(opp)])
	# ③ P2 恒青:与 3v3 队 2 **同一个 token、同一个机制**,实测须逐字节相等
	var hue2 := p2.h * 360.0
	_check(_same_rgb(p2, UiFactory.C_TEAM_B),
			"★ 1v1 的 P2 身体应恰好等于 3v3 队 2 的 token C_TEAM_B %s(实测 %s)—— 两处口径必须同色"
			% [_hex(UiFactory.C_TEAM_B), _hex(p2)])
	_check(hue2 >= GREEN_CYAN_HUE_MIN and hue2 <= GREEN_CYAN_HUE_MAX,
			("★ 1v1 的 P2 色相应落在「青」%d~%d°(实测 %.2f°)—— 它现在**等于** token `C_TEAM_B` 的色相,"
			+ "故这条实际在守「队 2 那个 token 还在用户裁定的青色区间里」(上界含 8bit 量化余量,见常量注释)")
			% [GREEN_CYAN_HUE_MIN, GREEN_CYAN_HUE_MAX, hue2])
	# ④ 队色(modulate 比值)也要逐字节等于 token:身体那一处与头顶 ID / 小地图点位同源
	var ta := _modal(_spr["队1"])
	var tb := _modal(_spr["队2"])
	_check(_same_rgb(ta, UiFactory.C_TEAM_A),
			"3v3 队 1 身体应恰好是 C_TEAM_A %s(实测 %s)" % [_hex(UiFactory.C_TEAM_A), _hex(ta)])
	_check(_same_rgb(tb, UiFactory.C_TEAM_B),
			"3v3 队 2 身体应恰好是 C_TEAM_B %s(实测 %s)" % [_hex(UiFactory.C_TEAM_B), _hex(tb)])
	# ⑤ 两队必须**互相**可分辨(不然"一眼看出谁是队友"落空):同色或近色一律红
	var d := absf(ta.r - tb.r) + absf(ta.g - tb.g) + absf(ta.b - tb.b)
	_check(d > 0.3, "★ 两队身体色太接近(逐通道差之和 %.3f)—— 六人同框分不出队伍" % d)
	_summary(before, "守卫 B:1v1 的 P1=%s / 对手副本=%s / P2=%s(hsv %.2f°)/ 队1=%s / 队2=%s / 两队差 %.3f"
			% [_hex(p1), _hex(opp), _hex(p2), hue2, _hex(ta), _hex(tb), d])


# ── 守卫 C(反向):大乱斗**必须继续**消费 peer_hues;1v1 那一侧必须停用 ──
func _guard_c_royale_still_consumes_hues() -> void:
	var before := _failures.size()
	# ① 反向:大乱斗照旧读载荷(4~8 人靠颜色区分;"1v1 停用"不能连坐)
	var royale := _code_only(_read(ROYALE_GAME))
	var rbody := _func_body(royale, "_apply_peer_hues")
	_check(not rbody.is_empty(), "读不到 royale_game.gd 的 _apply_peer_hues")
	_check(rbody.contains("_hues.get"),
			"★ 大乱斗的 _apply_peer_hues 不再读载荷里的色相了 —— 停用它等于把「对手颜色」这条 L6 加成删掉")
	_check(royale.contains("pvp_color_hue"),
			"★ 大乱斗不再消费 Settings.pvp_color_hue 了(自选色相是大乱斗唯一还生效的地方)")
	# ② 正向:1v1 整份文件对 Settings.pvp_color_hue **零引用**(注释不算),且不再读载荷
	var pvp := _code_only(_read(PVP_GAME))
	_check(not pvp.contains("pvp_color_hue"),
			("★ pvp_game.gd 又引用 Settings.pvp_color_hue 了 —— 1v1 的自选色相已按裁定停用"
			+ "(双方都选默认值时两个身体同为蓝,分不出谁是谁)") )
	_check(not pvp.contains("_opp_hues"),
			"★ pvp_game.gd 里 _opp_hues 复活了 —— 1v1 不消费 peer_hues,那份载荷不该有落点")
	var hues_body := _func_body(pvp, "_apply_peer_hues")
	_check(not hues_body.is_empty(), "读不到 pvp_game.gd 的 _apply_peer_hues(基类要求子类覆写它)")
	_check(not hues_body.contains("hues.get"),
			"★ 1v1 的 _apply_peer_hues 又在读载荷里的色相了(裁定:本模式恒为 P1 蓝 / P2 青)")
	# 短路后它该做的是"把固定那条重铺一次" —— 判据**不钉 helper 名**,只问有没有重铺动作:
	# 体内必须调用某个 `_apply_*tint(` 帮手(现名 `_apply_p2_tint()`;改名 / 换等价帮手都不算回退)。
	# 要拦的变异只有一条:把 `_apply_peer_hues` 改成**空函数/空壳** —— 那时上面两条照绿,
	# 但"把固定染色重铺一遍"的动作没了。★ 它**测不到**重铺的是不是同一条颜色(那是守卫 B 的活)。
	var re_tint := RegEx.new()
	re_tint.compile("_apply_[A-Za-z0-9_]*tint\\s*\\(")
	_check(re_tint.search(hues_body) != null,
			"★ 1v1 的 _apply_peer_hues 不再重铺固定染色(体内没调用任何 _apply_*tint(...) 帮手)—— 改空了就只剩「不读载荷」这个空壳")
	_summary(before, "守卫 C(反向):大乱斗仍消费 hues+pvp_color_hue / 1v1 零引用且不读载荷")


# ── 守卫 D:三处**同源**的常量必须真的同值(`player.png` ↔ BODY_BASE_COLOR ↔ C_TEAM_A)──
func _guard_d_token_sources() -> void:
	var before := _failures.size()
	var tex: Texture2D = load(BODY_TEXTURE)
	var img: Image = tex.get_image() if tex != null else null
	if img == null:
		_check(false, "%s 读不出 Image(本体主色的复测无从成立)" % BODY_TEXTURE)
	else:
		# 复测办法就是 pvp_match_client.gd 该常量注释里写的那条:按 alpha>200 过滤,取众数 RGB
		var hist: Dictionary = {}
		for y in range(img.get_height()):
			for x in range(img.get_width()):
				var c := img.get_pixel(x, y)
				if c.a > 200.0 / 255.0:
					var k := Vector3i(roundi(c.r * 255.0), roundi(c.g * 255.0), roundi(c.b * 255.0))
					hist[k] = int(hist.get(k, 0)) + 1
		var best := Vector3i(0, 0, 0)
		var bn := -1
		for k in hist:
			if int(hist[k]) > bn:
				bn = int(hist[k])
				best = k
		var mode := Color(best.x / 255.0, best.y / 255.0, best.z / 255.0)
		_check(_same_rgb(mode, PvpMatchClient.BODY_BASE_COLOR),
				("★ player.png 的不透明众数色 %s ≠ BODY_BASE_COLOR %s —— 换素材后没重测本体主色,"
				+ "队色(比值 = 队色 / 主色)会**整体偏**而没人发现") % [_hex(mode), _hex(PvpMatchClient.BODY_BASE_COLOR)])
	# 常量 → 队色 token:队 1 取的就是本体主色(比值恰为 1 ⇒ 队 1 就是默认蓝)
	_check(_same_rgb(UiFactory.C_TEAM_A, PvpMatchClient.BODY_BASE_COLOR),
			("★ C_TEAM_A %s ≠ PvpMatchClient.BODY_BASE_COLOR %s —— 队 1 不再等于本体那种蓝"
			+ "(队色与本体主色是同一条链,要一起改)") % [_hex(UiFactory.C_TEAM_A), _hex(PvpMatchClient.BODY_BASE_COLOR)])
	_summary(before, "守卫 D:player.png 众数 == BODY_BASE_COLOR == C_TEAM_A")


# ── 守卫 E:3v3 的**自己**也是队色(2026-09-21 用户裁定「青队玩家还是看见自己是蓝色的」)──
# 这条补的是一个**登记在案**的守卫缺口:`team_game` 把「自己那具用哪个来源」改错时,原先
# **一个探针都不会红**(guard C 只管 1v1 与大乱斗两侧,3v3 那一段当时没有断言)。
#   ① **行为**(像素):生产的 `_refresh_team_colors()` → 自己那具的众数色**逐字节等于**
#      `C_TEAM_B`(队 2)。旧实现传的是 `Settings.pvp_color_hue` ⇒ 要么绿(摆的 120°)、
#      要么本体蓝(默认 0)—— 两种都不等于 token ⇒ 红。
#   ② **源码**:`team_game.gd` 对 `Settings.pvp_color_hue` **零引用**(与 guard C ② 对
#      `pvp_game.gd` 的同款口径:个人色相在 3v3 整体停用,它在本模式不再有任何落点)。
#   ③ **源码**:基类钩子 `_apply_peer_hues_or_team` 的覆写**必须消费 `teams`**、且**不得**
#      调 `_apply_peer_hues`(那正是缺口描述里"改回基类默认也不会红"的那一处)。
func _guard_e_team_self_tint() -> void:
	var before := _failures.size()
	# ① 行为:自己那具的像素色 == 队 2 token
	var me := _modal(_spr["3v3自己"])
	_check(_same_rgb(me, UiFactory.C_TEAM_B),
			("★ 3v3 里**自己**的身体应恰好是 C_TEAM_B %s(实测 %s)—— 生产把" +
			"自己那具染成了别的来源(旧实现是 Settings.pvp_color_hue;默认 0 = 不改色 ⇒ 本体蓝)。" +
			"用户原话:「3v3 青队玩家还是看见自己是蓝色的」") % [_hex(UiFactory.C_TEAM_B), _hex(me)])
	# ② 源码:3v3 整份文件对自选色相零引用(注释不算)
	var tg := _code_only(_read(TEAM_GAME))
	_check(not tg.contains("pvp_color_hue"),
			("★ team_game.gd 又引用 Settings.pvp_color_hue 了 —— 3v3 的自选色相已按用户裁定停用" +
			"(自己与队友必须同队色,个人色相在本模式没有落点)"))
	# ③ 源码:颜色那一段的钩子必须**继续**消费 teams,且不进基类那条"个人色相"路
	var hook := _func_body(tg, "_apply_peer_hues_or_team")
	_check(not hook.is_empty(), "读不到 team_game.gd 的 _apply_peer_hues_or_team")
	_check(hook.contains("teams"),
			"★ 3v3 的 _apply_peer_hues_or_team 不再消费载荷里的 teams 了 —— 队色是本模式唯一的颜色来源")
	_check(not hook.contains("_apply_peer_hues("),
			"★ 3v3 的颜色钩子里出现 _apply_peer_hues 了 —— peer_hues 在本模式是无效输入(6 个人认不出队友)")
	_summary(before, "守卫 E:3v3 自己 == 队 2 token(%s)/ 文件零引用 pvp_color_hue / 钩子只消费 teams"
			% _hex(me))


# ── 生产路径的染色助手:直接调 `PvpMatchClient._apply_tint`(不实例化进树;
#    该函数只碰它的三个入参、不读成员状态 ⇒ 离线调用安全,且**测的就是生产那份代码**)──
# ★ 只用于 3v3 那两具(队色)。1v1 那三具走 `_apply_production_p2_tint`(调的是
#   `pvp_game._apply_p2_tint` 本体)—— 别把 1v1 也改成这里直接传 token,那会让守卫 B ③ 恒真。
func _tint(spr: AnimatedSprite2D, hue_deg: float, override: Color = Color(0, 0, 0, 0)) -> void:
	if spr == null:
		return
	var pmc: PvpMatchClient = PvpMatchClient.new()
	pmc._apply_tint(spr, hue_deg, override)
	pmc.free()


# key 既是 `_spr` 的键也是 `_roots` 的键(生产的 `_apply_p2_tint` 要的是**根**,不是 sprite)
func _spawn(ps: PackedScene, key: String, pos: Vector2) -> AnimatedSprite2D:
	var p: Node2D = ps.instantiate()
	add_child(p)
	p.set_physics_process(false)
	p.scale = Vector2(BODY_SCALE, BODY_SCALE)
	p.position = pos
	_roots[key] = p
	var spr: AnimatedSprite2D = p.get_node_or_null("AnimatedSprite2D")
	if spr == null:
		_check(false, "player.tscn 里没有 AnimatedSprite2D")
		return null
	# 冻到同一帧:守卫 A 要逐像素比较,各人动画帧不同就没法比
	spr.play(&"idle")
	spr.pause()
	spr.frame = 0
	return spr


# 身体矩形(图像像素)。用 sprite 自己的变换算,不假设 player.tscn 的内部偏移。
func _rect_px(spr: AnimatedSprite2D) -> Rect2i:
	if spr == null or _img == null:
		return Rect2i()
	var fr := spr.sprite_frames.get_frame_texture(spr.animation, spr.frame)
	if fr == null:
		return Rect2i()
	var sz: Vector2 = fr.get_size() * spr.global_scale
	var vs := get_viewport().get_visible_rect().size
	var s := float(_img.get_width()) / maxf(vs.x, 1.0)
	var r := Rect2((spr.global_position - sz * 0.5) * s, sz * s)
	return Rect2i(int(r.position.x), int(r.position.y), int(r.size.x), int(r.size.y))


# 矩形内"非背景"像素的众数 = 本体主色(它占不透明像素的 83.6%,众数稳定是它)。
func _modal(spr: AnimatedSprite2D) -> Color:
	var rc := _rect_px(spr)
	var hist: Dictionary = {}
	for y in range(maxi(rc.position.y, 0), mini(_img.get_height(), rc.position.y + rc.size.y)):
		for x in range(maxi(rc.position.x, 0), mini(_img.get_width(), rc.position.x + rc.size.x)):
			var c := _img.get_pixel(x, y)
			if absf(c.r - BACKDROP.r) < 0.02 and absf(c.g - BACKDROP.g) < 0.02 \
					and absf(c.b - BACKDROP.b) < 0.02:
				continue
			var k := Vector3i(roundi(c.r * 255.0), roundi(c.g * 255.0), roundi(c.b * 255.0))
			hist[k] = int(hist.get(k, 0)) + 1
	var best := Vector3i(0, 0, 0)
	var bn := -1
	for k in hist:
		if int(hist[k]) > bn:
			bn = int(hist[k])
			best = k
	return Color(best.x / 255.0, best.y / 255.0, best.z / 255.0)


# 8bit 量纲上的同色(截图往返有极小误差;口径仍是"逐字节相等")
func _same_rgb(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.004 and absf(a.g - b.g) < 0.004 and absf(a.b - b.b) < 0.004


func _hex(c: Color) -> String:
	return "#%02X%02X%02X" % [roundi(c.r * 255.0), roundi(c.g * 255.0), roundi(c.b * 255.0)]


# (原先这里有个 `_const_of` 读 `pvp_game.gd` 的 `P2_DEFAULT_HUE` —— 2026-09-20 P2 改走
#  modulate 比值后那个常量已删,探针改为**直接调生产的 `_apply_p2_tint()`**,不再读常量。)


func _frames(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


# ★ PNG 只是**给人看**的那一份,断言全在像素上 ⇒ 落盘失败**不算探针失败**(否则
#   `.superpowers/sdd/`(gitignore 目录)在别的机器上不存在就会把守卫染红,理由还与本
#   guard 无关)。目录不存在就自己建。
func _shot(png_name: String) -> Image:
	await _frames(2)
	var img := get_viewport().get_texture().get_image()
	if img == null:
		return null
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(OUT_DIR)):
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var path := OUT_DIR.path_join(png_name)
	if img.save_png(path) != OK:
		print("[HUE-TINT] (提示)截图 %s 写入失败 —— 不影响断言,只是少了人眼那一份" % png_name)
	else:
		print("[HUE-TINT] 已存 %s" % ProjectSettings.globalize_path(path))
	return img
