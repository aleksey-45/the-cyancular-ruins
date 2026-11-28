class_name PostProcess
extends CanvasLayer

const LAYER := 128  # 图层顺序使 HUD 保持在后期处理效果上方。

@export var world_viewport: SubViewport = null
@export var barrel_strength: float = 0.4

var _mat: ShaderMaterial = null
const LOW_HP_THRESHOLD := 0.35

class State:
	var barrel := false
	var hit := 0.0
	var low_hp := 0.0
	var heartbeat_cd := 0.0
	var coverage := 0.0
	var dim := 0.0

	func advance(frame: MatchFrame, world_delta: float, ui_delta: float, sounds: Array) -> Dictionary:
		var clock := frame.clock
		coverage = move_toward(coverage, 1.0 if clock and clock.rewind else 0.0, world_delta / 0.2)
		dim = move_toward(dim, 1.0 if clock and clock.haste else 0.0, world_delta / 0.1)
		hit = maxf(0.0, hit - ui_delta * 4.0)
		var target := clampf(1.0 - float(frame.health) / frame.max_health / LOW_HP_THRESHOLD, 0.0, 1.0)
		low_hp = move_toward(low_hp, target, ui_delta * 2.0)
		heartbeat_cd = maxf(0.0, heartbeat_cd - ui_delta)
		if low_hp >= LOW_HP_THRESHOLD * 0.999 and heartbeat_cd == 0.0 and world_delta > 0.0:
			sounds.append(["heartbeat", -6.0])
			heartbeat_cd = lerpf(1.2, 0.6, low_hp)
		return {"barrel_enabled": barrel, "desat": float(frame.downed), "hit_red": hit, "low_hp": low_hp,
			"rewind_film": coverage,
			"loan_depth": clock.loan_depth if clock else 0.0, "haste_dim": dim}

# 裁切以世界视口的中心为基准，宽高比例分别由外层视口与世界视口的尺寸决定。
static func crop_scale(win_size: Vector2, world_vp_size: Vector2) -> Vector2:
	return Vector2(win_size.x / world_vp_size.x, win_size.y / world_vp_size.y)


func _ready() -> void:
	layer = LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS

	var rect := ColorRect.new()
	rect.name = "ShaderRect"
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat = ShaderMaterial.new()
	_mat.shader = preload("res://core/present/post_process.gdshader")
	_mat.set_shader_parameter("barrel_enabled", false)
	_mat.set_shader_parameter("barrel_strength", barrel_strength)
	_mat.set_shader_parameter("screen_tex", world_viewport.get_texture())
	_mat.set_shader_parameter("viewport_size", Vector2(world_viewport.size))

	var vsize := get_viewport().get_visible_rect().size
	_mat.set_shader_parameter("crop_scale", crop_scale(vsize, world_viewport.size))

	rect.material = _mat
	add_child(rect)


func display(values: Dictionary) -> void:
	for key: String in values:
		_mat.set_shader_parameter(key, values[key])

func set_intro_rewind(elapsed: float, strength: float) -> void:
	_mat.set_shader_parameter(&"intro_rewind", Vector2(elapsed, strength))
