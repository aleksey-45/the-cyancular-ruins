class_name WorldRewind
extends RefCounted

# 世界时空回溯系统：定频快照环形缓冲区与状态回放器，负责关键实体状态的定频记录与倒流回放。
#
# 架构设计：与 Terrain 的地形历史协同工作，本模块负责实体状态回溯：
#   - record()：常态下以定频（TimeParams.SNAP_HZ）记录关键实体状态（玩家、普通敌人、子弹）。
#   - step()：回溯激活时沿时间轴逆序回放，一次性还原实体的物理状态与子弹位置。
#   - 精英敌人豁免：精英单位不受回溯影响，保持自主行为。
#   - 击败实体保留：在快照窗口内被击败的敌人隐藏其物理和渲染节点，回溯至击败时刻前则恢复存活。
#   - 回溯期间伤害免疫：实体在 TimeField.is_rewinding() 期间免疫外部常规伤害，玩家输入被暂时挂起。

const FRAME_TIME: int = 0
const FRAME_PLAYER: int = 1
const FRAME_ENEMIES: int = 2
const FRAME_BULLETS: int = 3

const BULLET_ID: int = 0
const BULLET_TYPE_ID: int = 1
const BULLET_SOURCE: int = 2
const BULLET_DAMAGE: int = 3
const BULLET_MOTION: int = 4

# 最老的有效帧在 _head，之后按时间顺序读取 _count 个槽。
var _frames: Array = []
var _head := 0
var _count := 0
var _t := 0.0                      # 世界已录制时间(秒)
var _acc := 0.0
var _cursor := 0.0
var _combat: CombatSimulator

func _init(combat: CombatSimulator) -> void:
	_combat = combat

func record(delta: float, player: Player, enemies: Array) -> void:
	_t += delta
	_acc += delta
	if _acc < 1.0 / float(TimeParams.SNAP_HZ):
		return
	_acc = 0.0
	var cutoff := _t - TimeParams.SNAP_SECONDS
	var enemy_states: Array[Array] = []
	for enemy: EnemyBase in enemies:
		if enemy.has_meta("elite"):
			continue
		# 尸体只在录制时间推进时过期，暂停和回放不会缩短保留期。
		if enemy._rewind_hold:
			if enemy.rewind_death_time < 0.0:
				enemy.rewind_death_time = _t
			if enemy.rewind_death_time < cutoff:
				enemy.queue_free()
				continue
		enemy_states.append(enemy.capture_rewind_state())
	var bullet_states: Array[Array] = []
	for bullet: BulletBody in _combat.projectiles.values():
		var state := [bullet.entity_id, bullet.type_id, bullet._source_id, bullet.hit_damage]
		bullet.append_motion_state(state)
		bullet_states.append(state)
	while _count > 0 and float(_frames[_head][FRAME_TIME]) < cutoff:
		_frames[_head] = null
		_head = _frame_slot(1)
		_count -= 1
	_append_frame([_t, player.capture_rewind_state(), enemy_states, bullet_states])

func _frame_slot(index: int) -> int:
	return (_head + index) % _frames.size()

func _append_frame(frame: Array) -> void:
	if _count == _frames.size():
		var grown: Array = []
		grown.resize(maxi(1, _count * 2))
		for index in _count:
			grown[index] = _frames[_frame_slot(index)]
		_frames = grown
		_head = 0
	_frames[_frame_slot(_count)] = frame
	_count += 1

func can_rewind() -> bool:
	return _count >= 2

func begin() -> void:
	_cursor = 0.0
	if can_rewind():
		_combat.clear()


## 退出时空回溯：裁剪回溯出口之后的时间轴数据，保持时间线连续一致。
## 时间轴游标重置至回溯出口，后续 record() 从该时刻继续追加录制。
## 保证多次连续回溯历史状态互不冲突，避免重复回放已被覆写的时间段。
## 返回出口时刻(磁带新末尾),Level0 用它把瓦片账本裁到同一位置。
func finish() -> float:
	var exit_t := _t - _cursor
	if _count > 0:
		var last := _last_frame_index(exit_t)
		while _count > last + 1:
			_count -= 1
			_frames[_frame_slot(_count)] = null
		_t = maxf(exit_t, float(_frames[_frame_slot(last)][FRAME_TIME]))
	_cursor = 0.0
	return _t

func step(delta: float, player: Player) -> void:
	if not can_rewind():
		return
	var oldest: float = _frames[_head][FRAME_TIME]
	_cursor = minf(TimeParams.advance_rewind(_cursor, delta), _t - oldest)
	_apply(_frames[_frame_slot(_last_frame_index(current_target()))], player)


func _last_frame_index(target: float) -> int:
	var low := 0
	var high := _count
	while low < high:
		var middle := (low + high) / 2
		if float(_frames[_frame_slot(middle)][FRAME_TIME]) <= target:
			low = middle + 1
		else:
			high = middle
	return maxi(0, low - 1)

func _apply(frame: Array, player: Player) -> void:
	if is_instance_valid(player):
		player.rewind_restore(frame[FRAME_PLAYER])
	for state: Array in frame[FRAME_ENEMIES]:
		if is_instance_valid(state[EnemyBase.REWIND_NODE]):
			var enemy: EnemyBase = state[EnemyBase.REWIND_NODE]
			enemy.rewind_restore(state)
	_apply_bullets(frame[FRAME_BULLETS])


func _apply_bullets(states: Array) -> void:
	var wanted := {}
	for state: Array in states:
		var id: int = state[BULLET_ID]
		wanted[id] = true
		var bullet: BulletBody = _combat.projectiles.get(id)
		if bullet == null:
			bullet = _combat.spawn_projectile(id, state[BULLET_TYPE_ID], state[BULLET_SOURCE],
					state[BULLET_MOTION + BulletBody.MOTION_POS], state[BULLET_MOTION + BulletBody.MOTION_VEL],
					state[BULLET_DAMAGE])
		bullet.restore_motion(state, BULLET_MOTION)
	for id: int in _combat.projectiles.keys():
		if not wanted.has(id):
			_combat.erase_projectile(id)

## 当前回放目标时间(秒):瓦片账本按同一时间轴取区间还原。
func current_target() -> float:
	return _t - _cursor


func recorded_seconds() -> float:
	return _t
