class_name WaterSurfaceBatch
extends Node2D

# 水面单格伸缩合批:所有水面格在一个 canvas item 里绘制(1 个 draw call 替代 N 个 Sprite),
# 每格底部锚定、按相位 scale.y 伸缩,画面与逐 Sprite 完全一致。不改变视觉效果,只省绘制开销。
# cells 元素:{"pos": Vector2(格底中心), "phase": float}。

var _cells: Array = []
var _tex: Texture2D = null
var _ts := 64


func setup(cells: Array, tex: Texture2D, ts: int) -> void:
	_cells = cells
	_tex = tex
	_ts = ts


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if _tex == null or _cells.is_empty():
		return
	var t := Time.get_ticks_msec() / 1000.0
	for c in _cells:
		var phase := sin(t * GameParameters.water_sway_speed + c.phase)
		var s := 1.0 + phase * (GameParameters.water_sway_amp / _ts)
		# 以格底中心为原点、scale.y=s:矩形 (-ts/2, -ts, ts, ts) 顶部缩放、底部固定在原点
		draw_set_transform(c.pos, 0.0, Vector2(1.0, s))
		draw_texture_rect(_tex, Rect2(-_ts * 0.5, -_ts, _ts, _ts), false)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
