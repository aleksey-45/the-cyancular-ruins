class_name WorldRewind
extends RefCounted

# 实体快照与地形共用单人关卡的录制时钟。
const FRAME_PLAYER := 1
const FRAME_ENEMIES := 2
const FRAME_BULLETS := 3

var _history := RewindHistory.new()
var _record_time := 0.0
var _acc := 0.0
var _playing := false
var _combat: CombatSimulator
var _player: Player

func _init(combat: CombatSimulator, player: Player) -> void:
	_combat = combat
	_player = player
	combat.terrain.rewind_enabled = true

func can_rewind() -> bool:
	return _history.size() >= 2

## 推进一帧并返回当前世界时间。退出回放后从同一时刻续写实体和地形。
func advance(delta: float, rewind: bool) -> float:
	var terrain := _combat.terrain
	if rewind:
		if not can_rewind():
			return _record_time
		if not _playing:
			terrain.seal_rewind(_record_time)
			_combat.clear()
			_playing = true
		var previous := _record_time - _history.rewound
		var oldest: float = _history.frame(0)[RewindHistory.TIME]
		_history.rewound = minf(TimeParams.advance_rewind(_history.rewound, delta), _record_time - oldest)
		var target := _record_time - _history.rewound
		_restore(_history.sample(target))
		terrain.rewind_between(target, previous)
		return target

	if _playing:
		_record_time = maxf(_record_time - _history.rewound, _history.frame(0)[RewindHistory.TIME])
		_history.truncate(_record_time)
		terrain.truncate_rewind(_record_time)
		_history.rewound = 0.0
		_playing = false
	_record_time += delta
	_acc += delta
	var cutoff := _record_time - TimeParams.SNAP_SECONDS
	if _acc >= 1.0 / TimeParams.SNAP_HZ:
		_acc = 0.0
		_record(cutoff)
	terrain.seal_rewind(_record_time)
	terrain.prune_rewind(cutoff)
	return _record_time

func _record(cutoff: float) -> void:
	var enemies: Array[Array] = []
	for enemy: EnemyBase in EnemyBase.in_viewport(_player.get_viewport()):
		if enemy.has_meta("elite"):
			continue
		if enemy._rewind_hold:
			if enemy.rewind_death_time < 0.0:
				enemy.rewind_death_time = _record_time
			if enemy.rewind_death_time < cutoff:
				enemy.queue_free()
				continue
		enemies.append(enemy.capture_rewind_state())
	_history.expire_before(cutoff)
	_history.push([_record_time, _player.capture_rewind_state(), enemies, _combat.capture_projectiles()])

func _restore(frame: Array) -> void:
	_player.rewind_restore(frame[FRAME_PLAYER])
	for state: Array in frame[FRAME_ENEMIES]:
		var enemy = state[EnemyBase.REWIND_NODE]
		if is_instance_valid(enemy):
			enemy.rewind_restore(state)
	_combat.rewind_projectiles(frame[FRAME_BULLETS])
