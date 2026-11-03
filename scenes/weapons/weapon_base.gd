class_name WeaponBase
extends Node2D

enum Tier { LIGHT, MEDIUM, HEAVY }
enum PenaltyMode { NONE, WHILE_FIRING, WHILE_AIM_OR_COOLDOWN }

@export var bullet_scene: PackedScene = preload("res://scenes/weapons/bullet.tscn")
const RECOIL_TIME: float = 0.06  # 枪口后坐复位时长(秒),旧 recoil_time 内联
const PREVIEW_COLLISION_RADIUS: float = 4.0
# ── 走路 bob(纯表现)── 相位**取宿主模型的走路动画帧**(move 的 frame+frame_progress),不是自己的计时器;
#    单帧姿态(蹲/冲刺/飞行)没有帧进度 ⇒ 自然不抖,不为它们加代码。幅度随水平速度线性淡入。
const WALK_BOB_Y: float = 0.55             # local px(玩家根 2.5× 缩放 ⇒ 屏幕 ≈1.4px)
const WALK_BOB_X: float = 0.22
const WALK_BOB_ROT_DEG: float = 0.5
const WALK_BOB_REF_SPEED: float = 700.0    # px/s:达到此速度时满幅

# ── 武器参数 ──(tier 仅作信息/分组用,不参与行为判定)
@export var tier: Tier = Tier.LIGHT
@export var weapon_name: String = "weapon"

# ── 开火 ── full_auto:true=按住连发,false=按一下打一发。
@export var full_auto: bool = false
@export var fire_cooldown: float = 0.2
# heavy_aim:按住左键进入激光预瞄,松开才发射。
@export var heavy_aim: bool = false
# trigger_delay:扳机延迟(秒)。>0 时按住连发武器要先把扳机压满这么久才出第一发(机枪起转),期间松开 = 一发不打。
@export var trigger_delay: float = 0.0

# ── 蓄力(弓)── charge_time > 0 表示本武器按蓄力比缩放伤害/弹速;0 = 不蓄力(其余枪械全都不设)。
# 蓄力比与扳机计时随权威状态捕获/恢复。
@export var charge_time: float = 0.0
# 0 蓄力的伤害/弹速;满蓄力用 damage / bullet_speed。
@export var charge_damage_min: int = 0
@export var charge_speed_min: float = 0.0
var charge_ratio: float = 0.0
# 蓄力箭的视觉:拉弓时整支箭后退(弓身不动)。pull = 满蓄力时后退多少 px;节点名 ChargeArrow,不在就跳过。
@export var charge_arrow_pull: float = 0.0
var _trigger_t: float = 0.0

# ── 子弹 ── bullet_speed(px/s)越大弹道越直、越难闪避。
@export var bullet_speed: float = 900.0
@export var bullet_range: float = 600.0
@export var bullet_size: float = 1.0
@export var bullet_color: Color = Color.WHITE

# ── 霰弹/多弹丸 ── pellet_count:每次开火弹丸数(1=单发,>1 为霰弹)。
@export var pellet_count: int = 1
@export var spread_deg: float = 0.0

# ── 伤害 ── damage:命中敌人扣除的 HP。
@export var damage: int = 1
# impact:命中击退力度(>0 会覆盖敌人自身 knockback_strength)。
@export var impact: float = 60.0

# max_live_projectiles:同屏同时在飞弹数上限(0=无限)。防风暴类武器(榴弹)多人同炸:同时爆炸的 AoE/拆砖/碰撞重建连锁会让自建房机器卡死/闪退;弹数满时开火不发射(冷却照走,等场上的爆完再打)。
@export var max_live_projectiles: int = 0

# ── 后坐/镜头 ── recoil_push:开火把玩家向后推的力度(蹲下时不推)。
@export var recoil_push: float = 0.0
@export var recoil_kick: float = 4.0
@export var cam_shake: float = 2.0
@export var cam_shake_time: float = 0.1

# ── 移动惩罚 ── move_penalty:惩罚生效期间的水平移速倍率(1.0=不减)。
@export var move_penalty: float = 1.0
@export var jump_penalty: float = 1.0
# penalty_mode:NONE 永不 / WHILE_FIRING 开火后冷却中 / WHILE_AIM_OR_COOLDOWN 预瞄或冷却中。
@export var penalty_mode: PenaltyMode = PenaltyMode.NONE

# ── 激光(heavy_aim 用)── 预瞄激光线长度(px)。
@export var laser_length: float = 600.0
@export var laser_color: Color = Color(1.0, 0.2, 0.2, 0.6)
# show_aim_laser:heavy_aim 武器预瞄时是否画那条直线激光。弓关掉它(拉弓靠箭后移表达,一条红线从枪口射出去是枪械的语汇)。
@export var show_aim_laser: bool = true

# ── 瞄准 ── pitch_clamp_deg:本枪仰角钳制角(枪口/激光/出弹方向共用)。
@export var pitch_clamp_deg: float = 45.0

# ── 弹道/预览(榴弹等抛体用)── bullet_gravity:重力下坠倍率,发射时注入子弹(0=直线)。
@export var bullet_gravity: float = 0.0
# preview_arc:true=重武器预瞄画抛物线弧线(取代直线激光)。
@export var preview_arc: bool = false
# preview_time:预瞄参考时长(秒),仅供画弧;真实爆炸时机由子弹 fuse_time 决定。
@export var preview_time: float = 0.5

# ── 换弹(固定玩法,无开关可关;全模式开放)── PvP(1v1/大乱斗)一并开放:此前那道 reload_active() 闸门在 Level0.pvp_mode 与网络输入源下恒 false ⇒ PvP 两端一致地不换弹;开放后两端跑同一套(按下的边沿经输入包上行 BIT_RELOAD,弹药与装填进度进 Player.capture_state())。闸门整个删掉而不是改成恒 true:项目约定是「换弹恒开」,留个恒真的函数只会让人以为还有开关。
@export var mag_size: int = 12        # 弹夹容量
@export var reload_time: float = 1.2  # 换弹全程耗时(秒)
var mag_ammo: int = 0                 # 弹夹内残弹
# 入树前的待生效残弹。哨兵不能用 0(0 是合法弹数),也不能用 WeaponInventory.MAG_FULL(-1),故取 -2。★ 为什么需要它:新武器实例用 call_deferred(add_child) 入树,而 _ready() 会把 mag_ammo 重置为 mag_size ⇒ 入树前同步写残弹会被冲掉;原先的对策是排一个帧末 deferred 写回,而那个写回会覆盖它之后发生的一切(含回滚重放期间打出的每一发)。
const MAG_UNSET := -2
var pending_mag: int = MAG_UNSET
# 弹数是否已落定。★ 语义只有一个:_ready() 已跑过、mag_ammo 不再等于声明初值 0。
# ★ 为什么需要它:新武器实例用 call_deferred(add_child) 入树,而那里的 equip(body, cd) 是同步的 ⇒ 入树前那个窗口里 player 已非空、tick() 会照跑,而 mag_ammo 仍是 0 ⇒ fire() 的「空弹夹自动换弹」被假前提触发,把权威的 _reloading = false 冲成 true。
# ★ 为什么不是 is_inside_tree() 守卫(已被明文否决):它会丢帧,并会把 _auto_aim() 的朝向一起冻住 ⇒ 那本身造成真分歧,比它修掉的问题更坏。读点只有两个(fire() 的空弹夹分支与 start_reload() 首行):按 R 那条路绕过 fire(),与切枪同帧相撞是概率问题,撞上同样会把权威的 _reloading 冲成 true。
var _mag_ready := false
var _reloading := false
var _reload_t := 0.0
var _walk_bob := Vector2.ZERO          # 走路 bob(纯表现;相位取宿主模型的 move 帧)
var _walk_bob_rot := 0.0

# 换弹动画:进度 0→1 期间枪口下压再回位(sin 包络),中段带机械微抖;作用于精灵局部坐标,与根节点的瞄准旋转/镜像互不干扰。
const RELOAD_TILT := 0.9                    # 枪口下压最大弧度(≈51°)
const RELOAD_OFFSET := Vector2(-3.0, 7.0)   # 精灵同步回拉/下沉

func is_reloading() -> bool:
	return _reloading

func reload_progress() -> float:
	return (1.0 - _reload_t / maxf(reload_time, 0.01)) if _reloading else -1.0

func start_reload() -> void:
	# ★ 弹数未落定(未入树窗口)时 mag_ammo 仍是声明初值 0,不是「空弹夹」—— 按 R 那条路不经过 fire(),同一窗口里会在这里起一次没必要的换弹(见 _mag_ready)。
	if not _mag_ready:
		return
	if _reloading or mag_ammo >= mag_size:
		return
	_reloading = true
	_reload_t = reload_time
	Sfx.play("reload")

# 把「换弹 > 后坐 > 走路 bob」合成为精灵 pose —— **唯一**写 sprite.position/rotation 的地方(以后加表现只改这里)。
# 换弹姿态压过其他(与旧实现同优先);bob 始终叠加:走路/换弹/后坐同时发生时只有它是连续的。
func _apply_sprite_pose() -> void:
	if sprite == null:
		return   # 未入树(重建窗口):@onready 尚未解析,姿势下一帧补算
	var pos := _base_sprite_pos
	var rot := 0.0
	if _reloading:
		var p := clampf(1.0 - _reload_t / maxf(reload_time, 0.01), 0.0, 1.0)
		var k := sin(p * PI)          # 0→1→0:前段压下,末段回位
		var jiggle := sin(p * 34.0) * 1.2 * k   # 中段机械微抖(频率固定,幅度随包络)
		rot = RELOAD_TILT * k
		pos += RELOAD_OFFSET * k + Vector2(jiggle, 0.0)
	elif _recoil_timer > 0.0:
		pos -= Vector2(1.0, 0.0) * recoil_kick * (_recoil_timer / RECOIL_TIME)
	sprite.position = pos + _walk_bob
	sprite.rotation = rot + _walk_bob_rot
	_apply_charge_arrow_pose()


# 只移动箭,弓身不动;ChargeArrow 的 z_index 让箭画在弓身后。
func _apply_charge_arrow_pose() -> void:
	if _charge_arrow == null:
		return
	_charge_arrow.visible = charge_time > 0.0 and _aiming
	_charge_arrow.position = _base_arrow_pos + Vector2(-charge_arrow_pull * charge_ratio, 0.0)

# ★ 走路 bob 的相位取自**宿主模型的走路动画帧**(move 的 frame + frame_progress),不是独立计时器:
#   模型换一帧 = 枪跟着换一次;单帧姿态(蹲/冲刺/飞行)没有帧进度 ⇒ 自然不抖,不为它们加代码。
#   幅度按水平速度淡入(停下即回中);一个 move 循环(8 帧)≈ 两步 ⇒ 纵向两次起伏。
func _sample_walk_bob(anim: AnimatedSprite2D, speed_x: float) -> void:
	_walk_bob = Vector2.ZERO
	_walk_bob_rot = 0.0
	if anim == null or anim.sprite_frames == null or anim.animation != &"move":
		return
	var n := anim.sprite_frames.get_frame_count(&"move")
	if n <= 0:
		return
	var ratio := clampf(absf(speed_x) / WALK_BOB_REF_SPEED, 0.0, 1.0)
	if ratio <= 0.0:
		return
	var prog := (float(anim.frame) + anim.frame_progress) / float(n)   # 0..1 = 一个 move 循环
	var step := prog * TAU * 2.0
	_walk_bob = Vector2(cos(prog * TAU) * WALK_BOB_X, sin(step) * WALK_BOB_Y) * ratio
	_walk_bob_rot = sin(step) * deg_to_rad(WALK_BOB_ROT_DEG) * ratio

# ── 玩家按名访问 → `as Player` + 直接访问(2026-11-02)──
# 宿主 `player` 的声明类型是 Node2D(兼容副本武器的 null / 测试夹具),但生产宿主恒为 Player(已有 class_name)。
# 故这些口不再 `get("x")` / `has_method("x")` + 字符串调用:拼错成员名 = 编译期报错,不再静默拿到 null 或漏调。
# ★ 非 Player 宿主一律按"没有该接口"处理:旧 has_method 判据在那种宿主上返回的也是"没有",二者同向。
func _host_walk_anim() -> AnimatedSprite2D:
	var p := player as Player
	return p.animator if p != null else null

func _host_speed_x() -> float:
	var p := player as Player
	return absf(p.velocity.x) if p != null else 0.0

@onready var sprite: Sprite2D = $Sprite2D
@onready var muzzle: Marker2D = $Muzzle
@onready var _charge_arrow: Sprite2D = get_node_or_null("ChargeArrow") as Sprite2D
var player: Node2D
# 加速倍率(PvP):由宿主每物理帧推入(player.gd 的 _push_haste_mult → 当前那把枪)。★ 为什么是注入成员而不是 equip() 的参数:宿主引用只在 equip() 给一次,而倍率每帧都在变。★ 只被 _spawn_projectiles() 读:单机它恒 1(弹速倍率由 TimeField.bullet_delta 承担,不会双乘)。
# ★ 覆盖上限(照实):默认 1.0 ⇒ 宿主忘推 = 静默回到 1×(不报错)。零守卫(rewind_weapon_probe 已删·2026-10-09 的 S10)。
var haste_mult: float = 1.0
var fire_cd_timer: float = 0.0

var _recoil_timer: float = 0.0
var _base_sprite_pos: Vector2 = Vector2.ZERO
var _base_arrow_pos: Vector2 = Vector2.ZERO   # 蓄力箭的"未拉弓"位置(_ready 抓一次)
var _aiming: bool = false
var _fire_buffered: bool = false
var _aim_facing: int = 1          # 最近一次明确的瞄准侧(近垂直瞄时用,不随走路翻侧)
var _current_aim_facing: int = 1  # 本帧实际生效的朝向(含冲刺锁定回落),弹道与枪口共用
var _laser: Line2D = null
var _explosion_marker: Sprite2D = null

static func clamp_pitch(dir: Vector2, facing: int, limit_deg: float = 45.0) -> float:
	var local := Vector2(dir.x * float(facing), dir.y)
	var limit := deg_to_rad(limit_deg)
	return clampf(local.angle(), -limit, limit)

func _ready() -> void:
	mag_ammo = mag_size
	# ★ 入树前若有人塞了残弹,在这里一次消费掉 —— 这是「入树前写入」唯一生效的地方;消费后复位哨兵,免得后续 _ready 或探针误读。
	if pending_mag != MAG_UNSET:
		mag_ammo = clampi(pending_mag, 0, mag_size)
		pending_mag = MAG_UNSET
	_mag_ready = true
	_base_sprite_pos = sprite.position
	# 蓄力箭的基准位置只抓一次:之后每帧只写 position(不读回),重复抓会把已后移的位置当成基准、越蓄越靠后。
	if _charge_arrow != null:
		_base_arrow_pos = _charge_arrow.position
		_charge_arrow.visible = false
	# ★ 预瞄线与爆炸预览标记是**武器**的子节点(武器实例从不进出对象池),只在入树时建一次就够;子弹侧对应的是拖尾。
	_laser = Line2D.new()
	_laser.width = 1.0  # 细激光(经玩家 2.5x 缩放渲染约 2.5px)
	_laser.default_color = laser_color
	_laser.visible = false
	add_child.call_deferred(_laser)
	_explosion_marker = Sprite2D.new()
	_explosion_marker.texture = Explosion.make_circle_texture(16)
	_explosion_marker.modulate = Color(1.0, 0.4, 0.2, 0.9)
	_explosion_marker.visible = false
	add_child.call_deferred(_explosion_marker)

func _player_ok() -> bool:
	# ★ 旧写法是 `has_method("is_downed")` 兜容非 Player 宿主;宿主恒为 Player ⇒ 直接判。
	var p := player as Player
	return p != null and not p.is_downed()

# 宿主没注入开火接口时的响亮失败:点名是谁违约(武器名 + 宿主节点 + 宿主脚本路径)。
func _report_missing_attack_hook(hook: String) -> void:
	var who := "<null>(player == null)"
	if player != null:
		var scr := player.get_script() as Script
		var path := scr.resource_path if scr != null else ""
		who = "%s(%s)" % [player.name, path if not path.is_empty() else player.get_class()]
	push_error("武器 %s 的宿主 %s 没有注入输入接口 %s() —— 武器禁止读全局 Input" % [weapon_name, who, hook])

# ── 攻击输入查询:只读 player 注入进来的输入(LocalInputSource / PacketInputSource)── 这三个查询原先各带一句「宿主没有该接口就读全局 Input」的兜底,那会让 player 缺方法时绕过注入层偷读全局输入总线 —— 在权威服务器 / 回放 / 预测下是错的来源(headless 服务器读到的是宿主机桌面按键状态)。
# 缺接口 = 违约:当帧调 _report_missing_attack_hook() 点名宿主,查询返回 false(不开火)。为什么不让违约把整局带走:武器每个物理帧都会被问一次,而「不开火 + 报错」既不凭全局输入打出子弹,也不静默过关。★ 纪律:本文件里不得再出现读全局输入总线的写法(零守卫:扫这条子串的文本探针今天不在仓库里)。
func _attack_pressed() -> bool:
	var p := player as Player
	if p == null:
		_report_missing_attack_hook("is_attack_pressed")
		return false
	return p.is_attack_pressed()

func _attack_just_pressed() -> bool:
	var p := player as Player
	if p == null:
		_report_missing_attack_hook("is_attack_just_pressed")
		return false
	return p.is_attack_just_pressed()

func _attack_just_released() -> bool:
	var p := player as Player
	if p == null:
		_report_missing_attack_hook("is_attack_just_released")
		return false
	return p.is_attack_just_released()

func equip(p: Node2D, inherit_cooldown: float = 0.0) -> void:
	player = p
	# 切枪继承旧武器剩余冷却:后摇不能被切枪刷掉(否则可切枪连射)。
	fire_cd_timer = maxf(inherit_cooldown, 0.0)
	# 缓冲开火不随切枪继承:旧武器 freed 标记随之消失,新武器从无缓冲开始。
	_fire_buffered = false
	cancel_aim()

# 武器帧逻辑由所属 Player 的物理 tick 显式驱动(不跑 idle _process):冷却/缓冲开火/重武器松开/预瞄/后坐必须落在固定的物理 tick 上,否则同一输入在客户端预测重放 / 服务器权威模拟下会落在不同 tick(rollback 需要确定性);未被 Player 驱动的实例(对手副本武器,player==null)由 drive_remote_visual 外部驱动。
func tick(delta: float) -> void:
	if not _player_ok():
		return
	fire_cd_timer = maxf(fire_cd_timer - delta, 0.0)
	if _reloading:
		_reload_t -= delta
		if _reload_t <= 0.0:
			_reloading = false
			mag_ammo = mag_size
			Sfx.play("switch")
	# 每帧同步朝向/枪口旋转(瞄准与预览弧线);fire() 内部还会再同步一次,覆盖直接开火等不经本帧 tick 的路径,避免读到走路覆盖的旧朝向。
	_auto_aim()
	if _fire_buffered and fire_cd_timer == 0.0:
		_fire_buffered = false
		fire()
	if heavy_aim:
		if _attack_just_pressed():
			_aiming = true
		if _aiming:
			if _attack_pressed():
				_advance_charge(delta)
			elif charge_time > 0.0 and not _attack_just_released():
				# 按住信号消失又没有松开边沿(暂停/菜单把输入掩掉):这一弓作取消,不让蓄力挂在陈旧的 _aiming 上继续涨。
				_aiming = false
				charge_ratio = 0.0
		if _attack_just_released():
			# ★ 语义与改动前一致:松开就发射一次(不论本帧之前是否处于预瞄态),`_aiming` 只是提前清掉。
			_aiming = false
			try_fire()
			charge_ratio = 0.0
		_update_laser()
	elif full_auto:
		if _attack_pressed():
			_tick_trigger(delta)
		else:
			_trigger_t = 0.0
	elif _attack_just_pressed():
		try_fire()
	_recoil_recover(delta)
	# 走路 bob 的相位取宿主模型帧(不是计时器);换弹/后坐/bob 的合成只在 _apply_sprite_pose 一处。
	_sample_walk_bob(_host_walk_anim(), _host_speed_x())
	_apply_sprite_pose()


# 扳机延迟:压满 trigger_delay 才允许开火。★ 冷却仍在这里判(try_fire 内部),故起转期间按住不动不会白耗冷却。
func _tick_trigger(delta: float) -> void:
	if trigger_delay <= 0.0:
		try_fire()
		return
	_trigger_t = minf(_trigger_t + delta, trigger_delay)
	if _trigger_t >= trigger_delay:
		try_fire()


func _advance_charge(delta: float) -> void:
	if charge_time > 0.0:
		charge_ratio = minf(charge_ratio + delta / charge_time, 1.0)

func try_fire() -> void:
	if fire_cd_timer > 0.0:
		# 冷却 >0.5 的武器:最后 20% 内按开火不丢弃,改为缓冲,冷却结束自动打。
		# ★ 蓄力武器不缓冲:它这一发的伤害/弹速由"这一弓"的蓄力比决定,而缓冲要等到冷却结束才出弹,那时 charge_ratio 已是下一弓的值或已清零 —— 打出去的会是错的一发。
		if fire_cooldown > 0.5 and fire_cd_timer <= fire_cooldown * 0.2 and charge_time <= 0.0:
			_fire_buffered = true
		return
	fire()

func fire() -> void:
	if not _player_ok():
		return
	if _reloading:
		return
	if mag_ammo <= 0:
		# ★ 弹数未落定(未入树窗口)时这里的 0 是声明初值,不是「空弹夹」—— 照常起换弹会把权威刚写下的 _reloading = false 冲成 true(见 _mag_ready)。
		if _mag_ready:
			start_reload()
		return
	fire_cd_timer = fire_cooldown
	# 同屏弹数上限:满员时这发不发(不耗弹,冷却已计),等场上旧弹爆掉/消失再打;只对配置了 max_live_projectiles 的武器生效。
	if max_live_projectiles > 0 and _live_projectiles() >= max_live_projectiles:
		return
	# 开火瞬间同步朝向/枪口到鼠标:直接开火(_unhandled_input,input 阶段)先于 _process,读到的是上一物理帧被走路覆盖的 get_facing(),clamp_pitch 会折到走路侧、子弹打偏;统一先 _auto_aim,所有开火路径都取本帧最新瞄准方向。
	_auto_aim()
	_apply_charge_arrow_pose()
	var base_dir := _clamped_aim_dir()
	_spawn_projectiles(base_dir)
	Sfx.play("shoot_heavy" if heavy_aim else ("shotgun" if pellet_count > 1 else "shoot"))
	mag_ammo = maxi(mag_ammo - 1, 0)
	if mag_ammo == 0:
		start_reload()
	var host := player as Player
	if host != null:
		host.apply_recoil(recoil_push)
	_recoil_timer = RECOIL_TIME
	_apply_sprite_pose()   # 立即反映后坐(不等下一 tick);bob 用上一 tick 的采样
	var cam: Camera2D = get_viewport().get_camera_2d()
	if cam != null and cam.has_method("shake"):
		cam.shake(cam_shake, cam_shake_time)

# 本发的伤害:蓄力武器按蓄力比在 charge_damage_min..damage 之间线性插值,其余枪恒为 damage。
func current_damage() -> int:
	if charge_time <= 0.0:
		return damage
	return int(round(lerpf(float(charge_damage_min), float(damage), charge_ratio)))

# 本发的弹速:同上口径,charge_speed_min..bullet_speed。
func current_bullet_speed() -> float:
	if charge_time <= 0.0:
		return bullet_speed
	return lerpf(charge_speed_min, bullet_speed, charge_ratio)

# 伤害取自出膛时的子弹,不读射手当前正在拉的下一弓。
func apply_hit(target: Node, dir: Vector2, shot_damage: int) -> void:
	if target != null and target.has_method("hurt"):
		target.hurt(shot_damage, dir, impact)

# 出弹钩子:fire() 同步朝向/冷却后调用。基类默认按 pellet 出物理子弹;即时光束类武器(激光)覆写本方法,用一次性几何追踪替代逐帧飞行的弹丸;base_dir 是已钳制仰角的瞄准方向(世界系),与默认出弹同一来源。
# ★ 两端都从这里出弹:客户端视觉弹(pvp_mode=true)与服务器权威弹(pvp_mode 恒 false)取同一份池与同一份复位。
#   服务器只跳过 Sprite2D tint 这一项表现复位(见 BulletBase.reset_for_pool);玩法字段两端一视同仁 —— 漏一项 = 两端各错一半。
func _spawn_projectiles(base_dir: Vector2) -> void:
	var shot_speed := current_bullet_speed()
	var shot_damage := current_damage()
	var spread := deg_to_rad(spread_deg)
	var scene_path := bullet_scene.resource_path
	var pool := BulletPool.shared()
	for i in pellet_count:
		var b: BulletBase = pool.acquire(scene_path)
		if b == null:
			# 回落:池构造不出来(路径空 / 加载失败)时退回旧的一次性实例,行为与池化前逐字相同。
			b = bullet_scene.instantiate()
			b.set_meta("scene_path", scene_path)
		# Beta 时间玩法(PvP):射手加速 ⇒ 出膛弹速 ×同倍率。★ 只读注入进来的 haste_mult —— 单机它恒 1(弹速倍率由 TimeField.bullet_delta 承担,不会双乘);max_range 不动:加速时弹飞得更快但射程不变。
		# ★ 原先这里读的是 player.get(pvp_haste_mult) —— 字符串反射 + 存在性探测,而宿主根的静态类型是 Node2D(它没有 class_name);现在读宿主每帧推入的 haste_mult。
		var hm := haste_mult
		var ang := base_dir.angle() + randf_range(-spread, spread)
		# ★ 局部变量,不动 bullet_speed 成员:多弹丸武器(霰弹)逐弹 ×会累积,跨发更会永久变快。
		b.setup(Vector2.from_angle(ang), shot_speed * hm, bullet_range, bullet_size, bullet_color, self)
		b.shooter = player
		b.gravity_factor = bullet_gravity
		b.hit_damage = shot_damage
		b.hit_impact = impact
		b.global_position = _charge_arrow.global_position if _charge_arrow != null else muzzle.global_position
		# PvP:本地生成的子弹只做视觉(不裁决伤害);服务器权威子弹(Level0.pvp_mode=false)照常裁决。
		b.apply_damage = not Level0.pvp_mode
		# 服务器广播 bullet_spawn 时用(场景路径在运行期实例上可能为空)。
		b.set_meta("scene_path", scene_path)
		get_viewport().add_child(b)

func _live_projectiles() -> int:
	if not is_inside_tree():
		return 0
	var n := 0
	for b in get_tree().get_nodes_in_group("bullet"):
		if is_instance_valid(b) and b.source == self:
			n += 1
	return n

func cancel_aim() -> void:
	_aiming = false
	charge_ratio = 0.0
	_trigger_t = 0.0
	if _laser != null:
		_laser.visible = false

# 是否正在预瞄(heavy_aim 蓄力中):只有 heavy_aim 武器会置 _aiming;PvP 服务器快照读它,让对手副本能看到这人在蓄力瞄准。非重武器恒 false。
func is_previewing() -> bool:
	return _aiming

# PvP:服务器权威方向驱动副本武器外观(远端对手枪):只画朝向 + 枪口旋转,不读鼠标、不开火。副本武器不 equip(player==null)、_process 早退,由 player_replica 每帧调用本方法替代(复刻 _auto_aim 的镜像/旋转,俯仰随枪 clamp)。
# ★ 预瞄线不对副本画:预瞄红线只有使用者本人可见,对手看不到你在蓄力重狙/榴弹。故本方法不收 show_preview 参数,并显式把 _aiming 压回 false(让「副本永不预瞄」成为写下来的意图);服务端快照仍带 previewing 字段,此处刻意不消费 —— 日后要改回「看得见」从这里接。
func drive_remote_visual(aim_dir: Vector2, facing: int,
		walk_anim: AnimatedSprite2D = null, walk_speed_x: float = 0.0) -> void:
	if _laser == null or muzzle == null:
		return   # _ready 的 call_deferred 尚未建好(换枪当帧),下帧再驱动
	if aim_dir == Vector2.ZERO:
		aim_dir = Vector2(float(facing), 0.0)
	_aim_facing = facing
	_current_aim_facing = facing
	rotation = clamp_pitch(aim_dir, facing, pitch_clamp_deg) * float(facing)
	scale.x = float(facing)
	_aiming = false
	_update_laser()
	# 副本的枪也要跟走路 bob(相位同样取副本自己的模型帧;额度与本地玩家同源)。
	_sample_walk_bob(walk_anim, walk_speed_x)
	_apply_sprite_pose()

func get_movement_multiplier() -> Vector2:
	var active := false
	match penalty_mode:
		PenaltyMode.NONE:
			active = false
		PenaltyMode.WHILE_FIRING:
			active = fire_cd_timer > 0.0
		PenaltyMode.WHILE_AIM_OR_COOLDOWN:
			active = _aiming or fire_cd_timer > 0.0
	if not active:
		return Vector2.ONE
	return Vector2(move_penalty, jump_penalty)

# 与枪口相同的出弹方向:经过 ±45° 仰角钳制后的世界单位向量。local.x 按 facing 折叠,还原世界坐标时再乘回 facing(与 _auto_aim 的旋转一致);折叠用 _current_aim_facing 而不是 get_facing() —— 后者会被走路输入覆盖,朝向与鼠标反侧时子弹翻折到走路侧。
func _clamped_aim_dir() -> Vector2:
	var facing := _current_aim_facing
	var pitch := clamp_pitch(_aim_world_dir(), facing, pitch_clamp_deg)
	var local := Vector2.from_angle(pitch)
	return Vector2(local.x * float(facing), local.y)

func _auto_aim() -> void:
	var dir := _aim_world_dir()
	var facing := _aim_facing
	if absf(dir.x) > 0.1:
		facing = 1 if dir.x > 0.0 else -1
		_aim_facing = facing
	var p := player as Player
	if p != null and absf(dir.x) > 0.1:
		p.set_facing(facing)
		# 冲刺时 player.set_facing 被锁(身体保持冲刺方向,位移需要),此时枪口不跟随身体翻转、保持鼠标瞄准侧;非冲刺时 set_facing 成功、get_facing() 读回一致,无差异。
		# ★ 旧写法对 is_charging 有 has_method 兜底;宿主恒为 Player ⇒ 直接读(非 Player 宿主上旧写法算 charging=false,这里走 p==null 同一分支)。
		var charging: bool = p.is_charging()
		if not charging:
			facing = get_facing()
	_current_aim_facing = facing
	# 朝向镜像(scale.x=-1)会翻转旋转方向:clamp_pitch 已按 facing 折叠 dir.x,返回值再乘 facing 取反,朝左时镜像后的枪口才指向正确的俯仰象限。
	rotation = clamp_pitch(dir, facing, pitch_clamp_deg) * float(facing)
	scale.x = float(facing)

func _update_laser() -> void:
	if _laser == null or muzzle == null:
		return
	_laser.visible = _aiming and show_aim_laser
	if not _aiming:
		_update_explosion_marker(false)
		return
	if preview_arc:
		_laser.points = _sample_arc_points()
		_update_explosion_marker(true)
	else:
		_laser.points = PackedVector2Array([muzzle.position, muzzle.position + Vector2(laser_length, 0.0)])
		_update_explosion_marker(false)

# 预瞄抛物线:与 fire 同源(v0 = 钳制瞄准方向 × speed,g = bullet_gravity × gravity0),1/60s 采样到 preview_time,途中遇墙(非 EMPTY)格截断(榴弹撞墙停驻处 = 爆炸点),并封顶 bullet_range。
func _sample_arc_points() -> PackedVector2Array:
	var pts := PackedVector2Array()
	var p := muzzle.global_position
	var start := p
	var v := _clamped_aim_dir() * bullet_speed
	var g := bullet_gravity * GameParameters.gravity0
	var dt := 1.0 / 60.0
	var t := 0.0
	# 枪口起点判墙 ⇒ 真实榴弹会挣脱墙继续飞;跳过起点段判墙,避免弧线退化成贴脸短弧。
	var escape := _disk_overlaps_solid(start)
	pts.append(to_local(p))
	while t < preview_time:
		v.y += g * dt
		# 水中阻力:与真实子弹一致(water_bullet_drag),入水后减速 ⇒ 弧线在水里更垂/更短。
		if Water.is_in_water(p):
			v *= Water.bullet_drag_factor(true, GameParameters.water_bullet_drag, dt)
		p += v * dt
		t += dt
		if escape and p.distance_to(start) < GameParameters.TILE_SIZE:
			continue  # 起点挣脱段:不判墙、不截断,榴弹正从枪口墙体里飞出
		if _disk_overlaps_solid(p):
			break
		if p.distance_to(start) >= bullet_range:
			break
		pts.append(to_local(p))
	return pts

# 预瞄判墙:以 center 为圆心、半径 6px 的小球是否压到任一墙(非 EMPTY)格(环面)。小球按格子 AABB 粗查(球很小,最多跨 2 格,不会漏;比精确圆简单且略保守,宁多判墙不少判);逐格环面判定收在 core/tile_query.gd,空网格 ⇒ false(= 无墙)。
func _disk_overlaps_solid(center: Vector2) -> bool:
	var r := PREVIEW_COLLISION_RADIUS * bullet_size
	return TileQuery.rect_overlaps_solid(
			Rect2(center - Vector2(r, r), Vector2(r * 2.0, r * 2.0)), GameParameters.TILE_SIZE)

func _update_explosion_marker(show: bool) -> void:
	if _explosion_marker == null:
		return
	_explosion_marker.visible = show
	if show and _laser.points.size() > 0:
		_explosion_marker.position = _laser.points[_laser.points.size() - 1]

func _recoil_recover(delta: float) -> void:
	# 只推进计时器;精灵 pose 由 tick() 末尾的 _apply_sprite_pose() 统一写(与 bob/换弹合成一处)。
	_recoil_timer = maxf(_recoil_timer - delta, 0.0)

func get_current_aim_dir() -> Vector2:
	return _aim_world_dir()

func _aim_world_dir() -> Vector2:
	# 网络驱动的玩家(服务器上的远端模拟)用注入的瞄准;本地玩家返回 ZERO ⇒ 落回鼠标。★ 宿主恒为 Player(有 class_name)⇒ 直接调,
	# 不再 has_method 探测:拼错方法名当场编译报错,不会静默落回"读鼠标"那条错源(非 Player 宿主 = 违约,与 null 同路落回鼠标)。
	var p := player as Player
	if p != null:
		var override: Vector2 = p.get_aim_dir_override()
		if override != Vector2.ZERO:
			return override
		# override 存在但为 ZERO(网络玩家还没收到瞄准)时:网络驱动 ⇒ 永不读宿主机 OS 鼠标(服务器 headless 上没有鼠标,读了是垃圾方向),用朝向兜底;本地 PlayerInput 的 override 恒为 ZERO ⇒ is_network_driven()==false ⇒ 走下面的鼠标路径。
		if p.input_is_network():
			return Vector2(float(get_facing()), 0.0)
	# 用基类 Viewport 而非 SubViewport:冒烟测试把武器挂到 SceneTree 根(Window),标 SubViewport 会在运行时类型检查失败(Window≠SubViewport),函数被中断返回零方向。
	var sub: Viewport = get_viewport()
	if sub == null:
		return Vector2(float(get_facing()), 0.0)
	var cam: Camera2D = sub.get_camera_2d()
	if cam == null:
		return Vector2(float(get_facing()), 0.0)
	var win: Viewport = sub.get_window()
	if win == null:
		return Vector2(float(get_facing()), 0.0)
	# 窗口鼠标 → 世界坐标:鼠标用根 Window 的真实坐标(SubViewport 的 get_mouse_position 是被 push 进去的窗口坐标,不能直接用)。相机把屏幕中心映射到 cam.global_position,world_mouse = 相机基准 + 鼠标偏移。
	var win_size := win.get_visible_rect().size
	var mouse := win.get_mouse_position()
	# 用相机无抖动的基准位置,避免镜头抖动让准星跟着跳。
	var cam_center: Vector2 = cam.global_position
	if cam.has_method("get_base_global_position"):
		cam_center = cam.get_base_global_position()
	# PostProcess 是中心裁剪(显示世界视口中心、窗口大小的区域);相机 zoom(<1 视野更大)让窗口 1px = 世界 1/zoom px,鼠标偏移按 zoom 放大回世界坐标。★ 不能 ÷crop_scale:crop 只定裁剪比例、不改像素换算,÷ 它会放大偏移,瞄准「水平」实际偏下,而榴弹枪口离地极近,弧线几步内就撞地板。
	var world_mouse := cam_center + (mouse - win_size * 0.5) / cam.zoom
	var origin := player.global_position if player != null else global_position
	var dir := world_mouse - origin
	if dir.length_squared() < 0.0001:
		return Vector2(float(get_facing()), 0.0)
	return dir.normalized()

func get_facing() -> int:
	var p := player as Player
	return p.get_facing() if p != null else 1
