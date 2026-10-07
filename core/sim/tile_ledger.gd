class_name TileLedger
extends RefCounted

# 场景瓦片破坏历史账本：记录场景瓦片被破坏前的原始图层数据，时空回溯时按逆序还原网格与碰撞。
# 与 WorldRewind 共用同一时间轴（由关卡传入 recorded_seconds() 作为时间戳 t）。
# 纯逻辑数据结构，不依赖场景树，便于单元测试。
#
# 核心规则：
#   - 记录瓦片被破坏前的原始值，同一瓦片多次变动时按时间戳倒序还原（后进先出）。
#   - 超出时间窗口（TimeParams.SNAP_SECONDS）的历史条目自动裁剪释放。

var _entries: Array = []   # [{t: float, cells: [{cell: Vector2i, v: int}]}],按 t 升序


func record(t: float, cells: Array) -> void:
	if cells.is_empty():
		return
	_entries.append({"t": t, "cells": cells.duplicate()})


func count() -> int:
	var n := 0
	for e in _entries:
		n += (e["cells"] as Array).size()
	return n


func newest_t() -> float:
	return float(_entries[-1]["t"]) if not _entries.is_empty() else -1.0


## 取 (target_t, cursor_t] 区间内待还原的格,按 t 降序(最新破坏先还原)。
func take_range(target_t: float, cursor_t: float) -> Array:
	var picked: Array = []
	for e in _entries:
		var t := float(e["t"])
		if t > target_t and t <= cursor_t:
			picked.append(e)
	picked.sort_custom(func(a, b): return float(a["t"]) > float(b["t"]))
	return picked


## 裁掉早于 cutoff 的条目(超出回溯窗口的破坏不可再还原)
func prune(cutoff_t: float) -> void:
	while not _entries.is_empty() and float(_entries[0]["t"]) < cutoff_t:
		_entries.pop_front()


## 裁掉晚于 t 的条目(回溯出口之后的"被复写未来"从账上消失;与 WorldRewind.finish 对齐)
func prune_after(t: float) -> void:
	while not _entries.is_empty() and float(_entries[-1]["t"]) > t:
		_entries.pop_back()
