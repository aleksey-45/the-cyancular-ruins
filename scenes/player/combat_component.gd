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
			pp.flash_hit(clampf(float(damage) / float(max_hp) * 2.0, 0.5, 1.0))
	# 大伤害反馈:一次扣除生命值 >25% 最大血 → 相机震动(幅度随伤害比例增强)
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

# 爆炸击退位移:单独 move_and_collide(带碰撞),不污染 velocity。
# (地面吸收向下击退冲量后再减回去会把玩家弹起,改用独立位移结算)
func apply_knock(delta: float) -> void:
	body.move_and_collide(knock_velocity * delta)
	knock_velocity *= exp(-PlayerParams.player_knock_decay_rate * delta)

# 服务器权威倒地/复活(PvP 用;单人按 R 重载场景不涉及)。
func force_down() -> void:
	if not downed:
		_downed()

## 回溯专用:把倒地态置为 v(不扣除生命值/不发 went_down 的常规副作用,仅状态与动画)。
## 供 Player.rewind_restore 使用——"倒回到倒地那一刻"要精确复原,而不是再触发一次死亡流程。
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
