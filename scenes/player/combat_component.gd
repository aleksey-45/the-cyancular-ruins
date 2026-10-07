class_name CombatComponent
extends Node

# 战斗子系统：负责管理生命值、受击无敌帧、击退向量与倒地状态。hp_changed 信号由根节点转发给 HUD。
# 由根节点 player.gd 在物理帧中驱动更新。

# PvP 对战模式下取消常规受击无敌帧，确保多发弹丸（如霰弹枪散布）能够分别准确结算伤害。
# 防重复伤害由服务端权威判定保证（每颗弹丸命中后立即销毁并仅结算单次有效伤害）。
static var pvp_arena := false


signal hp_changed(current: int, max: int)
signal went_down   # 倒地瞬间触发，根节点接收后调用 weapons.cancel_aim 取消瞄准
signal took_hit(source_pos: Vector2, damage: int)  # 受到有效伤害（服务端 MatchHost 接收后广播受击反馈）

var max_hp: int = PlayerParams.player_max_hp
var hp: int = PlayerParams.player_max_hp
var iframes: float = 0.0
var downed: bool = false
var knock_velocity: Vector2 = Vector2.ZERO  # 爆炸专属击退向量（独立于常规移动速度，按指数衰减）

var body: CharacterBody2D

const IFRAME_BLINK_RATE := 20.0   # 受击无敌帧闪烁频率（每秒明暗切换次数）

func _ready() -> void:
	body = get_parent() as CharacterBody2D

func is_downed() -> bool:
	return downed

# 无敌帧时间递减与闪烁表现，每物理帧在移动逻辑执行前调用。
func update_iframe_blink(delta: float) -> void:
	iframes = maxf(iframes - delta, 0.0)
	if iframes > 0.0:
		body.modulate.a = 0.4 if int(iframes * IFRAME_BLINK_RATE) % 2 == 0 else 1.0
	else:
		body.modulate.a = 1.0

func take_hit(source_pos: Vector2, damage: int, ignore_iframes: bool = false, knockback: float = -1.0) -> void:
	# ignore_iframes: 特殊攻击（如冲撞）无视无敌帧阻挡，命中后照常重置 iframes
	# PvP 模式取消无敌帧阻挡（pvp_arena），但仍保证每颗弹丸独立结算单次伤害
	if downed or (not pvp_arena and iframes > 0.0 and not ignore_iframes):
		return
	# 受击打断冲刺状态，防止后续冲刺速度覆盖本次击退速度
	body.cancel_charge()
	hp -= damage
	took_hit.emit(source_pos, damage)
	Sfx.play("hurt")
	iframes = PlayerParams.iframes_time
	# 击退方向采用环面最短位移向量计算，而非简单绝对坐标相减：
	# 在环面循环地图与多人网络同步下，跨越接缝对射时命中源坐标与受击玩家可能相距近整张地图宽度，
	# 简单的 (body - source) 坐标相减会导致反向击退异常。
	# 使用环面最短位移向量（toroidal_delta_px）能够准确沿子弹来向将玩家向外推离。
	var away := (body.global_position - source_pos).normalized()
	if GameParameters.MAP_WIDTH > 0.0 and GameParameters.MAP_HEIGHT > 0.0:
		var short_vec := MazeGenerator.toroidal_delta_px(source_pos, body.global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		if not short_vec.is_zero_approx():
			away = short_vec.normalized()
	if away == Vector2.ZERO:
		away = Vector2(-float(body.get_facing()), 0.0)
	if knockback < 0.0:
		# 常规受击：施加固定击退初速度
		body.velocity.x = away.x * PlayerParams.player_hit_knockback
		body.velocity.y = away.y * PlayerParams.player_hit_knockback - PlayerParams.player_hit_knockback_up
	else:
		# 爆炸受击：设置独立击退向量，按指数衰减结算
		knock_velocity = away * knockback
	# 受击屏幕反馈：微红闪烁与相机震动
	var tree := body.get_tree()
	if tree != null:
		var pp := tree.get_first_node_in_group("post_process")
		if pp != null and pp.has_method("flash_hit"):
			pp.flash_hit(clampf(float(damage) / float(max_hp) * 2.0, 0.5, 1.0))
	# 大伤害反馈：扣血超过 25% 时强化相机震动幅度
	var hit_ratio := float(damage) / float(max_hp)
	var cam: Camera2D = body.get_viewport().get_camera_2d()
	if cam != null and cam.has_method("shake"):
		if hit_ratio > 0.25:
			cam.shake(PlayerParams.hit_cam_shake * (hit_ratio / 0.25), PlayerParams.hit_cam_shake_time)
		else:
			cam.shake(6.0, 0.15)
	hp_changed.emit(hp, max_hp)
	if hp <= 0:
		_downed()

# 爆炸击退位移结算：通过独立的碰撞移动结算，避免击退速度污染角色常规移动速度
func apply_knock(delta: float) -> void:
	body.move_and_collide(knock_velocity * delta)
	knock_velocity *= exp(-PlayerParams.player_knock_decay_rate * delta)

# 服务端权威倒地设置（多人模式使用）
func force_down() -> void:
	if not downed:
		_downed()

# 时空回溯状态设置：将倒地状态恢复至快照记录，不重复触发死亡事件
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
	# 复位后处理屏幕变灰特效
	var tree := body.get_tree()
	if tree != null:
		var pp := tree.get_first_node_in_group("post_process")
		if pp != null and pp.has_method("set_downed"):
			pp.set_downed(false)

func _downed() -> void:
	downed = true
	# 倒地状态下保持物理模拟，角色精灵倒地旋转
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
