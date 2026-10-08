class_name Hud
extends CanvasLayer

const LAYER := 129  # 位于后处理层之上，不受全屏着色器影响
const MARGIN := Vector2(24, 24)
const SEG_W := 5        # 生命值条单段宽度
const SEG_H := 32       # 生命值条单段高度
const SEG_GAP := 1      # 生命值条单段间距
const COLOR_NORMAL := Color(0.35, 0.85, 0.9)  # 常规青色
const COLOR_LOW := Color(0.9, 0.4, 0.4)      # 低血量报警红（低于 25%）
const LOW_RATIO := 0.25

# 击杀数文本颜色与字号规格（16 的整数倍）
const KILL_COLOR := UiFactory.C_ACCENT
const KILL_FONT_SIZE := 48
const WEAPON_FONT_SIZE := 32

# 界面通用半透明底板颜色
const PLATE_COLOR := UiFactory.C_PLATE
# 状态条底板边缘外扩留白
const BAR_PLATE_PAD := Vector2(6, 5)
const WATERPROOF_H := 10            # 氧气条高度
const WATERPROOF_GAP := 18         # 氧气条与生命条垂直间距
const WATERPROOF_W := 18            # 每点氧气宽度（像素）
const WATERPROOF_COLOR := Color(0.45, 0.72, 1.0)
const WATERPROOF_BACK := Color(1, 1, 1, 0.16)     # 空槽底槽颜色

var _segments: Array[ColorRect] = []
var _ghost_tweens: Array[Tween] = []  # 扣血受击白闪渐变动画
var _last_cur := 0
var _kill_label: Label
var _kills := 0
var _wp_bar: ColorRect = null
var _wp_back: ColorRect = null
var _wp_plate: ColorRect = null      # 氧气条底板
var _wp_w := 0.0
var _wp_tween: Tween = null
var _weapon_icon: TextureRect = null
var _weapon_name: Label = null
var _ammo_label: Label = null
var _slots: WeaponSlots = null
var _weapon_box: VBoxContainer = null  # 左下角持有武器列表容器
var _drop_bar: ColorRect = null        # 长按丢弃进度条
var _player: Node = null
var _ammo_low := false                 # 低弹药警告状态

const WEAPON_ICON_W := 96.0

# 右上角击杀计数器预制场景
const KILL_COUNTER_SCENE := preload("res://ui/hud/kill_counter.tscn")

func _ready() -> void:
	layer = LAYER
	_build_kill_label()
	# 怀表 HUD 界面组件，布局于生命条与氧气条下方
	var watch := WatchHud.new()
	watch.position = Vector2(MARGIN.x, MARGIN.y + 100.0)
	add_child(watch)
	# 时间模式中心标志组件
	add_child(TimeSymbolHud.new())
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
			_build_weapon_slots(p)



func _process(_delta: float) -> void:
	# 刷新手持武器残弹数
	if _ammo_label == null:
		return
	var w: WeaponBase = null
	if _player != null and is_instance_valid(_player) and "weapons" in _player:
		w = _player.weapons.current_weapon()
	var show := w != null
	_ammo_label.visible = show
	var prog := w.reload_progress() if (show and w != null) else -1.0

	# 刷新丢弃按键长按进度条
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
	# 弹药量低于 25% 时切换为黄色警告色
	var low := w.mag_ammo <= int(ceilf(w.mag_size * 0.25))
	if low != _ammo_low:
		_ammo_low = low
		_ammo_label.add_theme_color_override("font_color",
				UiFactory.C_WARN if low else UiFactory.C_TEXT)
	_ammo_label.text = "%d/%d" % [w.mag_ammo, w.mag_size]


# 构建左下角武器栏
func _build_weapon_display(p: Node) -> void:
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
	# 容器高度随内容动态适应并向上生长
	wrap.offset_top = wrap.offset_bottom
	wrap.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(wrap)
	_weapon_wrap = wrap
	wrap.resized.connect(_place_weapon_slots)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	wrap.add_child(col)

	_weapon_box = col
	_drop_bar = ColorRect.new()
	_drop_bar.color = UiFactory.C_DANGER
	_drop_bar.custom_minimum_size = Vector2(WEAPON_ICON_W, 4)
	_drop_bar.size = Vector2(0, 4)
	_drop_bar.visible = false
	col.add_child(_drop_bar)

	p.weapons.weapon_changed.connect(_on_weapon_changed)
	p.weapons.inventory_changed.connect(_refresh_weapon_boxes)
	_refresh_weapon_boxes()


# 刷新左下角武器列表项
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
	var held_index := 0
	var cur_index: int = _player.weapons._current_index
	for e in _player.weapons.inventory.held:
		var t := int(e["type"])
		# 依据背包槽位下标匹配当前选中的手持武器
		var sel := held_index == cur_index
		var box := PanelContainer.new()
		var bs := StyleBoxFlat.new()
		bs.bg_color = Color(0, 0, 0, 0.28) if sel else Color(0, 0, 0, 0)
		bs.set_corner_radius_all(0)
		bs.content_margin_left = 8.0
		bs.content_margin_right = 8.0
		bs.content_margin_top = 4.0
		bs.content_margin_bottom = 4.0
		box.add_theme_stylebox_override("panel", bs)
		box.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		box.custom_minimum_size = Vector2(320, 0)
		_weapon_box.add_child(box)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 14)
		box.add_child(row)

		# 快捷键数字序号标签
		var key_lbl := Label.new()
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
		icon.custom_minimum_size = Vector2(72 if sel else 58, 46 if sel else 36)
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		icon.modulate = Color(1, 1, 1, 1) if sel else Color(0.45, 0.45, 0.50, 1.0)
		row.add_child(icon)

		if sel:
			_weapon_icon = icon
			var info := VBoxContainer.new()
			info.add_theme_constant_override("separation", 2)
			info.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(info)
			_weapon_name = Label.new()
			UiFactory.style_control(_weapon_name, WEAPON_FONT_SIZE)
			_weapon_name.add_theme_color_override("font_color", UiFactory.C_TEXT)
			var nm := WeaponRegistry.name_of(t)
			_weapon_name.text = nm if not nm.is_empty() else "空手"
			info.add_child(_weapon_name)
			_ammo_label = Label.new()
			UiFactory.style_control(_ammo_label, WEAPON_FONT_SIZE)
			_ammo_label.add_theme_color_override("font_color", UiFactory.C_TEXT)
			info.add_child(_ammo_label)
		held_index += 1
	_weapon_box.move_child(_drop_bar, _weapon_box.get_child_count() - 1)


var _weapon_wrap: PanelContainer = null
const WEAPON_SLOTS_GAP := 8.0


func _build_weapon_slots(p: Node) -> void:
	_slots = WeaponSlots.attach_to(self, p.weapons)
	_place_weapon_slots()
	_place_weapon_slots.call_deferred()


# 将容量网格对齐至武器面板上方
func _place_weapon_slots() -> void:
	if _slots == null or _weapon_wrap == null or not is_instance_valid(_weapon_wrap):
		return
	_slots.anchor_left = 0.0
	_slots.anchor_right = 0.0
	_slots.anchor_top = 0.0
	_slots.anchor_bottom = 0.0
	_slots.offset_left = MARGIN.x
	_slots.offset_right = MARGIN.x + WeaponSlots.PANEL_W
	_slots.offset_bottom = _weapon_wrap.position.y - WEAPON_SLOTS_GAP
	_slots.offset_top = _slots.offset_bottom - _slots.panel_h


func _on_weapon_changed(_type_id: int) -> void:
	_refresh_weapon_boxes()


# 构建分段式生命值条
func _build_segments(count: int) -> void:
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
			_kill_ghost(i)
			seg.modulate = Color.WHITE
			seg.visible = true
		else:
			seg.visible = false
	for i in range(max(cur, 0), _last_cur):
		_start_ghost(i)
	_last_cur = cur

# 构建氧气值状态条
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
		_fade_waterproof(0.0 if cur >= max else 1.0)


func _fade_waterproof(a: float) -> void:
	if _wp_tween != null and _wp_tween.is_valid():
		_wp_tween.kill()
	_wp_tween = create_tween()
	_wp_tween.set_parallel(true)
	for c in [_wp_bar, _wp_back, _wp_plate]:
		_wp_tween.tween_property(c, "modulate:a", a, 0.4)

# 扣血受击白闪与淡出动画
func _start_ghost(i: int) -> void:
	var seg := _segments[i]
	_kill_ghost(i)
	seg.visible = true
	var base := seg.color
	var tw := create_tween()
	for _b in range(2):
		tw.tween_property(seg, "color", Color.WHITE, 0.08)
		tw.tween_property(seg, "color", base, 0.08)
	tw.tween_property(seg, "modulate:a", 0.0, 0.2)
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

# 初始化右上角击杀计数器
func _build_kill_label() -> void:
	var wrap := KILL_COUNTER_SCENE.instantiate() as PanelContainer
	var sb := StyleBoxFlat.new()
	sb.bg_color = PLATE_COLOR
	sb.draw_center = false
	sb.set_corner_radius_all(0)
	sb.content_margin_left = 16.0
	sb.content_margin_right = 16.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	wrap.add_theme_stylebox_override("panel", sb)

	_kill_label = wrap.get_node("KillLabel") as Label
	_kill_label.text = "%03d" % _kills
	_kill_label.add_theme_color_override("font_color", KILL_COLOR)
	UiFactory.style_control(_kill_label, KILL_FONT_SIZE)
	call_deferred("add_child", wrap)

func _on_enemy_spawned(enemy: Node) -> void:
	if enemy.has_signal("died"):
		enemy.died.connect(_on_enemy_died)

func _on_enemy_died() -> void:
	_kills += 1
	_kill_label.text = "%03d" % _kills

