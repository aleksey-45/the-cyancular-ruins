extends "res://Scenes/Weapons/prop_launcher.gd"

# 计时爆炸团(卡 pr_731505,槽 11):按下开火 = 拉销点燃——倒计时(默认 6s)立即开始,
# 屏幕中央显示像素倒计时数字;再按一次 = 把燃烧中的弹体掷向瞄准方向;倒计时走完仍未掷出
# → 在原地(持弹者脚下)爆炸(卡特殊要求)。
# 结算:爆炸伤上限=满血(explosion_damage=PlayerParams.player_max_hp,blast_falloff_mode=
# LINEAR 与爆心距离线性衰减)+ 轻度速度击退(explosion_knockback=2600≈260px 位移)。
# 引信唯一时间源 = TimedBombFuse(挂世界,不随切枪消失);掷出经 _lit_fuse 把剩余时间
# 带进投掷物,手持段与飞行段同一根引信;点燃即耗弹(烧在手里也损失这枚,自爆惩罚成立)。

@export var countdown_time := 6.0   # 倒计时(秒):按下开始计时,到点未掷出就在原地爆炸

var _fuse: TimedBombFuse = null   # 手持中的引信节点(掷出后置 null,弹自己走剩余引信)


func fire() -> void:
	if not _player_ok():
		return
	if _fuse != null and is_instance_valid(_fuse) and _fuse.armed_in_hand:
		_throw_bomb()
	else:
		_arm_bomb()


## 第一按:拉销点燃(不掷出)。耗 1 枚携带量,起 6s 倒计时(屏幕中央像素数字)。
func _arm_bomb() -> void:
	if mag_ammo <= 0:
		Sfx.play("deny")   # 打完即无(道具不换弹):空手按 = 拒绝
		return
	mag_ammo -= 1
	fire_cd_timer = fire_cooldown   # 拉销与掷出之间至少隔一个投掷间隔(防同帧点两下)
	_fuse = TimedBombFuse.new()
	_fuse.total = countdown_time
	_fuse.remaining = countdown_time
	_fuse.holder = player
	_fuse.blast_radius = blast_radius
	_fuse.blast_damage = explosion_damage
	_fuse.blast_knockback = explosion_knockback
	_fuse.falloff_mode = blast_falloff_mode
	_fuse.visual_scene = explosion_visual
	get_viewport().add_child(_fuse)
	Sfx.play("reload")   # 拉销:两段机械咔哒(与换弹同款音色)
	_throw_anim()


## 第二按:掷出燃烧中的弹体。剩余引信随弹走(到点即爆,与是否碰撞无关)。
func _throw_bomb() -> void:
	var remaining: float = _fuse.remaining
	_fuse.armed_in_hand = false   # 引信节点只剩倒计时显示职责,起爆移交投掷物
	_fuse = null
	fire_cd_timer = fire_cooldown
	# 与基类 fire() 同序:开火瞬间先同步朝向/枪口再取本帧瞄准方向(不读走路覆盖的朝向)
	_auto_aim()
	_lit_fuse = remaining
	_spawn_projectiles(_clamped_aim_dir())
	_lit_fuse = -1.0
	Sfx.play("shoot")
	var cam: Camera2D = get_viewport().get_camera_2d()
	if cam != null and cam.has_method("shake"):
		cam.shake(cam_shake, cam_shake_time)
	_throw_anim()
