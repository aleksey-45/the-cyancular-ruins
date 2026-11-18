class_name Hud
extends CanvasLayer

const MARGIN := Vector2(24, 24)
const FONT_SIZE := 32
const WEAPON_ICON_W := 96.0

var _kill_label: Label
var _ammo_label: Label
var _ammo_low := false
var _slots: WeaponSlots
var _vitals: Vitals
var _weapon_box: VBoxContainer
var _drop_bar: ColorRect
var _layout := PackedInt32Array()

func _ready() -> void:
	layer = 129
	_build_kill_label()
	_vitals = Vitals.new()
	add_child(_vitals)
	_build_weapon_display()

func present(frame: MatchFrame, delta: float) -> void:
	_vitals.present(frame, delta)
	_kill_label.text = "%03d" % frame.kills
	_update_weapon_display(frame.inventory)
	_drop_bar.visible = frame.drop_progress > 0.0
	if _drop_bar.visible:
		_drop_bar.size.x = WEAPON_ICON_W * frame.drop_progress
	if _ammo_label == null:
		return
	_ammo_label.visible = frame.magazine > 0
	if _ammo_label.visible:
		var low := frame.ammo <= ceili(frame.magazine * 0.25)
		if low != _ammo_low:
			_ammo_low = low
			_ammo_label.add_theme_color_override("font_color", UiFactory.C_WARN if low else UiFactory.C_TEXT)
		_ammo_label.text = "%d/%d" % [frame.ammo, frame.magazine]

func _build_weapon_display() -> void:
	var stack := VBoxContainer.new()
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_theme_constant_override("separation", 8)
	stack.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	stack.offset_left = MARGIN.x
	stack.offset_right = MARGIN.x + 344
	stack.offset_bottom = -MARGIN.y
	stack.offset_top = -MARGIN.y
	stack.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(stack)
	_slots = WeaponSlots.new()
	_slots.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	stack.add_child(_slots)

	var wrap := PanelContainer.new()
	wrap.add_theme_stylebox_override("panel", UiFactory.plate(UiFactory.C_PLATE, Vector2(12, 8)))
	stack.add_child(wrap)
	_weapon_box = VBoxContainer.new()
	_weapon_box.add_theme_constant_override("separation", 6)
	wrap.add_child(_weapon_box)
	_drop_bar = ColorRect.new()
	_drop_bar.color = UiFactory.C_DANGER
	_drop_bar.custom_minimum_size = Vector2(WEAPON_ICON_W, 4)
	_drop_bar.hide()
	_weapon_box.add_child(_drop_bar)

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
		box.add_theme_stylebox_override("panel", UiFactory.plate(Color(0, 0, 0, 0.28 if selected else 0.0), Vector2(8, 4)))
		box.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		box.custom_minimum_size.x = 320
		_weapon_box.add_child(box)

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 14)
		box.add_child(row)
		var key := UiFactory.label(str(i + 1), FONT_SIZE, UiFactory.C_TEXT if selected else UiFactory.C_TEXT_DIM)
		key.custom_minimum_size.x = 48
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
			icon.modulate = Color(0.45, 0.45, 0.50)
		row.add_child(icon)

		if selected:
			var info := VBoxContainer.new()
			info.add_theme_constant_override("separation", 2)
			info.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(info)
			info.add_child(UiFactory.label(WeaponRegistry.name_of(type_id), FONT_SIZE, UiFactory.C_TEXT))
			_ammo_label = UiFactory.label("", FONT_SIZE, UiFactory.C_TEXT)
			info.add_child(_ammo_label)
	_weapon_box.move_child(_drop_bar, -1)

func _build_kill_label() -> void:
	var wrap := PanelContainer.new()
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrap.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	var plate := UiFactory.plate(UiFactory.C_PLATE, Vector2(16, 6))
	plate.draw_center = false
	wrap.add_theme_stylebox_override("panel", plate)
	_kill_label = UiFactory.label("000", 48, UiFactory.C_ACCENT)
	wrap.add_child(_kill_label)
	UiFactory.place(self, wrap, Rect2(-32, 16, 0, 0), Vector2(1, 0))


class Vitals extends Node2D:
	const HP_SIZE := Vector2(5, 32)
	const HP_STEP := 6.0
	const HP_NORMAL := Color(0.35, 0.85, 0.9)
	const HP_LOW := Color(0.9, 0.4, 0.4)
	const PAD := Vector2(6, 5)
	const OXYGEN_POS := Vector2(0, 50)
	const OXYGEN_COLOR := Color(0.45, 0.72, 1.0)
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
		position = Hud.MARGIN

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
		var width := _max_hp * HP_STEP - 1
		draw_rect(Rect2(-PAD, Vector2(width, HP_SIZE.y) + PAD * 2), UiFactory.C_PLATE)
		var health_color := HP_LOW if _hp < _max_hp * 0.25 else HP_NORMAL
		# 刚扣除的生命格先以白色闪烁提示受伤，再逐渐变透明。
		var flash := 1.0 - absf(fposmod(_hit_age, 0.16) / 0.08 - 1.0) if _hit_age < HIT_FLASH else 0.0
		var ghost := health_color.lerp(Color.WHITE, flash)
		ghost.a = 1.0 - clampf((_hit_age - HIT_FLASH) / HIT_FADE, 0.0, 1.0)
		for i in maxi(_hp, _ghost_end):
			var color := health_color if i < _hp else ghost
			draw_rect(Rect2(Vector2(i * HP_STEP, 0), HP_SIZE), color)
		if oxygen_alpha > 0.0:
			var size := Vector2(18 * _max_oxygen, 10)
			draw_rect(Rect2(OXYGEN_POS - PAD, size + PAD * 2), Color(UiFactory.C_PLATE, UiFactory.C_PLATE.a * oxygen_alpha))
			draw_rect(Rect2(OXYGEN_POS, size), Color(1, 1, 1, 0.16 * oxygen_alpha))
			draw_rect(Rect2(OXYGEN_POS, Vector2(18 * _oxygen, size.y)), Color(OXYGEN_COLOR, oxygen_alpha))
