class_name Hud
extends CanvasLayer

const LAYER := 129  # 在 post-process(128)之上,不受桶形/CRT/变灰影响
const MARGIN := Vector2(24, 24)
const SEG_W := 5        # 每根竖条宽
const SEG_H := 32       # 竖条高
const SEG_GAP := 1      # 竖条之间的间隔
const COLOR_NORMAL := Color(0.35, 0.85, 0.9)  # 青色
const COLOR_LOW := Color(0.9, 0.4, 0.4)      # 血量 <25% 变红
const LOW_RATIO := 0.25

# 击杀数:强调青。原先用 Color(0,0.4,0.5,0.7) 的深青,叠在地图浅色开阔区上实测
# 对比度只有 1.93:1(低于文本下限 4.5:1,连大字下限 3:1 都不到)——「刻意压暗」过头
# 就成了「看不见」。现在配深色底板 + 强调青,实测 ≈4.8:1。
const KILL_COLOR := UiFactory.C_ACCENT
const KILL_FONT_SIZE := 48      # 16 的整数倍才像素锐利(48 = 3×16)
const WEAPON_FONT_SIZE := 32    # 武器名/残弹数;同上(32 = 2×16)
# 像素字体(Less Perfect DOS VGA,8×16 经典 VGA 计数器)与「关抗锯齿/微调/子像素」三件套
# 的唯一来源是 UiFactory.style_control(内部走 core/pixel_font.gd 的 PixelFont.shared())——
# 本文件不再自己 load 字体、不自己设字号,字号规范才守得住(见 ui_factory.gd 文件头)。
const KILL_MARGIN := Vector2(32, 16)            # 右上角内边距
# HUD 底板:武器区 / 血条 / 氧条 / 右上角击杀数,**四处共用这一个值**
# (用户 2026-09-15 定为 0.15、同日又下调到 0.1;当天这几个元素先被去掉底板、又垫回来)。
# ★ 这个值**对局内 HUD 也生效** —— 大乱斗 ping/提示条(royale_hud 的 `_plate_box`)、
#   1v1 记分条与延迟条(pvp_hud.tscn 的 `Plate` StyleBox)都是同一个 0.1。
#   ★ **例外:大乱斗排行榜 `royale_hud._board_bg` 单独是 0.25** —— 用户点名把那张玩家栏
#     排除在这轮下调之外(玩家名次表要更实的底);别看到"统一"就把那处也一起改了。
#   (`pvp_hud` 的 `Mask` 与 royale 的 `_mask` 是**全屏压暗罩**,不是底板,别顺手一起改。)
# ⚠ 0.1 是**薄薄压一层**,不是当年那套底板。按 WCAG 相对亮度算(底色取地图开阔区 #78969F):
#     alpha 0(不垫)→ 底色 L=0.283,青血条 1.87:1、金残弹 2.26:1、白字 2.57:1
#     alpha 0.10   → 底色 L=0.225,青血条 2.27:1、金残弹 2.74:1、白字 3.11:1   ← 现在
#     alpha 0.15   → 底色 L=0.199,青血条 2.50:1、金残弹 3.03:1、白字 3.44:1   ← 上一版
#     alpha 0.45   → 底色 L=0.080,青血条 4.81:1、金残弹 5.81:1、白字 6.60:1   ← 当年那套(≥4.5:1)
#   即现在只是把这几样从「勉强」提到「稍好」,血条仍低于大字下限 3:1。这是用户看过实图后的
#   选择,别拿对比度理由把它调回去;真要提对比度得动元素自身的颜色(血条青/金色残弹),另一件事。
const PLATE_COLOR := Color(0, 0, 0, 0.1)
# 血条/氧条底板比条本身每边外扩多少(右上角计数器的留白走 PanelContainer 的 content margin)
const BAR_PLATE_PAD := Vector2(6, 5)
const WATERPROOF_H := 10            # 防水值条高(细长)
const WATERPROOF_GAP := 18         # 防水值条与血条间距(下移)
const WATERPROOF_W := 18            # 每点防水值宽度(px)
# 亮蓝:当年为「深色底板」选的颜色 —— 底板换成深色后,原来的深蓝
# (Color(0.161,0.26,0.8,0.702))会在深底上糊成一片(≈1.0:1),提亮到浅蓝后 ≈3.8:1。
# (2026-09-15 底板去掉过半天,这两个值当时失去了前提;同日氧条底板垫回来后,浅蓝 3.8:1
#  与「白 0.16 空槽压在深底上」的前提重新成立。)
const WATERPROOF_COLOR := Color(0.45, 0.72, 1.0)
const WATERPROOF_BACK := Color(1, 1, 1, 0.16)     # 空槽(底板上的浅色浅槽)

var _segments: Array[ColorRect] = []
var _ghost_tweens: Array[Tween] = []  # 与 _segments 并行:掉血段的淡出 tween
var _last_cur := 0
var _kill_label: Label
var _kills := 0
var _wp_bar: ColorRect = null
var _wp_back: ColorRect = null
var _wp_plate: ColorRect = null      # 氧条底板:与条/空槽一同淡入淡出(用户 2026-09-15)
var _wp_w := 0.0
var _wp_tween: Tween = null
var _weapon_icon: TextureRect = null
var _weapon_name: Label = null
var _ammo_label: Label = null
var _slots: WeaponSlots = null
var _weapon_box: VBoxContainer = null  # 左下角:每把持有武器一个方框(上下并列)
var _drop_bar: ColorRect = null   # 长按 Q 的丢弃进度条(与换弹条共用槽位、互斥显示)
var _player: Node = null
var _ammo_low := false              # 残弹是否已进入「低弹量」金态(只在跨阈值时改色)

const WEAPON_ICON_W := 96.0   # 左下角剪影/进度条宽度

func _ready() -> void:
	layer = LAYER
	_build_kill_label()
	var spawner := get_parent().get_node_or_null("EnemySpawner")
	if spawner != null and spawner.has_signal("enemy_spawned"):
		spawner.enemy_spawned.connect(_on_enemy_spawned)
	var p := get_tree().get_first_node_in_group("player")
	if p != null and p.has_signal("hp_changed"):
		_build_segments(p.max_hp)
		p.hp_changed.connect(_on_hp)
		_on_hp(p.hp, p.max_hp)
		if p.has_signal("waterproof_changed"):
			_build_waterproof(p.max_waterproof)
			p.waterproof_changed.connect(_on_waterproof)
			_on_waterproof(p.waterproof, p.max_waterproof)
		if "weapons" in p:
			_player = p
			_build_weapon_display(p)
			_build_weapon_slots(p)   # (信号连接与初始同步都在 _build_weapon_display 里做完)



func _process(_delta: float) -> void:
	# 残弹数:剪影/名称右侧实时刷新;非单机(PvP 不换弹)时隐藏
	if _ammo_label == null:
		return
	var w: WeaponBase = null
	if _player != null and is_instance_valid(_player) and "weapons" in _player:
		w = _player.weapons.current_weapon()
	# 换弹全模式开放后弹量条恒显示 —— 原先那句 `and w.reload_active()` 正是 PvP 里
	# 弹量条整条消失的原因(闸门已删,见 weapon_base.gd 的换弹段注释)。
	var show := w != null
	_ammo_label.visible = show
	# ★ 换弹进度条**已取消**(用户 2026-09-16:改由角色旁的圆环倒计时提示,见 ui/reload_ring.gd)。
	#   那条细条与"装填中…"文案一并去掉;丢弃进度条仍用这条槽位。
	var prog := w.reload_progress() if (show and w != null) else -1.0

	# 丢弃进度:长按 Q 时占用同一条槽位(换弹优先级更高 —— 换弹中不可能是丢弃)。
	# ★ 没有反馈的两秒长按是不可用的:玩家会以为按键没生效,于是一直按着或放弃。
	if _drop_bar != null:
		var dp := 0.0
		if prog < 0.0 and show and _player != null and _player.has_method("drop_hold_progress"):
			dp = _player.drop_hold_progress()
		var dropping := dp > 0.0
		_drop_bar.visible = dropping
		if dropping:
			_drop_bar.size.x = WEAPON_ICON_W * clampf(dp, 0.0, 1.0)

	if not show:
		return
	# 金色只表「弹夹见底」这一个语义。原先满弹与残弹低位同一个金色,等于没有警告 ——
	# 现在常态是中性色,剩 ≤25% 才转金。
	var low := w.mag_ammo <= int(ceilf(w.mag_size * 0.25))
	if low != _ammo_low:
		_ammo_low = low
		_ammo_label.add_theme_color_override("font_color",
				UiFactory.C_WARN if low else UiFactory.C_TEXT)
	# ★ 换弹中**不再**改成"装填中…"(用户 2026-09-16:改用角色旁的圆环倒计时提示),
	#   这里恒显示残弹/满弹。
	_ammo_label.text = "%d/%d" % [w.mag_ammo, w.mag_size]


# 左下角:当前武器纯白像素剪影 + 名称(HUD 游玩界面辨识)。
func _build_weapon_display(p: Node) -> void:
	# 左下角:每把持有武器一个方框、**上下并列**(用户 2026-09-16)。
	#   未选中 → 只有剪影(灰);选中 → 剪影(白) + 名称 + 残弹。
	# 容量(4×2 槽位格子)另放**右下角**,见 _build_weapon_slots。
	var wrap := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = PLATE_COLOR
	sb.set_corner_radius_all(0)
	sb.content_margin_left = 12.0
	sb.content_margin_right = 12.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	wrap.add_theme_stylebox_override("panel", sb)
	wrap.anchor_left = 0.0
	wrap.anchor_right = 0.0
	wrap.anchor_top = 1.0
	wrap.anchor_bottom = 1.0
	wrap.offset_left = MARGIN.x
	wrap.offset_right = MARGIN.x + 344
	wrap.offset_bottom = -MARGIN.y
	# ★ 高度**收缩到内容**:offset_top 与底边齐平(零高),再由控件的"最小尺寸"
	#   把它撑到正好装下那几个方框,配合 GROW_DIRECTION_BEGIN 向上长。
	#   原先写死 -260 → 只有一把枪时也顶着一个巨大的空框(用户 2026-09-16 指出)。
	wrap.offset_top = wrap.offset_bottom
	wrap.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(wrap)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	wrap.add_child(col)

	_weapon_box = col
	# 丢弃进度条:挂在整列下方(与"哪把被选中"无关)
	_drop_bar = ColorRect.new()
	_drop_bar.color = UiFactory.C_DANGER
	_drop_bar.custom_minimum_size = Vector2(WEAPON_ICON_W, 4)
	_drop_bar.size = Vector2(0, 4)
	_drop_bar.visible = false
	col.add_child(_drop_bar)

	p.weapons.weapon_changed.connect(_on_weapon_changed)
	p.weapons.inventory_changed.connect(_refresh_weapon_boxes)
	_refresh_weapon_boxes()


# 重建左下角那一列:每把持有武器一个方框,顺序 = 背包顺序。
# ★ 每次都整体重建(数量少,最多 4 个)——比逐项 diff 简单,也不会漏同步。
#   选中那个的残弹 Label 存进 `_ammo_label`,供 _process 每帧刷新。
func _refresh_weapon_boxes() -> void:
	if _weapon_box == null or _player == null or _player.weapons == null:
		return
	for c in _weapon_box.get_children():
		if c == _drop_bar:
			continue
		_weapon_box.remove_child(c)
		c.queue_free()
	_ammo_label = null
	_weapon_icon = null
	_weapon_name = null
	var cur: int = _player.weapons.current_slot_int()
	var held_index := 0
	for e in _player.weapons.inventory.held:
		var t := int(e["type"])
		var sel := t == cur
		var box := PanelContainer.new()
		var bs := StyleBoxFlat.new()
		bs.bg_color = Color(0, 0, 0, 0.28) if sel else Color(0, 0, 0, 0)   # 选中的底更深(用户 2026-09-16)
		bs.set_corner_radius_all(0)
		bs.content_margin_left = 8.0
		bs.content_margin_right = 8.0
		bs.content_margin_top = 4.0
		bs.content_margin_bottom = 4.0
		box.add_theme_stylebox_override("panel", bs)
		# 用户 2026-09-16「把框更长一些」:给定宽,别随内容缩(短名字的框会明显更短)
		box.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		box.custom_minimum_size = Vector2(320, 0)
		_weapon_box.add_child(box)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 14)
		box.add_child(row)

		# 键位数字(最左):与数字键 1-4 一一对应,顺序 = 背包顺序
		var key_lbl := Label.new()
		# 用户 2026-09-16:数字太小、左右留白也太小 → 两态同字号(32,16 的倍数),
		# 宽度给到 48 并居中(左右各留 ~16px),不再贴边。
		UiFactory.style_control(key_lbl, WEAPON_FONT_SIZE)
		key_lbl.add_theme_color_override("font_color",
				UiFactory.C_TEXT if sel else UiFactory.C_TEXT_DIM)
		key_lbl.custom_minimum_size = Vector2(48, 0)
		key_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		key_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		key_lbl.text = str(held_index + 1)
		row.add_child(key_lbl)

		var icon := TextureRect.new()
		icon.texture = WeaponIcons.silhouette(t)
		icon.custom_minimum_size = Vector2(72 if sel else 58, 46 if sel else 36)   # 用户 2026-09-16「手枪被放太大了」→ 整体收一档
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		icon.modulate = Color(1, 1, 1, 1) if sel else Color(0.45, 0.45, 0.50, 1.0)
		row.add_child(icon)

		if sel:
			# 选中的才有全部信息:名称 + 残弹
			_weapon_icon = icon
			var info := VBoxContainer.new()
			info.add_theme_constant_override("separation", 2)
			info.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(info)
			_weapon_name = Label.new()
			UiFactory.style_control(_weapon_name, WEAPON_FONT_SIZE)
			_weapon_name.add_theme_color_override("font_color", UiFactory.C_TEXT)
			_weapon_name.text = WeaponComponent.DISPLAY_NAMES.get(t, "空手")
			info.add_child(_weapon_name)
			_ammo_label = Label.new()
			UiFactory.style_control(_ammo_label, WEAPON_FONT_SIZE)
			_ammo_label.add_theme_color_override("font_color", UiFactory.C_TEXT)
			info.add_child(_ammo_label)
		held_index += 1
	# 丢弃条排到最下面
	_weapon_box.move_child(_drop_bar, _weapon_box.get_child_count() - 1)


func _build_weapon_slots(p: Node) -> void:
	# 容量格子:**左下角、武器框的正上方**(用户 2026-09-16:先挪到右下角,又要求挪回)。
	#   底边贴着武器面板的顶边往上排。
	_slots = WeaponSlots.attach_to(self, p.weapons)
	var wrap_top: float = -260.0   # 武器面板顶边的 y(见 _build_weapon_display;面板自身会收缩)
	_slots.anchor_left = 0.0
	_slots.anchor_right = 0.0
	_slots.anchor_top = 1.0
	_slots.anchor_bottom = 1.0
	_slots.offset_left = MARGIN.x
	_slots.offset_right = MARGIN.x + WeaponSlots.PANEL_W
	_slots.offset_bottom = wrap_top - 8.0
	_slots.offset_top = _slots.offset_bottom - WeaponSlots.PANEL_H


func _on_weapon_changed(_slot: int) -> void:
	# ★ 直接重建整个列表,别去改"某个缓存下来的 Label/Icon" —— 那两样在每次重建时都会被
	#   queue_free,而**释放后的对象不是 null**,`!= null` 挡不住它,表现为
	#   "Trying to cast a freed object"(实测踩到:weapon_changed 先于 inventory_changed 发射,
	#   回调先摸到了上一轮的旧节点)。
	_refresh_weapon_boxes()


# 每个 HP 一根竖条,按最大血量排成一排,竖条之间留一点间隔;条本身无边框。
# 底板(PLATE_COLOR)铺在整排下面 —— 竖条之间那 1px 缝于是透出底板而不是地图,
# 整排读成一条「压在薄板上的条」(0.1 很淡,缝里与缝外的差别是刻意做小的)。
func _build_segments(count: int) -> void:
	# ★ 底板**先**入队:入树顺序即绘制顺序,后加的条才画在它上面
	var bar_w := count * (SEG_W + SEG_GAP) - SEG_GAP
	var plate := ColorRect.new()
	plate.color = PLATE_COLOR
	plate.position = Vector2(MARGIN.x - BAR_PLATE_PAD.x, MARGIN.y - BAR_PLATE_PAD.y)
	plate.size = Vector2(bar_w + BAR_PLATE_PAD.x * 2.0, SEG_H + BAR_PLATE_PAD.y * 2.0)
	call_deferred("add_child", plate)
	for i in range(count):
		var seg := ColorRect.new()
		seg.position = Vector2(MARGIN.x + i * (SEG_W + SEG_GAP), MARGIN.y)
		seg.size = Vector2(SEG_W, SEG_H)
		seg.color = COLOR_NORMAL
		call_deferred("add_child", seg)
		_segments.append(seg)
		_ghost_tweens.append(null)

func _on_hp(cur: int, max_hp: int) -> void:
	var ratio := float(cur) / float(max(1, max_hp))
	var color := COLOR_LOW if ratio < LOW_RATIO else COLOR_NORMAL
	for i in _segments.size():
		var seg := _segments[i]
		seg.color = color
		if i < cur:
			# 存活段:清掉可能残留的淡出 tween,恢复不透明
			_kill_ghost(i)
			seg.modulate = Color.WHITE
			seg.visible = true
		else:
			seg.visible = false
	# 新掉血的段(旧血量→新血量之间):白闪后淡出,提示伤害
	for i in range(max(cur, 0), _last_cur):
		_start_ghost(i)
	_last_cur = cur

# 防水值(氧气)条:血条下方深蓝细长条,长度按防水值/上限。
# 底板 + 空槽 + 实条三件套,初始 alpha 全是 0 —— 满氧时整组不该出现(见 _on_waterproof)。
func _build_waterproof(wp_max: int) -> void:
	_wp_w = WATERPROOF_W * wp_max
	var y := MARGIN.y + SEG_H + WATERPROOF_GAP
	_wp_plate = ColorRect.new()
	_wp_plate.position = Vector2(MARGIN.x - BAR_PLATE_PAD.x, y - BAR_PLATE_PAD.y)
	_wp_plate.size = Vector2(_wp_w + BAR_PLATE_PAD.x * 2.0, WATERPROOF_H + BAR_PLATE_PAD.y * 2.0)
	_wp_plate.color = PLATE_COLOR
	_wp_plate.modulate.a = 0.0
	call_deferred("add_child", _wp_plate)
	_wp_back = ColorRect.new()
	_wp_back.position = Vector2(MARGIN.x, y)
	_wp_back.size = Vector2(_wp_w, WATERPROOF_H)
	_wp_back.color = WATERPROOF_BACK
	_wp_back.modulate.a = 0.0
	call_deferred("add_child", _wp_back)
	_wp_bar = ColorRect.new()
	_wp_bar.position = Vector2(MARGIN.x, y)
	_wp_bar.size = Vector2(_wp_w, WATERPROOF_H)
	_wp_bar.color = WATERPROOF_COLOR
	_wp_bar.modulate.a = 0.0
	call_deferred("add_child", _wp_bar)

func _on_waterproof(cur: int, max: int) -> void:
	if _wp_bar != null:
		_wp_bar.size.x = WATERPROOF_W * cur
		# 满值(陆地恢复满)→ 淡出;非满(开始消耗)→ 淡入
		_fade_waterproof(0.0 if cur >= max else 1.0)

# 掉血段效果:闪烁两下(闪白回到底色),最后淡出消失。

func _fade_waterproof(a: float) -> void:
	if _wp_tween != null and _wp_tween.is_valid():
		_wp_tween.kill()
	_wp_tween = create_tween()
	# 底板与条/空槽**同一 tween、同一时长** —— 氧条消失时底板必须跟着走,
	# 否则浅色地形上会留下一块没人认领的暗矩形(用户明确要求「一同出现消失」)。
	_wp_tween.set_parallel(true)
	for c in [_wp_bar, _wp_back, _wp_plate]:
		_wp_tween.tween_property(c, "modulate:a", a, 0.4)

func _start_ghost(i: int) -> void:
	var seg := _segments[i]
	_kill_ghost(i)
	seg.visible = true
	var base := seg.color  # 当前底色(青/红)
	var tw := create_tween()
	# 闪烁两下:每次先闪白再回到底色(原来的变透明改为变白)
	for _b in range(2):
		tw.tween_property(seg, "color", Color.WHITE, 0.08)
		tw.tween_property(seg, "color", base, 0.08)
	tw.tween_property(seg, "modulate:a", 0.0, 0.2)   # 最后淡出
	tw.tween_callback(func():
		seg.visible = false
		seg.modulate = Color.WHITE
		seg.color = base
	)
	_ghost_tweens[i] = tw

func _kill_ghost(i: int) -> void:
	if _ghost_tweens[i] != null and _ghost_tweens[i].is_valid():
		_ghost_tweens[i].kill()
		_ghost_tweens[i] = null

# 右上角击杀计数:初始 000,每死一个敌人 +1(三位零填充)。
func _build_kill_label() -> void:
	# 底板 2026-09-15 按用户要求去掉过、同日又按用户要求垫回(见 PLATE_COLOR)。
	# ⚠ **底色必须显式给**:StyleBoxFlat 的默认底色是**不透明灰 (0.6,0.6,0.6,1.0)**、
	#   `draw_center` 默认 true —— 想"去掉底色"却只删掉 `bg_color` 赋值那一行,等于把半透明
	#   黑板换成一块**实心灰板**(比原来还显眼;实测发过一版,用户当场看出「右上角怎么还有框」)。
	#   当时是靠 `draw_center = false` 救的,现在底色回来了就不要那行。
	var wrap := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = PLATE_COLOR
	sb.set_corner_radius_all(0)
	sb.content_margin_left = 16.0
	sb.content_margin_right = 16.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	wrap.add_theme_stylebox_override("panel", sb)
	# 锚定右上角:宽高都留 0,由文本撑开、向左下生长 —— 板子只包住数字,不做成长条。
	wrap.anchor_left = 1.0
	wrap.anchor_right = 1.0
	wrap.anchor_top = 0.0
	wrap.anchor_bottom = 0.0
	wrap.offset_left = -KILL_MARGIN.x
	wrap.offset_right = -KILL_MARGIN.x
	wrap.offset_top = KILL_MARGIN.y
	wrap.offset_bottom = KILL_MARGIN.y
	wrap.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	wrap.grow_vertical = Control.GROW_DIRECTION_END
	call_deferred("add_child", wrap)

	_kill_label = Label.new()
	_kill_label.text = "%03d" % _kills
	_kill_label.add_theme_color_override("font_color", KILL_COLOR)
	UiFactory.style_control(_kill_label, KILL_FONT_SIZE)      # 像素字体 + 字号(16 倍数)
	wrap.add_child(_kill_label)

func _on_enemy_spawned(enemy: Node) -> void:
	if enemy.has_signal("died"):
		enemy.died.connect(_on_enemy_died)

func _on_enemy_died() -> void:
	_kills += 1
	_kill_label.text = "%03d" % _kills
