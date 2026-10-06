class_name TileLedger
extends RefCounted

# 场景瓦片回溯记录账本：记录每次破坏的瓦片单元及其破坏前的原始状态，回溯时按时间逆序（LIFO）还原。
# 与 WorldRewind 共享同一时间轴（由 Level0 传入 WorldRewind.recorded_seconds() 作为时间戳 t）。
# 纯数据结构（支持 -s 独立测试）；具体写回网格与场景由 Level0 的 _restore_cell 执行。
#
# 设计要点：
#   · 当前仅记录玩家造成的场景破坏（由 Level0 在 _on_tile_destroyed 中捕获）。
#   · 同一网格若发生多次破坏与生成，还原时必须按时间降序（LIFO）执行，确保优先还原最近一次的状态。
#   · 超出历史记录窗口（TimeParams.SNAP_SECONDS）的条目自动裁剪释放。

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


## 获取 (target_t, cursor_t] 时间区间内待还原的瓦片数据，按时间降序排列（最新破坏优先还原）。
func take_range(target_t: float, cursor_t: float) -> Array:
	var picked: Array = []
	for e in _entries:
		var t := float(e["t"])
		if t > target_t and t <= cursor_t:
			picked.append(e)
	picked.sort_custom(func(a, b): return float(a["t"]) > float(b["t"]))
	return picked


## 裁剪早于 cutoff_t 的历史条目（超出回溯窗口的历史记录不再保留）
func prune(cutoff_t: float) -> void:
	while not _entries.is_empty() and float(_entries[0]["t"]) < cutoff_t:
		_entries.pop_front()
