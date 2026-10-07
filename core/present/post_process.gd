class_name PostProcess
extends CanvasLayer

const LAYER := 128  # 世界后处理图层，层级低于 HUD（129），避免遮挡界面

@export var world_viewport: SubViewport = null
@export var barrel_strength: float = 0.4

var _mat: ShaderMaterial = null
var _hit_red: float = 0.0   # 受击红闪当前强度（每帧衰减，参见 flash_hit）
var _film: float = 0.0      # 回溯底片化效果强度（Level0 逐帧更新）
var _loan: float = 0.0      # 透支状态视效强度
var _haste: float = 0.0     # 加速状态视效强度

# 窗口尺寸 / 世界视口尺寸换算：将窗口坐标映射至世界视口的中心裁剪区域。
# 武器瞄准坐标转换与着色器采样均统一调用此方法。
static func crop_scale(win_size: Vector2, world_vp_size: Vector2) -> Vector2:
	return Vector2(win_size.x / world_vp_size.x, win_size.y / world_vp_size.y)


func _ready() -> void:
	add_to_group("post_process")
	layer = LAYER
	# 游戏暂停（暂停菜单暂停场景树）时本层仍持续更新：受击红闪在 _process 中逐帧衰减，
	# 保持 PROCESS_MODE_ALWAYS 避免暂停时屏幕残留受击红色。
	process_mode = Node.PROCESS_MODE_ALWAYS

	if world_viewport == null:
		push_error("PostProcess: no world viewport assigned!")
		return

	var rect := ColorRect.new()
	rect.name = "ShaderRect"
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	call_deferred("add_child", rect)

	var shader := load("res://core/present/post_process.gdshader") as Shader
	if shader == null:
		push_error("PostProcess: failed to load shader!")
		return
	_mat = ShaderMaterial.new()
	_mat.shader = shader
	_mat.set_shader_parameter("barrel_enabled", true)
	_mat.set_shader_parameter("barrel_strength", barrel_strength)
	_mat.set_shader_parameter("screen_tex", world_viewport.get_texture())

	# crop_scale = 窗口 / 世界视口，让 shader 只在世界纹理的中心窗口区采样。
	var vsize := get_viewport().get_visible_rect().size
	_mat.set_shader_parameter("crop_scale", crop_scale(vsize, world_viewport.size))

	rect.material = _mat


func _unhandled_input(event: InputEvent) -> void:
	if _mat == null:
		return
	if event.is_action_pressed("toggle_barrel"):
		var cur = _mat.get_shader_parameter("barrel_enabled")
		_mat.set_shader_parameter("barrel_enabled", not cur)
		get_viewport().set_input_as_handled()

func set_downed(v: bool) -> void:
	if _mat:
		_mat.set_shader_parameter("desat", 1.0 if v else 0.0)


# 受击红闪:strength 0-1(伤害越大越红),约 0.25s 衰减完。
# combat.take_hit(单机)与 PvP hit_event→take_hit 都走这里,不用重复接线。
func flash_hit(strength: float = 1.0) -> void:
	_hit_red = maxf(_hit_red, clampf(strength, 0.0, 1.0))

## 时间玩法三效果统一入口(Level0 每帧调;单机才有,常态全 0 = 无痕)
func set_time_effects(film: float, loan: float, haste: float) -> void:
	_film = clampf(film, 0.0, 1.0)
	_loan = clampf(loan, 0.0, 1.0)
	_haste = clampf(haste, 0.0, 1.0)
	if _mat == null:
		return
	_mat.set_shader_parameter("rewind_film", _film)
	_mat.set_shader_parameter("loan_depth", _loan)
	_mat.set_shader_parameter("haste_dim", _haste)
	if world_viewport != null:
		_mat.set_shader_parameter("viewport_size", Vector2(world_viewport.size))


func _process(delta: float) -> void:
	if _hit_red > 0.0:
		_hit_red = maxf(_hit_red - delta * 4.0, 0.0)   # 衰减放慢:微红可感知地停留 ~0.25s
		if _mat != null:
			_mat.set_shader_parameter("hit_red", _hit_red)
