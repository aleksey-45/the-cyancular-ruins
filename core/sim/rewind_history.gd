class_name RewindHistory
extends RefCounted

enum { TIME, SNAPSHOT }
var time := 0.0
var _frames: Array = []
var _first := 0
var _since_sample := 0.0
var _rewound := -1.0
var _combat: CombatSimulator
var _scope: int
var _seconds: float

func _init(combat: CombatSimulator, scope := CombatSnapshot.WORLD, seconds := TimeParams.SNAP_SECONDS) -> void:
	_combat = combat
	_scope = scope
	_seconds = seconds
	if scope == CombatSnapshot.WORLD:
		combat.terrain.rewind_enabled = true

func can_rewind() -> bool:
	return not _frames.is_empty() and (_rewound >= 0.0 or time > float(_frames[_first][TIME]))

func oldest_time() -> float:
	return time if _frames.is_empty() else float(_frames[_first][TIME])

## 同帧采样的角色共用一个检查点，各自记录这个检查点在个人时间轴上的时刻。
func record(delta: float, sample: CombatSnapshot = null) -> CombatSnapshot:
	_rewound = -1.0
	time += delta
	_since_sample += delta
	if _since_sample < TimeParams.SNAP_INTERVAL:
		return sample
	_since_sample = 0.0
	if sample == null:
		sample = CombatSnapshot.new()
		sample.capture(_combat)
	if _scope == CombatSnapshot.WORLD:
		sample.capture_environment(_combat)
	_frames.append([time, sample])
	while _frames[_first][TIME] < time - _seconds:
		_frames[_first] = null
		_first += 1
	if _first * 2 >= _frames.size():
		_frames = _frames.slice(_first)
		_first = 0
	return sample

func rewind(delta: float, hit_elites := true) -> void:
	var world := _scope == CombatSnapshot.WORLD
	var terrain := _combat.terrain
	if _rewound < 0.0:
		_rewound = 0.0
		_since_sample = 0.0
		if world:
			terrain.undo_changes(terrain.take_rewind_changes())
			for bullet: BulletBody in _combat.projectiles.values():
				bullet.rewind_hits.clear()
	var target := maxf(oldest_time(), time - TimeParams.rewind_delta(_rewound, delta))
	_rewound += time - target
	time = target
	while _frames.back()[TIME] > time:
		var later: Array = _frames.pop_back()
		if world:
			var snapshot: CombatSnapshot = later[SNAPSHOT]
			terrain.undo_changes(snapshot.terrain_changes)
	if world:
		terrain.flush_collisions()
	var selected: CombatSnapshot = _frames.back()[SNAPSHOT]
	selected.restore(_combat, _scope)
	if world and hit_elites:
		_combat.hit_rewound_elites()
