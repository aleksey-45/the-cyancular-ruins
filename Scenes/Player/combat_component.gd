class_name CombatComponent
extends Node

# 战斗子系统:生命/无敌帧/爆炸击退向量/倒地。hp_changed 由根转发给 HUD。
# 由根 player.gd 驱动(take_hit 经根转发、apply_knock/update_iframe_blink 每物理帧)。

# PvP 对局:取消命中无敌帧——每发子弹都要能结算(否则霰弹只算第一丸)。
# 帧伤防范靠「每发弹丸命中即销毁、只结算一次」,由服务器裁决保证。
static var pvp_arena := false


signal hp_changed(current: int, max: int)
signal went_down   # 倒地瞬间触发,根连到 weapons.cancel_aim(保持旧 _downed 里的取消瞄准)
signal took_hit(source_pos: Vector2, damage: int)  # 实际造成一次伤害(服务器 MatchHost 接它广播受击反馈)

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
	# PvP:取消无敌帧阻挡(pvp_arena),但仍每发结算一次(命中即销毁由裁决保证)。
	if downed or (not pvp_arena and iframes > 0.0 and not ignore_iframes):
		return
	# 冲刺被打断:否则下一帧 is_charge 分支会用冲刺速度覆盖本次击退
	body.cancel_charge()
	hp -= damage
	took_hit.emit(source_pos, damage)
	Sfx.play("hurt")
	iframes = PlayerParams.iframes_time
	# 击退方向用环面最短向量,不用绝对相减:
	# PvP 服务器权威下,命中源坐标(服务器子弹/爆心)锚在射手副本上,可能与该玩家 canonical
	# 相差约整幅地图(跨接缝对枪)——绝对 (body - source) 会得出反向击退(受击被打向射手)。
	# 最短位移保证"沿命中来向把玩家推离"(与命中判定/HitEvent 的 toroidal 距离一致)。
	var away := (body.global_position - source_pos).normalized()
	if GameParameters.MAP_WIDTH > 0.0 and GameParameters.MAP_HEIGHT > 0.0:
		var short_vec := MazeGenerator.toroidal_delta_px(source_pos, body.global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		if not short_vec.is_zero_approx():
			away = short_vec.normalized()
	if away == Vector2.ZERO:
		away = Vector2(-float(body.get_facing()), 0.0)
	if knockback < 0.0:
		# 常规命中:固定击退直接覆盖(原行为)
		body.velocity.x = away.x * PlayerParams.player_hit_knockback
		body.velocity.y = away.y * PlayerParams.player_hit_knockback - PlayerParams.player_hit_knockback_up
	else:
		# 爆炸:设独立击退向量(叠加,不覆盖移动),随帧指数衰减
		knock_velocity = away * knockback
	# 受击反馈(每次命中):画面微红一瞬间 + 小幅屏幕震动。
	# 大伤害(>25% 最大血)原有的强震保持不变(下面 hit_ratio 分支)。
	var tree := body.get_tree()
	if tree != null:
		var pp := tree.get_first_node_in_group("post_process")
		if pp != null and pp.has_method("flash_hit"):
			pp.flash_hit(clampf(float(damage) / float(max_hp) * 2.0, 0.35, 1.0))
	# 大伤害反馈:一次扣血 >25% 最大血 → 相机震动(幅度随伤害比例增强)
	var hit_ratio := float(damage) / float(max_hp)
	var cam: Camera2D = body.get_viewport().get_camera_2d()
	if cam != null and cam.has_method("shake"):
		if hit_ratio > 0.25:
			cam.shake(PlayerParams.hit_cam_shake * (hit_ratio / 0.25), PlayerParams.hit_cam_shake_time)
		else:
			cam.shake(4.0, 0.12)   # 小伤害也给一点震感
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
