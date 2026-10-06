class_name TileLedger
extends RefCounted

# 玩家拆砖账本(第一阶段·瓦片回溯):记录每次破坏的格与其**改前值**,回拨时按时间倒序还原。
# 与 WorldRewind 共用同一时间轴(Level0 传 WorldRewind.recorded_seconds() 作为 t)。
# 纯数据(-s 可测);世界写入由 Level0 的 _restore_cell 执行。
#
# 语义要点:
#   · 只记**玩家造成**的破坏(Level0 在 _on_tile_destroyed 捕获;系统/事件造成的走别的口)。
#   · 同一格可能被多次破坏(先炸掉原砖 → 又被 gen 类事件补上 → 再拆):还原必须 **t 降序**
#     (最新一次破坏先还原=写回最近的改前值,再往前推,最早的值最后落地) → 与 LIFO 一致。
#   · 超出缓冲窗口(TimeParams.SNAP_SECONDS)的条目裁掉:那些格已经"回不去"了。

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
