class_name CombatComponent
extends Node

# 战斗子系统:生命/无敌帧/爆炸击退向量/倒地。hp_changed 由根转发给 HUD。
# 由根 player.gd 驱动(take_hit 经根转发、apply_knock/update_iframe_blink 每物理帧)。

signal hp_changed(current: int, max: int)
signal went_down   # 倒地瞬间触发,根连到 weapons.cancel_aim(保持旧 _downed 里的取消瞄准)

var max_hp: int = PlayerParams.player_max_hp
var hp: int = PlayerParams.player_max_hp
var iframes: float = 0.0
var downed: bool = false
var knock_velocity: Vector2 = Vector2.ZERO  # 爆炸专属击退向量(独立于移动速度,指数衰减)

var body: CharacterBody2D

const IFRAME_BLINK_RATE := 20.0   # 无敌帧闪烁频率(每秒明暗切换次数)

func _ready() -> void:
	body = get_parent() as CharacterBody2D

func is_downed() -> bool:
	return downed

# 无敌帧递减 + 闪烁,每物理帧由根在移动逻辑前调用。
func update_iframe_blink(delta: float) -> void:
	iframes = maxf(iframes - delta, 0.0)
	if iframes > 0.0:
		body.modulate.a = 0.4 if int(iframes * IFRAME_BLINK_RATE) % 2 == 0 else 1.0
	else:
		body.modulate.a = 1.0

func take_hit(source_pos: Vector2, damage: int, ignore_iframes: bool = false, knockback: float = -1.0) -> void:
	# ignore_iframes: 特殊攻击(如冲撞)穿透无敌帧,但命中后照常刷新 iframes。
	if downed or (iframes > 0.0 and not ignore_iframes):
		return
	# 冲刺被打断:否则下一帧 is_charge 分支会用冲刺速度覆盖本次击退
	body.cancel_charge()
	hp -= damage
	iframes = PlayerParams.iframes_time
	var away := (body.global_position - source_pos).normalized()
	if away == Vector2.ZERO:
		away = Vector2(-float(body.get_facing()), 0.0)
	if knockback < 0.0:
		# 常规命中:固定击退直接覆盖(原行为)
		body.velocity.x = away.x * PlayerParams.player_hit_knockback
		body.velocity.y = away.y * PlayerParams.player_hit_knockback - PlayerParams.player_hit_knockback_up
	else:
		# 爆炸:设独立击退向量(叠加,不覆盖移动),随帧指数衰减
		knock_velocity = away * knockback
	# 大伤害反馈:一次扣血 >25% 最大血 → 相机震动(幅度随伤害比例增强)
	var hit_ratio := float(damage) / float(max_hp)
	if hit_ratio > 0.25:
		var cam: Camera2D = body.get_viewport().get_camera_2d()
		if cam != null and cam.has_method("shake"):
			cam.shake(PlayerParams.hit_cam_shake * (hit_ratio / 0.25), PlayerParams.hit_cam_shake_time)
	hp_changed.emit(hp, max_hp)
	if hp <= 0:
		_downed()

# 爆炸击退位移:单独 move_and_collide(带碰撞),不污染 velocity。
# (地面把向下击退吃掉后再减回去会把玩家弹起,改用独立位移结算)
func apply_knock(delta: float) -> void:
	body.move_and_collide(knock_velocity * delta)
	knock_velocity *= exp(-PlayerParams.player_knock_decay_rate * delta)

# 服务器权威倒地/复活(PvP 用;单人按 R 重载场景不涉及)。
func force_down() -> void:
	if not downed:
		_downed()

func revive() -> void:
	if not downed:
		return
	downed = false
	hp = max_hp
	body.rotation = 0.0
	var animator: AnimatedSprite2D = body.animator
	if animator != null:
		animator.play("idle")
	# 复位倒地变灰:_downed() 只 set_downed(true),不复位则复活后屏幕一直灰(PvP 回合复活)。
	var tree := body.get_tree()
	if tree != null:
		var pp := tree.get_first_node_in_group("post_process")
		if pp != null and pp.has_method("set_downed"):
			pp.set_downed(false)

func _downed() -> void:
	downed = true
	# 不取消物理:保留当前速度/击退,尸体继续受重力/冲击(与敌人统一)
	body.rotation = -PI / 2.0 * float(body.get_facing())
	var animator: AnimatedSprite2D = body.animator
	if animator != null:
		animator.stop()
	went_down.emit()
	var tree := body.get_tree()
	if tree != null:
		var pp := tree.get_first_node_in_group("post_process")
		if pp != null and pp.has_method("set_downed"):
			pp.set_downed(true)
