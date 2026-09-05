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

const KILL_COLOR := Color(0.0, 0.4, 0.5, 0.7)  # 击杀数:半透明(0.75)深青色
const KILL_FONT_SIZE := 48
# 像素字体:Less Perfect DOS VGA(8×16 经典 VGA 计数器,作者已收窄字距)。
# 字号保持 16 的整数倍才像素锐利(48=3×16)。
const KILL_FONT_PATH := "res://assets/fonts/less_perfect_dos_vga.ttf"
const KILL_MARGIN := Vector2(32, 16)            # 右上角内边距
const KILL_LABEL_W := 300.0                      # 向左留出的生长宽度
const BACK_COLOR := Color(1, 1, 1, 0.4)      # 竖条底下的半透明白色底板
const BACK_PAD := 4                            # 底板相对竖条的外扩 padding
const WATERPROOF_H := 10            # 防水值条高(细长)
const WATERPROOF_GAP := 18         # 防水值条与血条间距(下移)
const WATERPROOF_W := 18            # 每点防水值宽度(px)
const WATERPROOF_COLOR := Color(0.161, 0.26, 0.8, 0.702)  # 深蓝
const WATERPROOF_BACK := Color(1, 1, 1, 0.4)      # 底板

var _segments: Array[ColorRect] = []
var _ghost_tweens: Array[Tween] = []  # 与 _segments 并行:掉血段的淡出 tween
var _last_cur := 0
var _kill_label: Label
var _kills := 0
var _wp_bar: ColorRect = null
var _wp_back: ColorRect = null
var _wp_w := 0.0
var _wp_tween: Tween = null
var _weapon_icon: TextureRect = null
var _weapon_name: Label = null
var _ammo_label: Label = null
var _player: Node = null
var _reload_bar: ColorRect = null
var _bar_back: ColorRect = null

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


func _process(_delta: float) -> void:
	# 残弹数(实验性换弹):剪影/名称右侧实时刷新;关闭换弹玩法时隐藏
	if _ammo_label == null:
		return
	var w: WeaponBase = null
	if _player != null and is_instance_valid(_player) and "weapons" in _player:
		w = _player.weapons.current_weapon()
	var show := Settings.reload_enabled and w != null and w.reload_active()
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
	_ammo_label.text = "装填中…" if w.is_reloading() else "%d/%d" % [w.mag_ammo, w.mag_size]


# 左下角:当前武器纯白像素剪影 + 名称(HUD 游玩界面辨识)。
func _build_weapon_display(p: Node) -> void:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	box.anchor_left = 0.0
	box.anchor_right = 0.0
	box.anchor_top = 1.0
	box.anchor_bottom = 1.0
	box.offset_left = MARGIN.x
	box.offset_top = -96
	box.offset_right = MARGIN.x + 260
	box.offset_bottom = -MARGIN.y
	box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(box)

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
	_reload_bar.color = Color(0.95, 0.85, 0.55)
	_reload_bar.size = Vector2(0, 4)
	_reload_bar.visible = false
	bar_holder.add_child(_reload_bar)

	_weapon_name = Label.new()
	_weapon_name.add_theme_font_size_override("font_size", 24)
	_weapon_name.add_theme_color_override("font_color", Color(0.85, 0.93, 0.98))
	var pf: FontFile = load(KILL_FONT_PATH) as FontFile
	if pf != null:
		pf.antialiasing = TextServer.FONT_ANTIALIASING_NONE
		pf.hinting = TextServer.HINTING_NONE
		pf.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
		_weapon_name.add_theme_font_override("font", pf)
	_weapon_name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_weapon_name.size_flags_vertical = Control.SIZE_FILL
	box.add_child(_weapon_name)

	# 残弹数(实验性换弹):名称右侧,"12/30";换弹时"装填中…"
	_ammo_label = Label.new()
	_ammo_label.add_theme_font_size_override("font_size", 24)
	_ammo_label.add_theme_color_override("font_color", Color(0.95, 0.85, 0.55))
	if pf != null:
		_ammo_label.add_theme_font_override("font", pf)
	_ammo_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_ammo_label.size_flags_vertical = Control.SIZE_FILL
	_ammo_label.visible = false
	box.add_child(_ammo_label)


func _on_weapon_changed(slot: int) -> void:
	if _weapon_icon != null:
		_weapon_icon.texture = WeaponComponent.silhouette(slot)
		_weapon_name.text = WeaponComponent.DISPLAY_NAMES.get(slot, "?")

# 每个 HP 一根竖条,按最大血量排成一排,竖条之间留一点间隔;无边框。
# 竖条背后垫一层半透明白色底板,整体更易读。
func _build_segments(count: int) -> void:
	var bar_w := count * (SEG_W + SEG_GAP) - SEG_GAP
	var back := ColorRect.new()
	back.position = Vector2(MARGIN.x - BACK_PAD, MARGIN.y - BACK_PAD)
	back.size = Vector2(bar_w + BACK_PAD * 2, SEG_H + BACK_PAD * 2)
	back.color = BACK_COLOR
	call_deferred("add_child", back)  # 先加,绘制在竖条底下

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
	_kill_label = Label.new()
	_kill_label.text = "%03d" % _kills
	_kill_label.add_theme_color_override("font_color", KILL_COLOR)
	_kill_label.add_theme_font_size_override("font_size", KILL_FONT_SIZE)
	var pf: FontFile = load(KILL_FONT_PATH) as FontFile
	if pf != null:
		# 像素字体:关抗锯齿/子像素/提示,整数倍字号下保持像素边缘锐利
		pf.antialiasing = TextServer.FONT_ANTIALIASING_NONE
		pf.hinting = TextServer.HINTING_NONE
		pf.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
		_kill_label.add_theme_font_override("font", pf)
	# 锚定右上角,右对齐,文本向左生长
	_kill_label.anchor_left = 1.0
	_kill_label.anchor_right = 1.0
	_kill_label.anchor_top = 0.0
	_kill_label.anchor_bottom = 0.0
	_kill_label.offset_left = -KILL_LABEL_W
	_kill_label.offset_top = KILL_MARGIN.y
	_kill_label.offset_right = -KILL_MARGIN.x
	_kill_label.offset_bottom = KILL_MARGIN.y + KILL_FONT_SIZE * 1.4
	_kill_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_kill_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	call_deferred("add_child", _kill_label)

func _on_enemy_spawned(enemy: Node) -> void:
	if enemy.has_signal("died"):
		enemy.died.connect(_on_enemy_died)

func _on_enemy_died() -> void:
	_kills += 1
	_kill_label.text = "%03d" % _kills
