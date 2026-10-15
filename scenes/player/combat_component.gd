class_name CombatComponent
extends Node

# 战斗子系统:生命/无敌帧/爆炸击退向量/倒地;由根 player.gd 驱动(take_hit 经根转发、apply_knock/update_iframe_blink 每物理帧),hp_changed 由根转发给 HUD。

# PvP 取消命中无敌帧(否则霰弹只算第一丸),帧伤防范靠「每发弹丸命中即销毁、只结算一次」由服务器裁决保证。
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

func update_iframe_blink(delta: float) -> void:
	iframes = maxf(iframes - delta, 0.0)
	if iframes > 0.0:
		body.modulate.a = 0.4 if int(iframes * IFRAME_BLINK_RATE) % 2 == 0 else 1.0
	else:
		body.modulate.a = 1.0

func take_hit(source_pos: Vector2, damage: int, ignore_iframes: bool = false, knockback: float = -1.0) -> void:
	# ignore_iframes:特殊攻击(如冲撞)穿透无敌帧但照常刷新;PvP 取消无敌帧阻挡,仍每发只结算一次。
	if downed or (not pvp_arena and iframes > 0.0 and not ignore_iframes):
		return
	# 冲刺被打断:否则下一帧 is_charge 分支会用冲刺速度覆盖本次击退
	body.cancel_charge()
	hp -= damage
	took_hit.emit(source_pos, damage)
	Sfx.play("hurt")
	iframes = PlayerParams.iframes_time
	# ★ 击退方向必须用环面最短向量,不能绝对相减:服务器权威下命中源坐标(服务器子弹/爆心)锚在射手副本上,可能与本玩家 canonical 相差约整幅地图(跨接缝对枪),绝对相减会得出反向击退。
	var away := (body.global_position - source_pos).normalized()
	if GameParameters.MAP_WIDTH > 0.0 and GameParameters.MAP_HEIGHT > 0.0:
		var short_vec := MazeGenerator.toroidal_delta_px(source_pos, body.global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		if not short_vec.is_zero_approx():
			away = short_vec.normalized()
	if away == Vector2.ZERO:
		away = Vector2(-float(body.get_facing()), 0.0)
	if knockback < 0.0:
		body.velocity.x = away.x * PlayerParams.player_hit_knockback
		body.velocity.y = away.y * PlayerParams.player_hit_knockback - PlayerParams.player_hit_knockback_up
	else:
		knock_velocity = away * knockback
	# 受击反馈:每次命中小红闪 + 小幅震动;大伤害(扣血 >25% 最大血)的强震见下面 hit_ratio 分支。
	var tree := body.get_tree()
	if tree != null:
		var pp := tree.get_first_node_in_group("post_process")
		if pp != null and pp.has_method("flash_hit"):
			pp.flash_hit(clampf(float(damage) / float(max_hp) * 2.0, 0.5, 1.0))
	var hit_ratio := float(damage) / float(max_hp)
	var cam: Camera2D = body.get_viewport().get_camera_2d()
	if cam != null and cam.has_method("shake"):
		if hit_ratio > 0.25:
			cam.shake(PlayerParams.hit_cam_shake * (hit_ratio / 0.25), PlayerParams.hit_cam_shake_time)
		else:
			cam.shake(6.0, 0.15)   # 小伤害也给一点震感
	hp_changed.emit(hp, max_hp)
	if hp <= 0:
		_downed()

# 爆炸击退位移:单独 move_and_collide 结算,不污染 velocity —— 地面吃掉向下击退后再减回去会把玩家弹起。
func apply_knock(delta: float) -> void:
	body.move_and_collide(knock_velocity * delta)
	knock_velocity *= exp(-PlayerParams.player_knock_decay_rate * delta)

# 服务器权威倒地/复活(PvP 用;单人按 R 重载场景不涉及)。
func force_down() -> void:
	if not downed:
		_downed()

## 回溯专用:把倒地态置为 v,不扣血、不发 went_down、不再触发死亡流程 —— 供 Player.rewind_restore 精确复原。
func set_downed_by_rewind(v: bool) -> void:
	if downed == v:
		return
	downed = v
	var animator: AnimatedSprite2D = body.animator
	if animator != null:
		animator.play("downed" if v else "idle")
	if v:
		went_down.emit()


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
