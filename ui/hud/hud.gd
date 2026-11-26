class_name Hud
extends CanvasLayer

# 单人和联机共用的玩家 HUD。HUD 绘制在后期处理层上方，避免文字和图标受畸变和时间技能滤镜影响。
const LAYER := 129

const MARGIN := UiDesign.MARGIN
const FONT_SIZE := UiDesign.T_H2

const WEAPON_ICON_W := 96.0              # 左下角剪影/丢弃进度条宽度（设计像素档）。
const WEAPON_ROW_W := 320.0              # 每把武器一行方框的固定宽。
const WEAPON_PANEL_W := WEAPON_ROW_W + UiDesign.SP_3 * 2.0

var _kill_count: Label
var _ammo_label: Label
var _ammo_low := false
var _slots: WeaponSlots
var _vitals: Vitals
var _weapon_box: VBoxContainer
var _drop_bar: ColorRect
var _layout := PackedInt32Array()

func _ready() -> void:
	layer = LAYER
	_build_kill_counter()
	_vitals = Vitals.new()
	add_child(_vitals)
	_build_weapon_display()

func present(frame: MatchFrame, delta: float) -> void:
	_vitals.present(frame, delta)
	_kill_count.text = "%03d" % frame.kills
	_update_weapon_display(frame.inventory)
	var dropping := frame.drop_progress > 0.0
	_drop_bar.visible = dropping
	if dropping:
		_drop_bar.custom_minimum_size.x = WEAPON_ICON_W * clampf(frame.drop_progress, 0.0, 1.0)
	if _ammo_label == null:
		return
	_ammo_label.visible = frame.magazine > 0
	if _ammo_label.visible:
		var low := frame.ammo <= ceili(frame.magazine * 0.25)
		if low != _ammo_low:
			_ammo_low = low
			_ammo_label.add_theme_color_override("font_color",
					UiDesign.C_WARN if low else UiDesign.C_TEXT)
		_ammo_label.text = "%d/%d" % [frame.ammo, frame.magazine]

func _build_weapon_display() -> void:
	var stack := VBoxContainer.new()
	stack.name = "WeaponStack"
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_theme_constant_override("separation", UiDesign.SP_2)
	stack.anchor_left = 0.0
	stack.anchor_top = 1.0
	stack.anchor_right = 0.0
	stack.anchor_bottom = 1.0
	stack.offset_left = MARGIN
	stack.offset_right = MARGIN + WEAPON_PANEL_W
	stack.offset_top = -MARGIN
	stack.offset_bottom = -MARGIN
	stack.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(stack)

	_slots = WeaponSlots.new()
	_slots.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	stack.add_child(_slots)

	var wrap := PanelContainer.new()
	wrap.name = "WeaponPanel"
	UiDesign.hud_plate(wrap, UiDesign.SP_3, UiDesign.SP_2)
	wrap.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	wrap.custom_minimum_size.x = WEAPON_PANEL_W
	stack.add_child(wrap)

	_weapon_box = VBoxContainer.new()
	_weapon_box.add_theme_constant_override("separation", UiDesign.SP_2)
	wrap.add_child(_weapon_box)

	_drop_bar = ColorRect.new()
	_drop_bar.color = UiDesign.C_DANGER
	_drop_bar.custom_minimum_size = Vector2(WEAPON_ICON_W, UiDesign.SP_1)
	_drop_bar.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_drop_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_drop_bar.hide()
	_weapon_box.add_child(_drop_bar)

# 背包布局变化时才重建武器栏。
func _update_weapon_display(layout: PackedInt32Array) -> void:
	if layout == _layout:
		return
	_layout = layout
	_slots.show_inventory(layout)
	for child in _weapon_box.get_children():
		if child != _drop_bar:
			_weapon_box.remove_child(child)
			child.queue_free()
	_ammo_label = null
	_ammo_low = false
	for slot in range(2, layout.size(), 2):
		var i := (slot - 2) / 2
		var type_id := layout[slot]
		var selected := i == layout[0]
		var box := PanelContainer.new()
		UiDesign.hud_plate(box, UiDesign.SP_2, UiDesign.SP_1, true,
				UiDesign.C_PLATE_DEEP if selected else UiDesign.C_TRANSPARENT)
		box.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		box.custom_minimum_size.x = WEAPON_ROW_W
		_weapon_box.add_child(box)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", UiDesign.SP_3)
		box.add_child(row)

		# 武器栏序号对应快捷键 1–4。
		var key := UiDesign.label(str(i + 1), FONT_SIZE,
				UiDesign.C_TEXT if selected else UiDesign.C_TEXT_DIM)
		key.custom_minimum_size.x = UiDesign.SP_8
		key.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		key.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(key)

		var icon := TextureRect.new()
		icon.texture = WeaponIcons.silhouette(type_id)
		icon.custom_minimum_size = Vector2(72, 46) if selected else Vector2(58, 36)
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		if not selected:
			icon.modulate = UiDesign.C_TEXT_DIM
		row.add_child(icon)

		if selected:
			var info := VBoxContainer.new()
			info.add_theme_constant_override("separation", UiDesign.SP_1)
			info.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(info)
			info.add_child(UiDesign.label(WeaponRegistry.name_of(type_id), FONT_SIZE, UiDesign.C_TEXT))
			_ammo_label = UiDesign.label("", FONT_SIZE, UiDesign.C_TEXT)
			info.add_child(_ammo_label)
	_weapon_box.move_child(_drop_bar, -1)

func _build_kill_counter() -> void:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	UiDesign.hud_plate(panel, UiDesign.SP_4, UiDesign.SP_2, false)
	_kill_count = UiDesign.label("000", UiDesign.T_H1, UiDesign.C_ACCENT)
	panel.add_child(_kill_count)
	UiDesign.place(self, panel, Rect2(-UiDesign.SP_6, UiDesign.SP_4, 0, 0), Vector2.RIGHT)


class Vitals extends Control:
	const HP_SIZE := Vector2(5, 32)
	const HP_STEP := 6.0
	const LOW_RATIO := 0.25
	const PAD := Vector2(6, 5)
	const OXYGEN_POS := Vector2(0, 50)
	const OXYGEN_W := 18.0
	const OXYGEN_H := 10.0
	const OXYGEN_BACK_ALPHA := 0.16
	const HIT_FLASH := 0.32
	const HIT_FADE := 0.2
	var _hp := 0
	var _max_hp := 0
	var _ghost_end := 0
	var _hit_age := 0.0
	var _oxygen := 0
	var _max_oxygen := 0
	var oxygen_alpha := 0.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		anchor_left = 0.0
		anchor_top = 0.0
		anchor_right = 0.0
		anchor_bottom = 0.0
		offset_left = Hud.MARGIN
		offset_top = Hud.MARGIN
		offset_right = Hud.MARGIN
		offset_bottom = Hud.MARGIN

	func present(frame: MatchFrame, delta: float) -> void:
		var hp := clampi(frame.health, 0, frame.max_health)
		if hp != _hp or frame.max_health != _max_hp:
			_ghost_end = mini(_hp, frame.max_health)
			_hit_age = 0.0
			_hp = hp
			_max_hp = frame.max_health
			queue_redraw()
		if _ghost_end > _hp:
			_hit_age += delta
			if _hit_age >= HIT_FLASH + HIT_FADE:
				_ghost_end = _hp
			queue_redraw()
		var oxygen := frame.oxygen
		var capacity := frame.max_oxygen
		var alpha := move_toward(oxygen_alpha, 1.0 if oxygen < capacity else 0.0, delta / 0.4)
		if alpha != oxygen_alpha or oxygen != _oxygen or capacity != _max_oxygen:
			oxygen_alpha = alpha
			_oxygen = oxygen
			_max_oxygen = capacity
			queue_redraw()

	func _draw() -> void:
		var width := _max_hp * HP_STEP - 1.0
		draw_rect(Rect2(-PAD, Vector2(width, HP_SIZE.y) + PAD * 2.0), UiDesign.C_PLATE)
		var health_color := UiDesign.C_DANGER if _hp < _max_hp * LOW_RATIO else UiDesign.C_ACCENT
		# 刚扣除的生命格先以白色闪烁提示受伤，再逐渐变透明。
		var flash := 1.0 - absf(fposmod(_hit_age, 0.16) / 0.08 - 1.0) if _hit_age < HIT_FLASH else 0.0
		var ghost := health_color.lerp(Color.WHITE, flash)
		ghost.a = 1.0 - clampf((_hit_age - HIT_FLASH) / HIT_FADE, 0.0, 1.0)
		for i in maxi(_hp, _ghost_end):
			var color := health_color if i < _hp else ghost
			draw_rect(Rect2(Vector2(i * HP_STEP, 0.0), HP_SIZE), color)
		if oxygen_alpha > 0.0:
			var size := Vector2(OXYGEN_W * _max_oxygen, OXYGEN_H)
			draw_rect(Rect2(OXYGEN_POS - PAD, size + PAD * 2.0),
					Color(UiDesign.C_PLATE, UiDesign.C_PLATE.a * oxygen_alpha))
			draw_rect(Rect2(OXYGEN_POS, size),
					Color(UiDesign.C_WHITE, OXYGEN_BACK_ALPHA * oxygen_alpha))
			draw_rect(Rect2(OXYGEN_POS, Vector2(OXYGEN_W * _oxygen, size.y)),
					Color(UiDesign.C_SLOT_FILLED, oxygen_alpha))
