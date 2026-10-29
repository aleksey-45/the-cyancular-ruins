class_name PostProcess
extends CanvasLayer

const LAYER := 128  # 世界后处理层,低于 HUD(129),不遮 HUD

@export var world_viewport: SubViewport = null
@export var barrel_strength: float = 0.4

var _mat: ShaderMaterial = null
var _hit_red: float = 0.0   # 受击红闪当前强度(每帧衰减,见 flash_hit)
var _film: float = 0.0             # 回溯底片化强度(Level0 每帧推)
var _loan: float = 0.0
var _haste: float = 0.0
# 残血红屏(纯客户端表现):低于 LOW_HP_START 开始,到 LOW_HP_FULL 满强度;只画屏幕边缘。
const LOW_HP_START := 0.35
const LOW_HP_FULL := 0.10
const LOW_HP_RATE := 0.55           # 每秒过渡量(受伤进得比回血快,见 _tick_low_hp)
const LOW_HP_BPM_LOW := 36.0        # 低血心跳起拍(用户反馈 72 太快 ⇒ 减半)
const LOW_HP_BPM_HIGH := 55.0       # 最低血心跳(同上,110 的一半)
var _low_hp: float = 0.0
var _low_hp_pulse: float = 0.0
var _low_hp_player: Node = null

# 窗口尺寸 / 世界视口尺寸:把窗口映射到世界视口的中心裁剪区。
# 枪的瞄准换算(weapon_base)与 shader 采样都用它,收敛到单一来源,改一处不偏。
static func crop_scale(win_size: Vector2, world_vp_size: Vector2) -> Vector2:
	return Vector2(win_size.x / world_vp_size.x, win_size.y / world_vp_size.y)


func _ready() -> void:
	add_to_group("post_process")
	layer = LAYER
	# 暂停(pause_menu 暂停整棵树)时本层仍要跑:受击红闪在 _process 里逐帧衰减,
	# 若跟着树一起暂停,红色会凝固在暂停那一刻直到恢复。
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
	_tick_low_hp(delta)


# 残血红屏驱动:从 `player` 组取本地玩家(单机/PvP 都是这一个入口),按 hp/max_hp 映射到 0..1。
# ★ 纯表现:不接信号、不需要服务器字段,也不碰 HUD;倒地时淡出(倒地有既有的灰化)。
func _tick_low_hp(delta: float) -> void:
	if _mat == null:
		return
	if _low_hp_player == null or not is_instance_valid(_low_hp_player):
		_low_hp_player = get_tree().get_first_node_in_group("player")
	var target := 0.0
	if _low_hp_player != null and is_instance_valid(_low_hp_player) \
			and _low_hp_player.has_method("is_downed") and not _low_hp_player.is_downed():
		var mx := float(_low_hp_player.get("max_hp"))
		if mx > 0.0:
			var ratio := clampf(float(_low_hp_player.get("hp")) / mx, 0.0, 1.0)
			target = clampf((LOW_HP_START - ratio) / (LOW_HP_START - LOW_HP_FULL), 0.0, 1.0)
	# 受伤方向快、恢复方向慢:避免 c2 校正 / 治疗 / 复活时闪跳。
	var rate := LOW_HP_RATE * (1.6 if target > _low_hp else 0.7)
	_low_hp = move_toward(_low_hp, target, delta * rate)
	_low_hp_pulse += delta * lerpf(LOW_HP_BPM_LOW, LOW_HP_BPM_HIGH, _low_hp) / 60.0 * TAU
	_mat.set_shader_parameter("low_hp", _low_hp)
	_mat.set_shader_parameter("low_hp_pulse", _low_hp_pulse)
