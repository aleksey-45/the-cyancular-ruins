class_name HUD
extends CanvasLayer

const LAYER := 129  # 在 post-process(128)之上,不受桶形/CRT/变灰影响
const MARGIN := Vector2(24, 24)
const SEG_W := 5        # 每根竖条宽
const SEG_H := 18       # 竖条高
const SEG_GAP := 2      # 竖条之间的间隔
const COLOR_NORMAL := Color(0.25, 0.85, 0.9)  # 青色
const COLOR_LOW := Color(0.9, 0.25, 0.2)      # 血量 <25% 变红
const LOW_RATIO := 0.25

var _segments: Array[ColorRect] = []

func _ready() -> void:
	layer = LAYER
	var p := get_tree().get_first_node_in_group("player")
	if p != null and p.has_signal("hp_changed"):
		_build_segments(p.max_hp)
		p.hp_changed.connect(_on_hp)
		_on_hp(p.hp, p.max_hp)

# 每个 HP 一根竖条,按最大血量排成一排,竖条之间留一点间隔;无边框。
func _build_segments(count: int) -> void:
	for i in range(count):
		var seg := ColorRect.new()
		seg.position = Vector2(MARGIN.x + i * (SEG_W + SEG_GAP), MARGIN.y)
		seg.size = Vector2(SEG_W, SEG_H)
		seg.color = COLOR_NORMAL
		add_child(seg)
		_segments.append(seg)

func _on_hp(cur: int, max_hp: int) -> void:
	var ratio := float(cur) / float(max(1, max_hp))
	var color := COLOR_LOW if ratio < LOW_RATIO else COLOR_NORMAL
	for i in _segments.size():
		_segments[i].visible = i < cur
		_segments[i].color = color
