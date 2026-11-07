class_name PostProcess
extends CanvasLayer

const LAYER := 128  # 世界后处理层,低于 HUD(129),不遮 HUD
# 发光通道相对世界视口的分辨率倍数:0.5 = 半分辨率(显存 1/4)。发光是柔和的东西,半分辨率够用。
const glow_scale := 0.5

@export var world_viewport: SubViewport = null
@export var barrel_strength: float = 0.4
# 光照参数表:**数值在 .tres 里**,这里只留引用。留空时自动加载默认那份。
@export var lighting: LightingParams = null

var _mat: ShaderMaterial = null
var _glow_vp: SubViewport = null    # 发光通道(自动发现同级 GlowViewport;没有则该特性自动关闭)
var _glow_cam: Camera2D = null      # 发光通道相机,每帧与世界相机同步
var _ui_vp: SubViewport = null      # UI 通道(不吃光照的辅助层)
var _ui_cam: Camera2D = null        # UI 通道相机,同样每帧同步
var _hit_red: float = 0.0   # 受击红闪当前强度(每帧衰减,见 flash_hit)
var _film: float = 0.0             # 回溯底片化强度(Level0 每帧推)
var _loan: float = 0.0
var _haste: float = 0.0
# 残血红屏(纯客户端表现):低于 LOW_HP_START 开始,到 LOW_HP_FULL 满强度;只画屏幕边缘。
const LOW_HP_START := 0.35
const LOW_HP_FULL := 0.10
const LOW_HP_RATE := 0.55           # 每秒过渡量(受伤进得比回血快,见 _tick_low_hp)
const LOW_HP_BPM_LOW := 36.0        # 低血心跳起拍
const LOW_HP_BPM_HIGH := 55.0       # 最低血心跳
var _low_hp: float = 0.0
var _low_hp_pulse: float = 0.0
var _low_hp_player: Node = null

# ── 天空与三套光照(纯渲染层) ── 世界视口那张图自己当遮挡体(alpha 判定)。
# ★ 时间是**时钟驱动**的:60 秒 = 24 小时,开局 06:00。太阳沿一条半圆从左地平线升到天顶、
#   再落到右地平线 —— 所以影子方向在一天里会**自己翻面**(上午向右、下午向左),
#   不是"同一个方向换个角度"。
# ★ 白天与夜晚是两套逻辑,不是同一套调暗:
#     白天  太阳在地平线上 → 斜投影影(晨昏长、正午≈0)+ 暖光/rim + 亮天空
#     夜    太阳在地平线下 → **没有方向影**(没有光源就没有影子)+ 整体压暗 + 冷月光 rim
var sun_enabled: bool = true
var sun_cycle_enabled: bool = true
var sun_strength: float = 0.55          # 斜投影影的整体浓度(set_sun_strength 改它)

# ── 时钟(周期/开局时刻等常量都在 DayCycle,这里只放"当前时刻")──
var day_hour: float = DayCycle.DAY_START_HOUR     # 当前时刻 [0,24);时间玩法会改变它的推进速率
var sun_elevation_deg: float = 0.0       # 派生:太阳高度角(负 = 地平线下)
var sun_azimuth: float = -1.0            # 派生:太阳在左(-1)/ 右(+1)
var moon_elevation_deg: float = 0.0      # 派生:月亮高度角(和太阳反相)
var _sun_cycle_t: float = 0.0            # 本日已过秒数(现实时间 × 时间倍率)


## 当前时刻文本,24 小时制 "HH:MM"。HUD 时钟直接读它 —— 别在别处再算一遍(单一真相源)。
func clock_text() -> String:
	var h := fposmod(day_hour, 24.0)
	var hh := int(h)
	var mm := int((h - float(hh)) * 60.0)
	return "%02d:%02d" % [hh, mm]

# 暗部色:只是"变暗",不是"变灰"。用接近中性的乘数保住砖本身的色相与饱和,
# 掺太多冷紫/冷蓝会让整屏发灰(用户:灰蒙蒙)。

# 斜影长度(世界像素):正午几乎为零,晨昏最长。
const CAST_PX_DUSK := 8.0
const CAST_STEP_PX := 2.0




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

	_resolve_lighting()

	var rect := ColorRect.new()
	rect.name = "ShaderRect"
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child.call_deferred(rect)

	var shader := load("res://core/present/post_process.gdshader") as Shader
	if shader == null:
		push_error("PostProcess: failed to load shader!")
		return
	_mat = ShaderMaterial.new()
	_mat.shader = shader
	_mat.set_shader_parameter("barrel_enabled", true)
	_mat.set_shader_parameter("barrel_strength", barrel_strength)
	_mat.set_shader_parameter("screen_tex", world_viewport.get_texture())
	# 遮挡采样另挂一份同一张纹理,只为拿线性过滤(点采样会让斜射线从两个实心 texel 之间漏过去)
	_mat.set_shader_parameter("occ_tex", world_viewport.get_texture())

	_bind_channels()

	# crop_scale = 窗口 / 世界视口，让 shader 只在世界纹理的中心窗口区采样。
	var vsize := get_viewport().get_visible_rect().size
	_mat.set_shader_parameter("crop_scale", crop_scale(vsize, world_viewport.size))

	rect.material = _mat
	# 太阳投影要用「世界视口像素 → uv」的换算;set_time_effects 也会写同一个值(单机每帧),
	# 这里补一次让 PvP / 不跑时间玩法的场景也有正确值(否则会退化成 1920×1440 兜底)。
	_mat.set_shader_parameter("viewport_size", Vector2(world_viewport.size))
	# ★ Alpha 判定要求视口真的透明:场景里已设 transparent_bg,这里再兜一次底 ——
	#   万一有人手改了 .tscn,判"实心"会退化成"整屏都是实体"。
	if not world_viewport.transparent_bg:
		push_warning("PostProcess: WorldViewport.transparent_bg 应为 true(太阳用 alpha 判遮挡)")
	_push_lighting_params()
	_push_sun()


# ── 通道接线:所有"额外数据来源"都在这一个函数里发现 + 绑定 + 决定降级 ──
# ★ 为什么集中:之前每条通道各写一段 if,散在 _ready 中间,加第三条就要改三处。
#   现在**一条通道 = 一个 _bind_xxx**,缺哪个就把对应的 gain 置 0(整段跳过),不会崩。
#
#   通道清单(每条只回答一个问题):
#     WorldViewport  SubViewport  场景本体长什么样
#     GlowViewport   SubViewport  哪里在自发光        → 加色叠加
#     UiViewport     SubViewport  哪些 UI 不吃光照    → 正常 alpha 合成
#     TerrainMask    烘好的纹理    这个像素是不是地形   → 地形受光只在这里生效
func _bind_channels() -> void:
	var host := world_viewport.get_parent()
	_bind_glow(host)
	_bind_ui(host)
	_bind_terrain_mask()


func _bind_glow(host: Node) -> void:
	_glow_vp = host.get_node_or_null("GlowViewport") as SubViewport if host != null else null
	if _glow_vp == null:
		_mat.set_shader_parameter("glow_gain", 0.0)
		return
	_glow_cam = _glow_vp.get_node_or_null("GlowCamera") as Camera2D
	_mat.set_shader_parameter("glow_tex", _glow_vp.get_texture())
	_mat.set_shader_parameter("glow_gain", 1.0)


func _bind_ui(host: Node) -> void:
	_ui_vp = host.get_node_or_null("UiViewport") as SubViewport if host != null else null
	if _ui_vp == null:
		_mat.set_shader_parameter("ui_gain", 0.0)
		return
	_ui_cam = _ui_vp.get_node_or_null("UiCamera") as Camera2D
	_mat.set_shader_parameter("ui_tex", _ui_vp.get_texture())
	_mat.set_shader_parameter("ui_gain", 1.0)


# 地形掩码是**烘好的数据纹理**,不是通道:地形是静态数据,没必要每帧重渲染一遍。
# 用一条独立通道反而要复制 TileMapLayer 并同步 17 万格。
func _bind_terrain_mask() -> void:
	_mat.set_shader_parameter("mask_gain", 0.0)



# 光照参数只推一次(它们是静态观感值,不随帧变化)。数值来源 = lighting.tres。
func _push_lighting_params() -> void:
	if _mat == null or lighting == null:
		return
	_mat.set_shader_parameter("terrain_gain", lighting.terrain_gain)
	_mat.set_shader_parameter("terrain_depth_px", lighting.terrain_depth_px)
	_mat.set_shader_parameter("terrain_steps", lighting.terrain_steps)
	_mat.set_shader_parameter("terrain_dither", lighting.terrain_dither)
	_mat.set_shader_parameter("shadow_far", lighting.shadow_far)
	DayCycle.set_amb_base(lighting.amb_base)
	FormLight.set_boost(lighting.form_boost)
	FormLight.set_steps(lighting.form_steps)
	FormLight.set_dither(lighting.form_dither)
	FormLight.set_bulge(lighting.form_bulge)


# 解析参数资源:优先用检查器里挂的,否则加载默认那份 .tres。
func _resolve_lighting() -> void:
	if lighting != null:
		return
	lighting = load("res://core/present/lighting_params.tres") as LightingParams
	if lighting == null:
		push_error("PostProcess: 加载不到 lighting_params.tres,外部观感参数将取 .gd 里的默认值")



# ── 昼夜模型:实现全部在 DayCycle(纯函数、不依赖节点)──
# ★ 这里只留**转发壳**:调用方(玩家发光、HUD 时钟、_push_sun)一行都不用改,
#   而"一天的物理"不再和"怎么画到屏幕"混在同一个文件里。
static func sun_at(hour: float) -> Vector2:
	return DayCycle.sun_at(hour)


static func moon_at(hour: float) -> float:
	return DayCycle.moon_at(hour)


static func day_arc(hour: float) -> float:
	return DayCycle.day_arc(hour)


static func day_amount(elev_deg: float) -> float:
	return DayCycle.day_amount(elev_deg)


static func moon_amount(hour: float) -> float:
	return DayCycle.moon_amount(hour)


static func low_sun_amount(elev_deg: float) -> float:
	return DayCycle.low_sun_amount(elev_deg)


static func ambient_for(hour: float, moon_amt: float) -> float:
	return DayCycle.ambient_for(hour, moon_amt)


static func sky_base(hour: float) -> Color:
	return DayCycle.sky_base(hour)


func _push_sun() -> void:
	if _mat == null:
		return
	var pair := sun_at(day_hour)
	var elev: float = pair.x
	sun_elevation_deg = elev
	sun_azimuth = pair.y
	moon_elevation_deg = moon_at(day_hour)

	# 当前起作用的光源:太阳在地平线上就用太阳,否则用月亮(夜里唯一的方向光)。
	var sun_up := elev > 0.0
	var light_elev := elev if sun_up else maxf(moon_elevation_deg, 0.0)
	var light_azim := sun_azimuth if sun_up else -sun_azimuth
	var rad := deg_to_rad(maxf(light_elev, 0.5))
	# 光的方向 = 指向光源(屏幕空间 y 向下)。★ 不是 (1,-1/tan):那给的是余角(踩过)。
	var dir := Vector2(light_azim * cos(rad), -sin(rad)).normalized()

	# 形体光:全场精灵共用材质,这里每帧推一次方向 ⇒ 同时有体积。
	# ★ 强度必须读 lighting_params.tres 的 form_gain —— 早先这里写死 0.50,
	#   于是 .tres 里怎么调都不生效(玩家一直是黑的,实测太阳 09:00 增益 0.42 而非 0.12)。
	# ★ 随白天程度衰减:夜里本来就暗,再叠一层压暗会把暗部糊死。
	var form_amp := lighting.form_gain if lighting != null else 0.12
	FormLight.push(dir, form_amp * clampf(0.45 + 0.55 * day_arc(day_hour), 0.0, 1.0))

	# ★★ ① 环境光:唯一的亮度驱动量,乘性、≤ 1。正午恰为 1.0 = 原版亮度。
	var moon_amt := moon_amount(day_hour)
	var amb_amt := ambient_for(day_hour, moon_amt)
	# ★ 环境光**有颜色**:物理上它就是"天光颜色 × 强度"。这里从当前天空色里取色相/饱和、
	#   丢掉亮度,再按 amb_tint_strength 和白色混合 ⇒ 黄昏偏暖橙、夜里偏蓝、正午近白。
	#   三通道恒 ≤ 1(先按最大通道归一化),所以只染色不提亮,不破坏"永不发光"。
	var sky_for_tint := sky_base(day_hour)
	var mx := maxf(sky_for_tint.r, maxf(sky_for_tint.g, sky_for_tint.b))
	var amb_tint := Color.WHITE
	var amb_mul := Color.WHITE
	if mx > 0.001:
		var hue := Color(sky_for_tint.r / mx, sky_for_tint.g / mx, sky_for_tint.b / mx)
		var strength := lighting.amb_tint_strength if lighting != null else 0.35
		amb_tint = Color.WHITE.lerp(hue, clampf(strength, 0.0, 1.0))
		# ★ 乘数用的染色要比"色相拉拢"更轻:两者共用一个高 strength 会把夜里压暗
		#   (0.55 时夜里红/绿只剩 67%/80%)。这里单独用一半强度。
		amb_mul = Color.WHITE.lerp(hue, clampf(strength * 0.5, 0.0, 1.0))
	_mat.set_shader_parameter("ambient_hue", Vector3(amb_tint.r, amb_tint.g, amb_tint.b))
	_mat.set_shader_parameter("amb_hue_mix", lighting.amb_hue_mix if lighting != null else 0.4)
	_mat.set_shader_parameter("ambient_color",
			Vector3(amb_mul.r * amb_amt, amb_mul.g * amb_amt, amb_mul.b * amb_amt))
	# ★ 天空纵向渐变(全天都有):高处 = 本色,地平线附近 = 略亮略暖;晨昏再往下端压橙/紫。
	var sky_c := sky_base(day_hour)
	var sky_top := sky_c.lightened(0.157)     # 上:略亮(上下各 0.157 ⇒ 跨度恒为 255×0.157 ≈ 40)
	var sky_bot := sky_c.darkened(0.157)      # 下:略暗
	_mat.set_shader_parameter("sky_top", Vector3(sky_top.r, sky_top.g, sky_top.b))
	_mat.set_shader_parameter("sky_bottom", Vector3(sky_bot.r, sky_bot.g, sky_bot.b))
	_mat.set_shader_parameter("sky_curve", 0.10)
	_mat.set_shader_parameter("sky_band_pow", 1.75)

	# ② 斜投影影:太阳/月亮都得"有方向"才投。太阳在头顶(正午)时投影≈0。
	#   夜里月亮也是低角,同样会有很淡的斜影 —— 这就是"晚上的光照变化"。
	var low := low_sun_amount(light_elev)
	var is_moon := not sun_up
	# 月光比日光弱、更冷:浓度按 0.35 折算。
	var light_gain := 0.35 if is_moon else 1.0
	_mat.set_shader_parameter("cast_strength", clampf(low * sun_strength * light_gain, 0.0, 1.0))
	_mat.set_shader_parameter("cast_steps", clampf(CAST_PX_DUSK * low / CAST_STEP_PX, 1.0, 40.0))
	_mat.set_shader_parameter("cast_step_px", CAST_STEP_PX)

	# ★ 环境地板:夜里低、白天高。dayness 由环境光强度归一化得到(夜里 0、正午 1)。
	var dayness := clampf((amb_amt - (lighting.amb_base if lighting != null else 0.15)) / maxf(1.0 - (lighting.amb_base if lighting != null else 0.15), 0.001), 0.0, 1.0)
	var floor_a := 0.3
	var floor_b := 0.55
	if lighting != null:
		floor_a = lighting.amb_floor_night
		floor_b = lighting.amb_floor_day
	_mat.set_shader_parameter("amb_floor", lerpf(floor_a, floor_b, dayness))

	# ③ 暗部颜色:**从环境光/天色派生**,不是写死的冷蓝。
	# ★ 以前是 TINT_NOON/DUESK/NIGHT 三个固定冷色 —— 黄昏满屏长影全被染冷,
	#   和暖橙的天空直接打架(用户:地形压暗和天色对不上,墙面变成灰绿)。
	#   现在阴影色 = 当前环境光色相再压暗一点 ⇒ 阴影是"这种光更少",而不是"换了一种蓝光"。
	#   乘性、三通道 ≤ 1。
	var tint := amb_tint.darkened(0.10)
	if is_moon:
		tint = tint.darkened(0.05)
	tint = Color(minf(tint.r, 1.0), minf(tint.g, 1.0), minf(tint.b, 1.0))
	_mat.set_shader_parameter("cast_tint", Vector3(tint.r, tint.g, tint.b))

	# ④ 受光侧暖色:只有太阳低角(晨昏)才有;月光不暖。
	_mat.set_shader_parameter("sun_warm", 0.0 if is_moon else clampf(low * 0.7, 0.0, 1.0))
	_mat.set_shader_parameter("sun_on", sun_enabled)
	_mat.set_shader_parameter("sun_dir", dir)


func set_sun_enabled(on: bool) -> void:
	sun_enabled = on
	_push_sun()


func set_sun_cycle_enabled(on: bool) -> void:
	sun_cycle_enabled = on


## 直接设时刻(0..24)。调试与截图走这一个入口,和运行时同一条推导链。
func set_hour(hour: float) -> void:
	day_hour = fposmod(hour, 24.0)
	_sun_cycle_t = (day_hour - DayCycle.DAY_START_HOUR) / 24.0 * DayCycle.DAY_CYCLE_SECONDS
	_push_sun()


## 兼容旧调试入口:按高度角反查一个"能产生这个高度角"的时刻(只用于截图对照)。
func set_sun(elevation_deg: float, azimuth: float) -> void:
	var e := clampf(elevation_deg, -40.0, 86.0)
	var h := 12.0
	if e >= 0.0:
		var t := asin(clampf(e / 86.0, -1.0, 1.0)) / PI     # 0..0.5
		h = DayCycle.SUNRISE_HOUR + t * (DayCycle.SUNSET_HOUR - DayCycle.SUNRISE_HOUR)
		if azimuth >= 0.0:
			h = 24.0 - h          # 镜像到下午
	else:
		var t := asin(clampf(-e / 40.0, 0.0, 1.0)) / PI
		h = DayCycle.SUNSET_HOUR + t * (24.0 - DayCycle.SUNSET_HOUR + DayCycle.SUNRISE_HOUR)
	set_hour(h)


## 影子浓度 0~1:整体缩放"斜投影影"那一项的浓度。0 = 完全不画斜影(但昼夜的压暗/rim 仍在)。
func set_sun_strength(v: float) -> void:
	sun_strength = clampf(v, 0.0, 1.0)
	_push_sun()


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
	_sync_glow_camera()
	if _hit_red > 0.0:
		_hit_red = maxf(_hit_red - delta * 4.0, 0.0)   # 衰减放慢:微红可感知地停留 ~0.25s
		if _mat != null:
			_mat.set_shader_parameter("hit_red", _hit_red)
	_tick_low_hp(delta)
	_tick_day_cycle(delta)


# 发光通道的相机必须与世界相机**逐帧同步**(位置/缩放/旋转),否则发光体和世界错位。
# ★ 用实际 global_position(不是 get_base_global_position):要跟着震屏一起动,否则发光会"漂"。
func _sync_glow_camera() -> void:
	if world_viewport == null:
		return
	var cam := world_viewport.get_camera_2d()
	if cam == null:
		return
	# 发光通道是**半分辨率**:尺寸减半后要同时把 zoom 减半,才能覆盖同一片世界区域。
	# 归一化 uv 与分辨率无关 ⇒ shader 里仍用同一个 uv 采样,不需要额外换算。
	if _glow_cam != null:
		_glow_cam.global_position = cam.global_position
		_glow_cam.zoom = cam.zoom * glow_scale
		_glow_cam.rotation = cam.rotation
	if _ui_cam != null:
		_ui_cam.global_position = cam.global_position
		_ui_cam.zoom = cam.zoom
		_ui_cam.rotation = cam.rotation


## 发光体挂载点:发光节点加进这里才不会被 ambient 压暗。没有通道时返回 null。
func glow_root() -> Node:
	return _glow_vp


## UI 辅助层挂载点:换弹读条 / 预瞄线加进这里,不吃 ambient 也不吃影子。没有通道时返回 null。
func ui_root() -> Node:
	return _ui_vp



# ── 时钟推进 ── 现实 60 秒 = 游戏内 24 小时(1 秒 = 24 分钟),从 06:00 起。
# 暂停时不走(_process 是 ALWAYS,这里自己让路)。
# ★ 纯表现:不碰 TimeField、不进快照、不影响任何逻辑;联机两端各自按本机时钟走即可。
const _SUN_PUSH_EPS := 0.02   # 高度角变化小于这个就不重推(度数)

func _tick_day_cycle(delta: float) -> void:
	if _mat == null or not sun_enabled or not sun_cycle_enabled:
		return
	if get_tree() != null and get_tree().paused:
		return
	_sun_cycle_t = fmod(_sun_cycle_t + delta * _time_rate(), DayCycle.DAY_CYCLE_SECONDS)
	day_hour = fposmod(DayCycle.DAY_START_HOUR + _sun_cycle_t / DayCycle.DAY_CYCLE_SECONDS * 24.0, 24.0)
	var want := sun_at(day_hour).x
	if absf(want - sun_elevation_deg) >= _SUN_PUSH_EPS:
		_push_sun()


## 时间倍率:加速 = 时钟快进,倒流 = 时钟倒着走。没在玩时间玩法时恒为 1。
## ★ 只影响**时钟**(昼夜推进),不影响物理/逻辑 —— 逻辑时间由 TimeField 自己管。
const TIME_RATE_HASTE := 6.0
const TIME_RATE_REWIND := -4.0

func _time_rate() -> float:
	var tf := TimeField.current
	if tf == null:
		return 1.0
	if tf.is_rewinding():
		return TIME_RATE_REWIND
	if tf.is_hasting():
		return TIME_RATE_HASTE
	return 1.0


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
