extends ProbeBase

# 色相 shader / 1v1 双色 / 队色的**常驻守卫**(场景模式 + **真渲染**:
# headless 下 get_viewport().get_texture().get_image() 返回 null,量不到像素)。
# 跑法:
#   "$GODOT" --path . --quit-after 3600 res://tests/hue_tint_probe.tscn
# 判据:grep 文本 `KH HUE-TINT PROBE: ALL-OK`(不看退出码;探针挂住时一行都不打印)。
#
# 存在理由(2026-09-19 用户裁定那一批):
#   · `player_p2_hue.gdshader` 曾有 `COLOR = tex * COLOR` 的**重复乘纹理** bug —— 而当时
#     **全仓没有一个探针会因它复活而变红**(改回去一切照旧绿,只有人眼看图才发现)。
#     守卫 A 把"入参 COLOR 已含纹理"这条**语义**钉成像素级断言:shader 一旦退回 tex*COLOR、
#     或 Godot 改了 COLOR 的语义,它都会红。
#   · 1v1 的个人色相**整体停用**后,"P1 恒蓝 / P2 恒偏绿的青"成了硬口径;守卫 B 从
#     常量 → shader → **渲染像素** → 队色 token 整条链钉住。
#   · 守卫 D 钉 `C_TEAM_A == BODY_BASE_COLOR == player.png 众数`:改了本体主色却没改队色 ⇒
#     两队一起偏,但**仍分得出谁是谁**,所以最容易漏(team_room_smoke 登记过这条局限)。
#   · 守卫 C 是**反向**的:大乱斗必须**继续**消费 peer_hues(别被"1v1 停用"顺手删掉)。
#
# ★ 染色一律走**生产那份代码**:`PvpMatchClient._apply_tint`(离线 `.new()` 调用 —— 它只碰
#   三个入参、不读成员状态),色相取自 `pvp_game.gd` 的常量表(`P2_DEFAULT_HUE`)。
#   探针**不抄**公式,才不会出现"探针和生产各自漂移、仍全绿"。

const OUT_DIR := "res://.superpowers/sdd"
const PLAYER_SCENE := "res://scenes/player/player.tscn"
const SHADER_PATH := "res://scenes/player/player_p2_hue.gdshader"
const PVP_GAME := "res://scenes/pvp_game.gd"
const ROYALE_GAME := "res://scenes/royale_game.gd"
const BODY_TEXTURE := "res://assets/textures/player.png"

# 头顶 ID 的底板实色(`ui/world_label.gd` 的 `黑 0.1` 压在 ui/hud.gd 注释记的地图开阔区
# #78969F 上)= #6C8790。用它当探针底 ⇒ 取到的色就是实机上那一条(与队色对比度同源)。
const BACKDROP := Color(0x6C / 255.0, 0x87 / 255.0, 0x90 / 255.0)
const BODY_SCALE := 4.0        # 48×48 的帧 → 192px
const ROW1_Y := 340.0          # P1 / P2 / 控制组
const ROW2_Y := 900.0          # 队 1 / 队 2
const XS := [280.0, 960.0, 1640.0]

# 「偏绿的青」区间(用户 2026-09-19 裁定:青绿区间 165~185 的偏绿侧)。改口径要一起改这里。
const GREEN_CYAN_HUE_MIN := 165.0
const GREEN_CYAN_HUE_MAX := 185.0

var _img: Image = null
var _spr: Dictionary = {}      # 名 -> AnimatedSprite2D


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
		_check(false, "pvp_game.gd 载入失败(读不到 P2_DEFAULT_HUE)")
		return
	var hue := _const_of(pvp_script, "P2_DEFAULT_HUE")

	# ── 场景:五具身体,底 = 头顶名底板实色 ──
	var bg := ColorRect.new()
	bg.color = BACKDROP
	bg.position = Vector2.ZERO
	bg.size = get_viewport().get_visible_rect().size
	add_child(bg)
	# ① P1:1v1 里 role 1 走的那条(**不染色**——`_apply_p2_tint` 只染 role 2)
	_spr["P1"] = _spawn(ps, Vector2(XS[0], ROW1_Y))
	# ② P2:1v1 里 role 2 走的那条(hue = production 的 `P2_DEFAULT_HUE`)
	_spr["P2"] = _spawn(ps, Vector2(XS[1], ROW1_Y))
	_tint(_spr["P2"], hue)
	# ③ 控制组:同一个 shader 但 `hue_shift = 0` —— **语义探针**专用配置
	#    (production 的 `_apply_tint` 在 0 时早退、不挂 shader,这一具是守卫 A 特意建的)
	_spr["控制组"] = _spawn(ps, Vector2(XS[2], ROW1_Y))
	var mat := ShaderMaterial.new()
	mat.shader = load(SHADER_PATH)
	mat.set_shader_parameter("hue_shift", 0.0)
	(_spr["控制组"] as AnimatedSprite2D).material = mat
	# ④/⑤ 3v3 两队:走的是 modulate **比值**那条路(与 shader 无关)
	_spr["队1"] = _spawn(ps, Vector2(XS[0], ROW2_Y))
	_tint(_spr["队1"], 0.0, UiFactory.C_TEAM_A)
	_spr["队2"] = _spawn(ps, Vector2(XS[1], ROW2_Y))
	_tint(_spr["队2"], 0.0, UiFactory.C_TEAM_B)

	await _frames(6)
	_img = await _shot("_hue_guard_p1_p2.png")
	if _img == null:
		_check(false, "截图失败 —— 是不是误加了 --headless?(真渲染是本探针的前提)")
		return

	_guard_a_semantics()
	_guard_b_two_colors(hue)
	_guard_c_royale_still_consumes_hues()
	_guard_d_token_sources()


# ── 守卫 A:shader 的 `COLOR` 语义(入参已含纹理)──
# 判据:`hue_shift = 0` 的 shader 必须与"不挂 shader"**逐像素相同**。
#   · 若入参 COLOR.rgb 里没有纹理(只有白 modulate),shift 0 会输出**纯白** ⇒ 红;
#   · 若 shader 退回 `COLOR = tex * COLOR`,输出是 `tex²`(更暗) ⇒ 红。
# 基线(2026-09-19 实测):修复后 36864 点 0 差异 / 旧实现 17424 点不同(47.3%)。
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


# ── 守卫 B:1v1 的两个身体色(常量 → shader → 像素 → 队色 token)──
func _guard_b_two_colors(hue: float) -> void:
	var before := _failures.size()
	var base: Color = PvpMatchClient.BODY_BASE_COLOR
	var p1 := _modal(_spr["P1"])
	var p2 := _modal(_spr["P2"])
	# ① P1 恒蓝:role 1 那条不染色,实测必须就是本体主色
	_check(_same_rgb(p1, base),
			"★ 1v1 的 P1 身体应恰好是本体主色 %s(实测 %s)——「P1 是蓝」被破坏了"
			% [_hex(base), _hex(p1)])
	# ② P2 恒偏绿的青:色相落在区间内,且**恰好**等于 3v3 队 2 的 token(同一套口径)
	var hue2 := p2.h * 360.0
	_check(hue2 >= GREEN_CYAN_HUE_MIN and hue2 <= GREEN_CYAN_HUE_MAX,
			"★ 1v1 的 P2 色相应落在「偏绿的青」%d~%d°(实测 %.1f°;它由 pvp_game.gd 的 P2_DEFAULT_HUE=%.1f° 决定)"
			% [GREEN_CYAN_HUE_MIN, GREEN_CYAN_HUE_MAX, hue2, hue])
	_check(_same_rgb(p2, UiFactory.C_TEAM_B),
			"★ 1v1 的 P2 身体应恰好等于 3v3 队 2 的 token C_TEAM_B %s(实测 %s)—— 两处口径必须同色"
			% [_hex(UiFactory.C_TEAM_B), _hex(p2)])
	# ③ 队色(modulate 比值)也要逐字节等于 token:身体那一处与头顶 ID / 小地图点位同源
	var ta := _modal(_spr["队1"])
	var tb := _modal(_spr["队2"])
	_check(_same_rgb(ta, UiFactory.C_TEAM_A),
			"3v3 队 1 身体应恰好是 C_TEAM_A %s(实测 %s)" % [_hex(UiFactory.C_TEAM_A), _hex(ta)])
	_check(_same_rgb(tb, UiFactory.C_TEAM_B),
			"3v3 队 2 身体应恰好是 C_TEAM_B %s(实测 %s)" % [_hex(UiFactory.C_TEAM_B), _hex(tb)])
	# ④ 两队必须**互相**可分辨(不然"一眼看出谁是队友"落空):同色或近色一律红
	var d := absf(ta.r - tb.r) + absf(ta.g - tb.g) + absf(ta.b - tb.b)
	_check(d > 0.3, "★ 两队身体色太接近(逐通道差之和 %.3f)—— 六人同框分不出队伍" % d)
	_summary(before, "守卫 B:P1=%s / P2=%s(hsv %.1f°)/ 队1=%s / 队2=%s / 两队差 %.3f"
			% [_hex(p1), _hex(p2), hue2, _hex(ta), _hex(tb), d])


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
			"★ 1v1 的 _apply_peer_hues 又在读载荷里的色相了(裁定:本模式恒为 P1 蓝 / P2 偏绿的青)")
	# 短路后它该做的是"把固定那条重铺一次" —— 钉住形状,免得日后有人把它改成空函数
	# (空函数能让上面两条照样绿,但 `_apply_p2_tint` 那次重铺就没了)
	_check(hues_body.contains("_apply_p2_tint()"),
			"★ 1v1 的 _apply_peer_hues 不再重铺固定染色(它该调 _apply_p2_tint())—— 改空了就只剩「不读载荷」这个空壳")
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


# ── 生产路径的染色助手:直接调 `PvpMatchClient._apply_tint`(不实例化进树;
#    该函数只碰它的三个入参、不读成员状态 ⇒ 离线调用安全,且**测的就是生产那份代码**)──
func _tint(spr: AnimatedSprite2D, hue_deg: float, override: Color = Color(0, 0, 0, 0)) -> void:
	if spr == null:
		return
	var pmc: PvpMatchClient = PvpMatchClient.new()
	pmc._apply_tint(spr, hue_deg, override)
	pmc.free()


func _spawn(ps: PackedScene, pos: Vector2) -> AnimatedSprite2D:
	var p: Node2D = ps.instantiate()
	add_child(p)
	p.set_physics_process(false)
	p.scale = Vector2(BODY_SCALE, BODY_SCALE)
	p.position = pos
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


# 读脚本常量:用 get_script_constant_map 而不是直接取属性 —— 取不存在的属性会抛错(挂住)。
# 取不到就返回 NAN 并记一条失败,让后续断言红,而不是把探针挂死。
func _const_of(gs: GDScript, name: String) -> float:
	var m: Dictionary = gs.get_script_constant_map()
	if not m.has(name):
		_check(false, "%s 里没有常量 %s" % [PVP_GAME, name])
		return NAN
	return float(m[name])


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
