extends Node

# 整机帧耗时采样探针(诊断用,代理可跑;场景模式跑,autoload 可用):
#   godot --headless --path . res://Tests/frame_perf_probe.tscn
# 本场景只当启动器:真干活的 worker 挂在 root 下(穿越 change_scene 存活——
# change_scene_to_file 会把 current_scene(即本场景)立刻摘树,不能在这里直接采样)。
# 流程:切 Level0 单机世界 → 采样基线帧间隔 → 生成烟区(道具同款)再采样 → 输出 avg/p95/max。
# headless 下无渲染,量的是脚本/物理侧每帧成本;与渲染侧卡顿互斥,用于二分归因。

const BASE_FRAMES := 600
const SMOKE_FRAMES := 300


func _ready() -> void:
	var worker := Node.new()
	worker.name = "PerfWorker"
	worker.set_script(load("res://Tests/frame_perf_probe_worker.gd"))
	get_tree().root.add_child.call_deferred(worker)
