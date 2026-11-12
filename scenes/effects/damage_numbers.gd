class_name DamageNumbers
extends Node

const LIFETIME := 0.6
const FADE_TIME := 0.3

var _anchor: Node2D
var _pending: Dictionary[int, Dictionary] = {}

func _init(anchor: Node2D) -> void:
	_anchor = anchor

func add_hit(victim: Node2D, damage: int) -> void:
	if damage <= 0:
		return
	if _pending.is_empty():
		_show_pending.call_deferred()
	# 同批散弹命中同一目标时合成一个数字。
	var id := victim.get_instance_id()
	if _pending.has(id):
		_pending[id]["damage"] += damage
	else:
		_pending[id] = {"at": victim.global_position, "damage": damage, "own": victim == _anchor}

func _show_pending() -> void:
	for hit: Dictionary in _pending.values():
		var color := UiFactory.C_DANGER if hit["own"] else UiFactory.C_WARN
		_float_number(hit["at"], hit["damage"], color)
	_pending.clear()

func _float_number(at: Vector2, damage: int, color: Color) -> void:
	var label := UiFactory.label(str(damage), 32, color)
	label.z_index = 10
	label.add_theme_color_override("font_outline_color", UiFactory.C_BG)
	label.add_theme_constant_override("outline_size", 6)
	add_child(label)
	var offset := Vector2(-label.get_combined_minimum_size().x * 0.5, -90.0)
	var place := func(rise: float) -> void:
		var shown := GridPathfinder.anchor_to_nearest(at, _anchor.global_position, _anchor.terrain.map_size)
		label.position = shown + offset + Vector2.UP * rise
	place.call(0.0)
	var tween := label.create_tween().set_parallel()
	tween.tween_method(place, 0.0, 56.0, LIFETIME).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "modulate:a", 0.0, FADE_TIME).set_delay(LIFETIME - FADE_TIME)
	tween.chain().tween_callback(label.queue_free)
