class_name CombatComponent
extends Node

# 战斗子系统：负责生命值、受击无敌帧、击退向量与倒地状态。HUD 由 Player.present_tick 更新。
# 由根节点 player.gd 在物理帧中驱动更新。

# PvP 对战模式下取消常规受击无敌帧，确保多发弹丸（如霰弹枪散布）能够分别准确结算伤害。
# 防重复伤害由服务端权威判定保证（每颗弹丸命中后立即销毁并仅结算单次有效伤害）。
static var pvp_arena := false


signal went_down   # 倒地瞬间触发，根节点接收后调用 weapons.cancel_aim 取消瞄准
signal took_hit(source_pos: Vector2, damage: int)

var max_hp: int:
	get: return (get_parent() as NativeActorBody).sim_max_hp
	set(value): (get_parent() as NativeActorBody).sim_max_hp = value
var hp: int:
	get: return (get_parent() as NativeActorBody).sim_hp
	set(value): (get_parent() as NativeActorBody).sim_hp = value
var iframes: float:
	get: return (get_parent() as NativeActorBody).sim_iframes
	set(value): (get_parent() as NativeActorBody).sim_iframes = value
var downed: bool:
	get: return (get_parent() as NativeActorBody).sim_downed
	set(value): (get_parent() as NativeActorBody).sim_downed = value
var knock_velocity: Vector2:
	get: return (get_parent() as NativeActorBody).motion_knock_velocity
	set(value): (get_parent() as NativeActorBody).motion_knock_velocity = value

var body: Player

const IFRAME_BLINK_RATE := 20.0   # 受击无敌帧闪烁频率（每秒明暗切换次数）

func _ready() -> void:
	body = get_parent() as Player

func is_downed() -> bool:
	return downed

# 无敌帧由共享步进递减；闪烁只在最终状态确定后更新。
func present() -> void:
	if iframes > 0.0:
		body.modulate.a = 0.4 if int(iframes * IFRAME_BLINK_RATE) % 2 == 0 else 1.0
	else:
		body.modulate.a = 1.0

func take_hit(source_pos: Vector2, damage: int, ignore_iframes: bool = false, knockback: float = -1.0) -> void:
	# ignore_iframes: 特殊攻击（如冲撞）无视无敌帧阻挡，命中后照常重置 iframes
	# PvP 模式取消无敌帧阻挡（pvp_arena），但仍保证每颗弹丸独立结算单次伤害
	if downed or (not pvp_arena and iframes > 0.0 and not ignore_iframes):
		return
	simulate_hit(source_pos, damage, knockback)
	took_hit.emit(source_pos, damage)

# 权威模拟与预测共用受击状态更新；事件和音画由外层处理。
func simulate_hit(source_pos: Vector2, damage: int, knockback: float) -> void:
	if body.native_simulate_hit(source_pos, damage, knockback): went_down.emit()

func apply_impulse(source_pos: Vector2, knockback: float) -> void:
	body.native_apply_impulse(source_pos, knockback)

func force_down() -> void:
	if not downed:
		_downed()

# 时空回溯状态设置：将倒地状态恢复至快照记录，不重复触发死亡事件
func set_downed_by_rewind(v: bool) -> void:
	if downed == v:
		return
	downed = v
	body.rotation = -PI / 2.0 * float(body.get_facing()) if v else 0.0
	body._grounded = false
	body.apply_collision_pose()
	if v:
		went_down.emit()


func revive() -> void:
	if not downed:
		return
	downed = false
	hp = max_hp
	body.rotation = 0.0
	body._grounded = false
	body.apply_collision_pose()

func _downed() -> void:
	if body.native_force_down(): went_down.emit()
