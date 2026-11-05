class_name PredictionHistory
extends RefCounted

var frames: Dictionary[int, PredictionFrame] = {}

func remember(saved: PredictionFrame, keep: int) -> void:
	frames[saved.tick] = saved
	frames.erase(saved.tick - keep)

func discard_after(tick: int) -> void:
	for at in frames.keys():
		if at > tick:
			frames.erase(at)
