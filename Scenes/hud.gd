class_name HUD
extends CanvasLayer

const LAYER := 129  # 在 post-process(128)之上,不受桶形/CRT/变灰影响
const BAR_W: int = 220
const BAR_H: int = 18
const MARGIN: int = 24

var _fill: ColorRect

func _ready() -> void:
	layer = LAYER
	var bg := ColorRect.new()
	bg.position = Vector2(MARGIN, MARGIN)
	bg.size = Vector2(BAR_W, BAR_H)
	bg.color = Color(0.0, 0.0, 0.0, 0.55)
	add_child(bg)
	_fill = ColorRect.new()
	_fill.position = Vector2(MARGIN + 2, MARGIN + 2)
	_fill.size = Vector2(BAR_W - 4, BAR_H - 4)
	_fill.color = Color(0.35, 0.85, 0.35)
	add_child(_fill)
	var p := get_tree().get_first_node_in_group("player")
	if p != null and p.has_signal("hp_changed"):
		p.hp_changed.connect(_on_hp)
		_on_hp(p.hp, p.max_hp)

func _on_hp(cur: int, max_hp: int) -> void:
	var ratio := float(cur) / float(max(1, max_hp))
	_fill.size.x = (BAR_W - 4) * ratio
	_fill.color = Color(0.85, 0.25, 0.2) if ratio < 0.3 else Color(0.35, 0.85, 0.35)
