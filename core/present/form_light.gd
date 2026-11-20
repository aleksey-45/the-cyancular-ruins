class_name FormLight
extends RefCounted

# P3 兼容桩:siri 的 WorldCanvas 是自绘管线,尚未接入逐精灵的形体光材质。
# 接口与 main 保持同形,PostProcess 可以照常调用;P4 再补真正的 form_light 材质。

static func set_boost(_v: float) -> void:
	pass


static func set_steps(_v: float) -> void:
	pass


static func set_dither(_v: float) -> void:
	pass


static func set_bulge(_v: float) -> void:
	pass


static func set_edge(_lo: float, _hi: float) -> void:
	pass


static func push(_sun_dir: Vector2, _gain: float) -> void:
	pass
