class_name WaterSurfaceCell
extends Sprite2D

# 水面单格伸缩:整格以「格底」为锚做垂直 scale(顶部按 -phase*amp 伸缩,底端固定),相位逐格错开。
# 用 Sprite 而非 TileMap shader(TileMapLayer 的顶点位移在 Godot 里不可靠),_process 直接改 scale.y 必然生效。
# 布局:centered=true,position=格底中心,offset=(0,-32) → 底部是缩放锚点。

var phase_offset: float = 0.0

func _process(_delta: float) -> void:
	var phase := sin(Time.get_ticks_msec() / 1000.0 * GameParameters.water_sway_speed + phase_offset)
	scale.y = 1.0 + phase * (GameParameters.water_sway_amp / 64.0)
