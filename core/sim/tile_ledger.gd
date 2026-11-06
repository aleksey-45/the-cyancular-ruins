class_name TileLedger
extends RefCounted


var _entries: Array = []


func record(t: float, cells: Array) -> void:
	if cells.is_empty():
		return
	_entries.append({"t": t, "cells": cells.duplicate()})


func count() -> int:
	var n := 0
	for e in _entries:
		n += (e["cells"] as Array).size()
	return n


func take_range(target_t: float, cursor_t: float) -> Array:
	var picked: Array = []
	for e in _entries:
		var t := float(e["t"])
		if t > target_t and t <= cursor_t:
			picked.append(e)
	picked.sort_custom(func(a, b): return float(a["t"]) > float(b["t"]))
	return picked


func prune(cutoff_t: float) -> void:
	while not _entries.is_empty() and float(_entries[0]["t"]) < cutoff_t:
		_entries.pop_front()


func prune_after(t: float) -> void:
	while not _entries.is_empty() and float(_entries[-1]["t"]) > t:
		_entries.pop_back()
