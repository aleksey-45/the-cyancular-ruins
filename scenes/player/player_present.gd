class_name PlayerPresent
extends Node

# 玩家表现层:眼睛发光(美术遮罩镜像)、换弹圆环(UI 通道)、冲刺/加速残影、朝向 flip 的 shader 参数。
# ★ 只有这里能碰渲染树:找 post_process 组、建 UI 子节点、读相机。模拟侧(移动/命中/回滚)一律不碰。
# ★ 由 Player._ready 在**非 headless** 时创建:headless(服务器/测试)没有渲染,表现层整体不自启。
#   旧实现在权威端也给每个玩家建了一个 ReloadRing(靠"找不到 group 就 return"降级),那不是"没有表现",是资源白花。
const FRAMES_JSON := "res://assets/textures/player.frames.json"

# ── 发光:由美术遮罩驱动(独立资产,像灯瓦片)──
# 遮罩 = `player_light.png`,与 player.png 同布局(同一份 cells)、白色标记、A 通道装强度。
# 为什么用遮罩:眼睛每帧位置都在变(实测跨帧 x 漂 4px、y 漂 6px),硬编码坐标跟不住。
# 为什么要单独的发光通道:世界整体在 PostProcess 里乘 ambient,发光体画在世界里会跟着变暗;
# 发光精灵挂在 PostProcess 的 GlowViewport(相机逐帧同步),由 shader 在光照之后叠加。
const LIGHT_FIELD := "light_image"
const LIGHT_K := 0.32
const LIGHT_TINT := Color(0.86, 0.93, 1.0)

const RELOAD_RING_OFFSET := Vector2(58.0, -44.0)
const HASTE_GHOST_INTERVAL := 0.03
const DOWN_DASH_GHOST_TIME := 0.06

var player: Player = null

var _reload_ring: ReloadRing = null   # 换弹圆环(角色后侧);挂在 UI 通道里
var _ring_in_ui := false              # 圆环是否已挂进 UI 通道(决定用世界坐标还是局部坐标)
var _light: AnimatedSprite2D = null
var _light_root: Node2D = null        # 发光通道里的镜像根(承载玩家的位置/缩放)
var _post: Node = null                # PostProcess(惰性获取)
var _ghost_t := 0.0
var _ghost_flip := false
var _dash_ghost_t := 0.0
var _down_dash_ghost_t := 0.0


func setup(p: Player) -> void:
	player = p


func tick(delta: float) -> void:
	if player == null or not is_instance_valid(player):
		return
	sync_form_flip()
	_tick_eye_glow()
	_tick_ghosts(delta)
	_update_reload_ring()


func sync_form_flip() -> void:
	var anim := player.animator
	var mat := anim.material as ShaderMaterial if anim != null else null
	if mat != null:
		mat.set_shader_parameter("flip_x", 1.0 if anim.flip_h else 0.0)


# 下冲开始:移动侧只报告事件,计时与发射都在本层(纯表现,不进整态)。
func down_dash_started() -> void:
	_down_dash_ghost_t = DOWN_DASH_GHOST_TIME


func _tick_ghosts(delta: float) -> void:
	if _down_dash_ghost_t > 0.0:
		_down_dash_ghost_t = maxf(_down_dash_ghost_t - delta, 0.0)
	var anim := player.animator
	if anim == null or not player.is_inside_tree():
		_dash_ghost_t = 0.0
		return
	# 冲刺 / 下冲残影:只在渲染帧发射 ⇒ C2 回滚重放不会把同一段冲刺再生成一遍。
	if player.is_charge or _down_dash_ghost_t > 0.0:
		if player.get_viewport().get_camera_2d() != null:
			_dash_ghost_t -= delta
			if _dash_ghost_t <= 0.0:
				_dash_ghost_t = PlayerVisual.DASH_GHOST_INTERVAL
				AfterImage.spawn(player.get_parent(), anim, PlayerVisual.DASH_GHOST_TINT,
						PlayerVisual.DASH_GHOST_DURATION, -1)
	else:
		_dash_ghost_t = 0.0
	# 加速残影:红/蓝交替;2× 下比原先(0.045)更密,拖尾才跟得上。
	if player.speed_mult() > 1.0:
		_ghost_t -= delta
		if _ghost_t <= 0.0:
			_ghost_t = HASTE_GHOST_INTERVAL
			var tint := Color(1.0, 0.25, 0.25, 0.55) if _ghost_flip else Color(0.3, 0.4, 1.0, 0.55)
			_ghost_flip = not _ghost_flip
			AfterImage.spawn(player.get_parent(), anim, tint)


# ── 换弹圆环 ──
# 显示在角色后侧(背对朝向那一侧),环心是带一位小数的倒计时。
# ★ 挂在 PostProcess 的 **UI 通道**(不吃 ambient、不吃影子):它是有暗色底环的 UI,
#   留在世界里会被整体压暗,塞进加色的发光通道又会变亮。
#   降级:没有 UI 通道时退回挂在玩家身上(旧的局部坐标算法)。
func _ensure_reload_ring() -> void:
	if _reload_ring != null and is_instance_valid(_reload_ring):
		return
	var pp := get_tree().get_first_node_in_group("post_process")
	var root: Node = null
	if pp != null and pp.has_method("ui_root"):
		root = pp.ui_root()
	_reload_ring = ReloadRing.new()
	_reload_ring.visible = false
	if root != null:
		_ring_in_ui = true
		root.add_child(_reload_ring)          # UI 通道里 1 单位 = 1 世界像素
	else:
		_ring_in_ui = false
		_reload_ring.scale = Vector2.ONE / player.scale.x
		player.add_child(_reload_ring)


func _update_reload_ring() -> void:
	_ensure_reload_ring()
	if _reload_ring == null or not is_instance_valid(_reload_ring):
		return
	var w := player.weapons.current_weapon()
	var prog := w.reload_progress() if w != null else -1.0
	_reload_ring.visible = prog >= 0.0
	if prog < 0.0:
		return
	var offset := Vector2(-RELOAD_RING_OFFSET.x * float(player.facing_direction), RELOAD_RING_OFFSET.y)
	if _ring_in_ui:
		# UI 通道有自己的一份同参数相机 ⇒ 直接用世界坐标即可,不需要投影换算。
		_reload_ring.global_position = player.global_position + offset
		_reload_ring.scale = Vector2.ONE
	else:
		var sc := maxf(absf(player.scale.x), 0.001)
		_reload_ring.position = offset / sc
	_reload_ring.set_progress(prog, w.reload_time * (1.0 - prog))


# ── 眼睛发光 ──
func _tick_eye_glow() -> void:
	var anim := player.animator
	if anim == null:
		return
	if _light == null:
		if _post == null or not is_instance_valid(_post):
			_post = get_tree().get_first_node_in_group("post_process")
		if _post == null or not _post.has_method("glow_root"):
			return
		var glow_parent: Node = _post.glow_root()
		if glow_parent == null:
			return                        # 没有发光通道(别的场景)=> 本特性自隐
		var lf := SpriteFramesIO.load_json(FRAMES_JSON, LIGHT_FIELD)
		if lf == null:
			return
		_light_root = Node2D.new()
		_light_root.name = "PlayerLight"
		glow_parent.add_child(_light_root)
		_light = AnimatedSprite2D.new()
		_light.name = "LightMask"
		_light.sprite_frames = lf
		_light.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST   # 遮罩绝不能被过滤混色
		_light.centered = anim.centered
		_light.offset = anim.offset
		_light_root.add_child(_light)
	# 镜像本体变换:发光通道有自己的相机(同世界相机),所以世界坐标直接可用。
	_light_root.global_position = player.global_position
	_light_root.scale = player.scale
	# 与本体严格同帧:同一个动画名 + 同一个帧号,遮罩不会和贴图错开。
	_light.animation = anim.animation
	_light.frame = anim.frame
	_light.flip_h = anim.flip_h
	_light.scale = anim.scale
	var amb := 1.0
	if _post != null and is_instance_valid(_post):
		amb = clampf(_post.ambient_for(_post.get("day_hour"), _post.moon_amount(_post.get("day_hour"))), 0.05, 1.0)
	# 强度:白天几乎为 0、夜里明显。遮罩自己的 A 通道仍是逐像素强度,两者相乘。
	var gain := clampf(LIGHT_K * (1.0 - amb), 0.0, 1.0)
	_light.modulate = Color(LIGHT_TINT.r, LIGHT_TINT.g, LIGHT_TINT.b, gain)
