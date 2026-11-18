class_name RewindHistory
extends RefCounted

# 第一槽是单调递增的时间。过期帧清空引用，前缀过半时再压缩数组。
const TIME := 0
var rewound := 0.0
var _frames: Array = []
var _head := 0

func size() -> int:
	return _frames.size() - _head

func frame(index: int) -> Array:
	return _frames[_head + index]

func push(value: Array) -> void:
	_frames.append(value)

func expire_before(time: float) -> void:
	while _head < _frames.size() and float(_frames[_head][TIME]) < time:
		_drop_first()
	_compact()

func keep_last(count: int) -> void:
	while size() > count:
		_drop_first()
	_compact()

func _drop_first() -> void:
	_frames[_head] = null
	_head += 1

func _compact() -> void:
	if _head > 0 and _head * 2 >= _frames.size():
		_frames = _frames.slice(_head)
		_head = 0

func sample(time: float) -> Array:
	return frame(maxi(0, first_after(time) - 1))

func truncate(time: float) -> void:
	_frames.resize(_head + first_after(time))
	_compact()

## 跳过所有等于 time 的帧，返回当前有效区间内的下标。
func first_after(time: float) -> int:
	var low := _head
	var high := _frames.size()
	while low < high:
		var middle := (low + high) / 2
		if float(_frames[middle][TIME]) <= time:
			low = middle + 1
		else:
			high = middle
	return low - _head
