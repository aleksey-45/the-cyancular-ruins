class_name PostProcess
extends CanvasLayer

const LAYER := 128  # 世界后处理图层，层级低于 HUD（129），避免遮挡界面

@export var world_viewport: SubViewport = null
@export var barrel_strength: float = 0.4

var _mat: ShaderMaterial = null
var _hit_red: float = 0.0   # 受击红闪当前强度（每帧衰减，参见 flash_hit）
var _low_hp: float = 0.0    # 低血暗角当前强度（平滑逼近目标）
var _low_hp_target: float = 0.0
var _heartbeat_cd: float = 0.0
var _rewind_coverage := 0.0
var _haste_dim := 0.0

# 低于该生命比例开始出现暗角与心跳；强度按实际最大 HP 归一化。
const LOW_HP_THRESHOLD := 0.35
const LOW_HP_RATE := 2.0

# 窗口尺寸 / 世界视口尺寸换算：将窗口坐标映射至世界视口的中心裁剪区域。
# 武器瞄准坐标转换与着色器采样均统一调用此方法。
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
	_mat.set_shader_parameter("barrel_enabled", true)
	_mat.set_shader_parameter("barrel_strength", barrel_strength)
	_mat.set_shader_parameter("screen_tex", world_viewport.get_texture())
	_mat.set_shader_parameter("viewport_size", Vector2(world_viewport.size))

	# crop_scale = 窗口 / 世界视口，让 shader 只在世界纹理的中心窗口区采样。
	var vsize := get_viewport().get_visible_rect().size
	_mat.set_shader_parameter("crop_scale", crop_scale(vsize, world_viewport.size))

	rect.material = _mat
	add_child(rect)


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


## 按实际最大 HP 归一化低血强度；恢复后目标归零，由 _process 平滑降低。
func set_health_ratio(hp: int, max_hp: int) -> void:
	var ratio := 0.0 if max_hp <= 0 else clampf(float(hp) / float(max_hp), 0.0, 1.0)
	_low_hp_target = clampf((LOW_HP_THRESHOLD - ratio) / LOW_HP_THRESHOLD, 0.0, 1.0)


# 单人受击和联机命中共用红闪。
func flash_hit(strength: float = 1.0) -> void:
	_hit_red = maxf(_hit_red, clampf(strength, 0.0, 1.0))

## 返回底片覆盖度，多人对局把同样的过渡用在指定图层上。
func advance_time(delta: float, rewinding: bool, haste: bool, loan: float, fullscreen: bool) -> float:
	_rewind_coverage = move_toward(_rewind_coverage, 1.0 if rewinding else 0.0, delta / 0.2)
	_haste_dim = move_toward(_haste_dim, 1.0 if haste else 0.0, delta / 0.1)
	_mat.set_shader_parameter("rewind_film", _rewind_coverage if fullscreen else 0.0)
	_mat.set_shader_parameter("loan_depth", clampf(loan, 0.0, 1.0))
	_mat.set_shader_parameter("haste_dim", _haste_dim)
	return _rewind_coverage


func present(delta: float) -> void:
	if _hit_red > 0.0:
		_hit_red = maxf(_hit_red - delta * 4.0, 0.0)   # 衰减放慢:微红可感知地停留 ~0.25s
		if _mat != null:
			_mat.set_shader_parameter("hit_red", _hit_red)
	if not is_equal_approx(_low_hp, _low_hp_target):
		_low_hp = move_toward(_low_hp, _low_hp_target, delta * LOW_HP_RATE)
		if _mat != null:
			_mat.set_shader_parameter("low_hp", _low_hp)
	_heartbeat_cd = maxf(_heartbeat_cd - delta, 0.0)
	if _low_hp >= LOW_HP_THRESHOLD * 0.999 and _heartbeat_cd <= 0.0 and not get_tree().paused:
		# 阈值与冷却控制：低血时才播放，且按强度加快间隔，不会每帧重启。
		Sfx.play("heartbeat", 1.0, -6.0)
		_heartbeat_cd = lerpf(1.2, 0.6, _low_hp)
