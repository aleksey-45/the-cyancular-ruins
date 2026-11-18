class_name CombatFeedback
extends CanvasLayer

const HIT_LIFE := 0.22
const KILL_LIFE := 1.25
const STREAK_RESET := 6.0
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

const OUTLINE := Color(0.05, 0.08, 0.12, 0.95)
const CENTER := Vector2(0.5, 0.5)

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
	var root := Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiFactory.cover(self, root)
	_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marker.draw.connect(_draw_hit)
	_marker.hide()
	UiFactory.cover(root, _marker)

	_kill_label.modulate.a = 0.0
	_kill_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_kill_label.grow_vertical = Control.GROW_DIRECTION_BOTH
	_kill_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_kill_label.bbcode_enabled = true
	_kill_label.scroll_active = false
	_kill_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_kill_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_kill_label.add_theme_color_override("default_color", Color(0.55, 0.95, 1))
	_kill_label.add_theme_color_override("font_outline_color", OUTLINE)
	_kill_label.add_theme_constant_override("outline_size", 16)
	for face in ["normal", "bold"]:
		_kill_label.add_theme_font_override(face + "_font", PixelFont.FONT)
		_kill_label.add_theme_font_size_override(face + "_font_size", 64)
	UiFactory.place(root, _kill_label, Rect2(-600, -166, 1200, 100), CENTER)

	_skull.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_skull.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_skull.grow_vertical = Control.GROW_DIRECTION_BOTH
	_skull.draw.connect(_draw_skull)
	_skull.hide()
	UiFactory.place(root, _skull, Rect2(-40, -40, 80, 80), CENTER)
	_streak_label = UiFactory.label("", 48, Color(1, 0.84, 0.43))
	_streak_label.modulate.a = 0.0
	_streak_label.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_streak_label.grow_vertical = Control.GROW_DIRECTION_BOTH
	_streak_label.add_theme_color_override("font_outline_color", OUTLINE)
	_streak_label.add_theme_constant_override("outline_size", 10)
	UiFactory.place(root, _streak_label, Rect2(44, -24, 256, 48), CENTER)

func show_hit() -> void:
	_hit_at = _now

func reset_streak() -> void:
	_streak = 0

func show_kill(who: String) -> void:
	_streak = 1 if _now - _kill_at > STREAK_RESET else _streak + 1
	_kill_at = _now
	_kill_label.text = "击杀 [color=#ffd76e]%s[/color]" % who.replace("[", "")
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
			var start := center + axis * (6.0 + 5.0 * _hit_progress)
			var end := start + axis * (10.0 - 3.0 * _hit_progress)
			_marker.draw_line(start, end, Color(0.05, 0.05, 0.05, 0.9 * (1.0 - _hit_progress)), 6.0)
			_marker.draw_line(start, end, Color(1, 1, 1, 1.0 - _hit_progress), 3.0)

func _draw_skull() -> void:
	var origin := (_skull.size - Vector2(64, 64)) * 0.5
	var dark := Color(0.07, 0.08, 0.11)
	for y in SKULL.size():
		for x in SKULL[y].length():
			var pixel: String = SKULL[y][x]
			var box := Rect2(origin + Vector2(x, y) * 8.0, Vector2(8, 8))
			match pixel:
				"#":
					_skull.draw_rect(box.grow(1.0), dark)
					_skull.draw_rect(box, Color(0.96, 0.96, 0.92))
				"o":
					_skull.draw_rect(box, dark)
