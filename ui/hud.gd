class_name HUD
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
# HUD 底板(2026-09-13 视觉评析):血条/氧条/武器区/击杀数一律垫一块半透明深色底板。
# 此前这些元素**直接叠在地图上**,而地图开阔区是浅灰蓝 —— 青色血条压上去实测 ≈1.9:1,
# 金色残弹 ≈2.3:1,而且同一个元素横跨深色砖墙与浅色开阔区时清晰度还在变。
# 深底板把底层压到 L≈0.08,所有元素一律 ≥4.5:1,且不再随地图明暗漂移。
# 0.45 是实测算出来的下限:更浅(如 0.25)在浅色开阔区只能到 3.07:1,不达标。
const PLATE_COLOR := Color(0, 0, 0, 0.45)
const PLATE_PAD := 8                           # 底板相对内容的外扩 padding
const WATERPROOF_H := 10            # 防水值条高(细长)
const WATERPROOF_GAP := 18         # 防水值条与血条间距(下移)
const WATERPROOF_W := 18            # 每点防水值宽度(px)
# 亮蓝:底板换成深色后,原来的深蓝(Color(0.161,0.26,0.8,0.702) 叠在浅色底板上)会在
# 深底上糊成一片(实测对比度 ≈1.0:1)。提亮到浅蓝后 ≈3.8:1,过非文本控件的 3:1 线。
const WATERPROOF_COLOR := Color(0.45, 0.72, 1.0)
const WATERPROOF_BACK := Color(1, 1, 1, 0.16)     # 空槽:底板上的浅色浅槽

var _segments: Array[ColorRect] = []
var _ghost_tweens: Array[Tween] = []  # 与 _segments 并行:掉血段的淡出 tween
var _last_cur := 0
var _kill_label: Label
var _kills := 0
var _wp_bar: ColorRect = null
var _wp_back: ColorRect = null
var _wp_w := 0.0
var _hp_w := 0.0
var _wp_tween: Tween = null
var _weapon_icon: TextureRect = null
var _weapon_name: Label = null
var _ammo_label: Label = null
var _player: Node = null
var _reload_bar: ColorRect = null
var _bar_back: ColorRect = null
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
			p.weapons.weapon_changed.connect(_on_weapon_changed)
			_on_weapon_changed(p.weapons._current_slot)   # 初始同步(首把枪可能未经 equip)
	# 底板最后加:竖条/氧条都走 call_deferred,这里直接 add_child 必画在它们底下。
	_add_bars_plate()


# 血条 + 氧条共用的一块深色底板。两块条尺寸由各自 build 时记下(_hp_w / _wp_w),
# 氧条没建(玩家无防水值)时底板只包血条。
func _add_bars_plate() -> void:
	if _hp_w <= 0.0 and _wp_w <= 0.0:
		return
	var w := maxf(_hp_w, _wp_w)
	var h := SEG_H
	if _wp_w > 0.0:
		h += WATERPROOF_GAP + WATERPROOF_H
	var plate := ColorRect.new()
	plate.position = Vector2(MARGIN.x - PLATE_PAD, MARGIN.y - PLATE_PAD)
	plate.size = Vector2(w + PLATE_PAD * 2.0, h + PLATE_PAD * 2.0)
	plate.color = PLATE_COLOR
	add_child(plate)


func _process(_delta: float) -> void:
	# 残弹数:剪影/名称右侧实时刷新;非单机(PvP 不换弹)时隐藏
	if _ammo_label == null:
		return
	var w: WeaponBase = null
	if _player != null and is_instance_valid(_player) and "weapons" in _player:
		w = _player.weapons.current_weapon()
	var show := w != null and w.reload_active()
	_ammo_label.visible = show
	# 换弹进度条:剪影下方细条,随进度填充;非换弹状态隐藏
	var prog := -1.0
	if show and w != null:
		prog = w.reload_progress()
	if _reload_bar != null:
		_reload_bar.visible = prog >= 0.0
		_bar_back.visible = prog >= 0.0
		if prog >= 0.0:
			_reload_bar.size.x = WEAPON_ICON_W * clampf(prog, 0.0, 1.0)
	if not show:
		return
	# 金色只表「弹夹见底」这一个语义。原先满弹与残弹低位同一个金色,等于没有警告 ——
	# 现在常态是中性色,剩 ≤25% 才转金。
	var low := w.mag_ammo <= int(ceilf(w.mag_size * 0.25))
	if low != _ammo_low:
		_ammo_low = low
		_ammo_label.add_theme_color_override("font_color",
				UiFactory.C_WARN if low else UiFactory.C_TEXT)
	_ammo_label.text = "装填中…" if w.is_reloading() else "%d/%d" % [w.mag_ammo, w.mag_size]


# 左下角:当前武器纯白像素剪影 + 名称(HUD 游玩界面辨识)。
func _build_weapon_display(p: Node) -> void:
	# 武器区也垫深底板:纯白剪影 + 浅蓝武器名和血条是同一个问题 —— 直接压在地图的
	# 浅色开阔区上会被吃掉。
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
	wrap.offset_top = -112
	wrap.offset_right = MARGIN.x + 300
	wrap.offset_bottom = -MARGIN.y
	wrap.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(wrap)

	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	wrap.add_child(box)

	_weapon_icon = TextureRect.new()
	_weapon_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_weapon_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_weapon_icon.custom_minimum_size = Vector2(WEAPON_ICON_W, 60)
	_weapon_icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	# 剪影与换弹进度条纵向排布
	var icon_box := VBoxContainer.new()
	icon_box.add_theme_constant_override("separation", 3)
	box.add_child(icon_box)
	icon_box.add_child(_weapon_icon)
	var bar_holder := Control.new()
	bar_holder.custom_minimum_size = Vector2(WEAPON_ICON_W, 5)
	icon_box.add_child(bar_holder)
	_bar_back = ColorRect.new()
	_bar_back.color = Color(1, 1, 1, 0.22)
	_bar_back.size = Vector2(WEAPON_ICON_W, 4)
	_bar_back.visible = false
	bar_holder.add_child(_bar_back)
	_reload_bar = ColorRect.new()
	_reload_bar.color = UiFactory.C_ACCENT   # 装填进度=强调青(金只留给「弹夹见底」)
	_reload_bar.size = Vector2(0, 4)
	_reload_bar.visible = false
	bar_holder.add_child(_reload_bar)

	_weapon_name = Label.new()
	UiFactory.style_control(_weapon_name, WEAPON_FONT_SIZE)   # 像素字体 + 字号(16 倍数)
	_weapon_name.add_theme_color_override("font_color", UiFactory.C_TEXT)
	_weapon_name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_weapon_name.size_flags_vertical = Control.SIZE_FILL
	box.add_child(_weapon_name)

	# 残弹数(实验性换弹):名称右侧,"12/30";换弹时"装填中…"
	_ammo_label = Label.new()
	UiFactory.style_control(_ammo_label, WEAPON_FONT_SIZE)    # 像素字体 + 字号(16 倍数)
	_ammo_label.add_theme_color_override("font_color", UiFactory.C_TEXT)
	_ammo_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_ammo_label.size_flags_vertical = Control.SIZE_FILL
	_ammo_label.visible = false
	box.add_child(_ammo_label)


func _on_weapon_changed(slot: int) -> void:
	if _weapon_icon != null:
		_weapon_icon.texture = WeaponComponent.silhouette(slot)
		_weapon_name.text = WeaponComponent.DISPLAY_NAMES.get(slot, "?")

# 每个 HP 一根竖条,按最大血量排成一排,竖条之间留一点间隔;无边框。
# 竖条底下不再垫自己的白板 —— 血条/氧条共用一块深色底板(见 _add_bars_plate),
# 竖条之间的 1px 缝透出底板,整排仍读成一条「带刻度的条」。
func _build_segments(count: int) -> void:
	var bar_w := count * (SEG_W + SEG_GAP) - SEG_GAP
	_hp_w = bar_w
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
func _build_waterproof(wp_max: int) -> void:
	_wp_w = WATERPROOF_W * wp_max
	var y := MARGIN.y + SEG_H + WATERPROOF_GAP
	_wp_back = ColorRect.new()
	_wp_back.position = Vector2(MARGIN.x, y)
	_wp_back.size = Vector2(_wp_w, WATERPROOF_H)
	_wp_back.color = WATERPROOF_BACK
	call_deferred("add_child", _wp_back)
	_wp_bar = ColorRect.new()
	_wp_bar.position = Vector2(MARGIN.x, y)
	_wp_bar.size = Vector2(_wp_w, WATERPROOF_H)
	_wp_bar.color = WATERPROOF_COLOR
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
	_wp_tween.tween_property(_wp_bar, "modulate:a", a, 0.4)
	_wp_tween.parallel().tween_property(_wp_back, "modulate:a", a, 0.4)

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
	# 击杀数垫深底板:它是全 HUD 对比度最差的一个(深青叠在浅色地图上 1.93:1)。
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
