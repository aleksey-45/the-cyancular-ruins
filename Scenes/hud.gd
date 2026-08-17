class_name HUD
extends CanvasLayer

const LAYER := 129  # 在 post-process(128)之上,不受桶形/CRT/变灰影响
const MARGIN := Vector2(24, 24)
const SEG_W := 5        # 每根竖条宽
const SEG_H := 30       # 竖条高
const SEG_GAP := 1      # 竖条之间的间隔
const COLOR_NORMAL := Color(0.35, 0.85, 0.9)  # 青色
const COLOR_LOW := Color(0.8, 0.45, 0.4)      # 血量 <25% 变红
const LOW_RATIO := 0.25

var _segments: Array[ColorRect] = []
var _ghost_tweens: Array[Tween] = []  # 与 _segments 并行:掉血段的淡出 tween
var _last_cur := 0

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

# 掉血段效果:变白,停顿片刻后淡出消失。
func _start_ghost(i: int) -> void:
	var seg := _segments[i]
	_kill_ghost(i)
	seg.color = Color.WHITE
	seg.modulate = Color.WHITE
	seg.visible = true
	var tw := create_tween()
	tw.tween_interval(0.2)                          # 白闪停顿
	# 闪烁两下:每次先隐藏再显示
	for _b in range(2):
		tw.tween_property(seg, "modulate:a", 0.0, 0.08)  # 隐
		tw.tween_property(seg, "modulate:a", 1.0, 0.08)  # 显
	tw.tween_property(seg, "modulate:a", 0.0, 0.2)   # 最后淡出
	tw.tween_callback(func():
		seg.visible = false
		seg.modulate = Color.WHITE
	)
	_ghost_tweens[i] = tw

func _kill_ghost(i: int) -> void:
	if _ghost_tweens[i] != null and _ghost_tweens[i].is_valid():
		_ghost_tweens[i].kill()
		_ghost_tweens[i] = null
