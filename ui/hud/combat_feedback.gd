class_name CombatFeedback
extends CanvasLayer

# 战斗反馈，包括命中标记、击杀播报和连杀计数。
# 动画和连杀计时在对局暂停时也继续更新。

const HIT_LIFE := 0.22
const KILL_LIFE := 1.25
const STREAK_RESET := 6.0

# 骷髅像素图中，# 表示骨白，o 表示眼鼻暗部，点表示透明。
const SKULL := [
	"..####..",
	".######.",
	".######.",
	".#o##o#.",
	".######.",
	"..####..",
	"..####..",
	"..o##o..",
]
const SKULL_PX := 8.0

# 命中标记由四条斜线组成。动画播放时，斜线缩短并向外移动。
const HIT_GAP := 6.0
const HIT_SPREAD := 5.0
const HIT_SEG := 10.0
const HIT_SEG_SHRINK := 3.0
const HIT_OUTLINE_W := 6.0
const HIT_CORE_W := 3.0

const KILL_FONT := UiDesign.T_H2 * 2   # 64
const STREAK_FONT := UiDesign.T_H1     # 48

const KILL_OUTLINE := UiDesign.SP_4    # 16
const STREAK_OUTLINE := UiDesign.SP_3

var _root: Control
var _marker := Control.new()
var _kill_label := RichTextLabel.new()
var _streak_label: Label
var _skull := Control.new()
var _now := 0.0
var _hit_at := -HIT_LIFE
var _kill_at := -STREAK_RESET
var _streak := 0
var _hit_progress := 1.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 131

	_root = Control.new()
	_root.name = "Root"
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root)

	_marker.name = "HitMarker"
	_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marker.draw.connect(_draw_hit)
	_marker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_marker.hide()
	_root.add_child(_marker)

	# 击杀播报放在屏幕中心上方，避免盖住准星。
	var center := CenterContainer.new()
	center.name = "Center"
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.offset_top = -UiDesign.SP_9
	center.offset_bottom = -UiDesign.SP_9
	_root.add_child(center)
	var column := VBoxContainer.new()
	column.name = "Column"
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", UiDesign.SP_5)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(column)

	_kill_label.name = "KillLabel"
	_kill_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_kill_label.bbcode_enabled = true
	_kill_label.scroll_active = false
	_kill_label.fit_content = true
	_kill_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_kill_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_kill_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_kill_label.add_theme_color_override("default_color", UiDesign.C_ACCENT)
	_kill_label.add_theme_color_override("font_outline_color", UiDesign.C_BG)
	_kill_label.add_theme_constant_override("outline_size", KILL_OUTLINE)
	var font := UiDesign.pixel_font()
	if font != null:
		for face in ["normal", "bold"]:
			_kill_label.add_theme_font_override(face + "_font", font)
			_kill_label.add_theme_font_size_override(face + "_font_size", KILL_FONT)
	_kill_label.modulate.a = 0.0
	column.add_child(_kill_label)

	var row := HBoxContainer.new()
	row.name = "KillRow"
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", UiDesign.SP_1)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(row)

	_skull.name = "SkullSlot"
	_skull.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_skull.custom_minimum_size = Vector2(UiDesign.SP_10, UiDesign.SP_10)
	_skull.draw.connect(_draw_skull)
	_skull.hide()
	row.add_child(_skull)

	_streak_label = UiDesign.label("", STREAK_FONT, UiDesign.C_GOLD)
	_streak_label.name = "StreakLabel"
	_streak_label.add_theme_color_override("font_outline_color", UiDesign.C_BG)
	_streak_label.add_theme_constant_override("outline_size", STREAK_OUTLINE)
	_streak_label.modulate.a = 0.0
	row.add_child(_streak_label)


func show_hit() -> void:
	_hit_at = _now


func reset_streak() -> void:
	_streak = 0


func show_kill(who: String) -> void:
	_streak = 1 if _now - _kill_at > STREAK_RESET else _streak + 1
	_kill_at = _now
	# 去掉昵称中的左方括号，防止被解释为 BBCode 标签。
	_kill_label.text = "击杀 [color=#%s]%s[/color]" % [
			UiDesign.C_GOLD.to_html(false), who.replace("[", "")]
	_streak_label.text = "x%d" % _streak
	Sfx.play("kill")


func _process(delta: float) -> void:
	_now += delta
	_hit_progress = minf(1.0, (_now - _hit_at) / HIT_LIFE)
	_marker.visible = _hit_progress < 1.0
	if _marker.visible:
		_marker.queue_redraw()
	var age := _now - _kill_at
	var alpha := clampf(minf(age / 0.08, (KILL_LIFE - age) / 0.35), 0.0, 1.0)
	_skull.visible = alpha > 0.0
	var scale_factor := 1.0 + 0.22 * maxf(0.0, 1.0 - age / 0.14)
	for item: Control in [_kill_label, _streak_label, _skull]:
		item.modulate.a = alpha
		item.pivot_offset = item.size * 0.5
		item.scale = Vector2.ONE * scale_factor


func _draw_hit() -> void:
	var center := _marker.size * 0.5
	for x in [-1, 1]:
		for y in [-1, 1]:
			var axis := Vector2(x, y).normalized()
			var start := center + axis * (HIT_GAP + HIT_SPREAD * _hit_progress)
			var end := start + axis * (HIT_SEG - HIT_SEG_SHRINK * _hit_progress)
			_marker.draw_line(start, end,
					Color(UiDesign.C_BG, 0.9 * (1.0 - _hit_progress)), HIT_OUTLINE_W)
			_marker.draw_line(start, end,
					Color(UiDesign.C_WHITE, 1.0 - _hit_progress), HIT_CORE_W)


func _draw_skull() -> void:
	var origin := (_skull.size - Vector2(64, 64)) * 0.5
	for y in SKULL.size():
		for x in SKULL[y].length():
			var pixel: String = SKULL[y][x]
			var box := Rect2(origin + Vector2(x, y) * SKULL_PX, Vector2(SKULL_PX, SKULL_PX))
			match pixel:
				"#":
					_skull.draw_rect(box.grow(1.0), UiDesign.C_BG)
					_skull.draw_rect(box, UiDesign.C_TEXT)
				"o":
					_skull.draw_rect(box, UiDesign.C_BG)
