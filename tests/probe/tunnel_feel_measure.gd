extends Node

# 帧耗时与卡顿监控采样器。挂载于场景树根节点（root），跨场景切换保持连续采样。
#
# 设计说明：
# 不采用 Engine.get_frames_per_second() 是因为其输出为每秒平均值，容易抹平瞬时单帧尖峰。
# 本采样器记录逐物理帧 delta 耗时，并在采样结束时计算分位数与各等级卡顿统计：
# - 60 FPS 标准单帧预算：~16.67ms
# - 轻度掉帧：> 16.7ms
# - 明显掉帧：> 33.3ms
# - 严重卡顿：> 50.0ms

const BUDGET_MS := 1000.0 / 60.0        # 16.67
const STALL_1_MS := 16.7
const STALL_2_MS := 33.3
const STALL_3_MS := 50.0

var side := "?"

var _frames: PackedFloat32Array = PackedFloat32Array()
var _acc := 0.0
var _stall1 := 0
var _stall2 := 0
var _stall3 := 0
var _max_ms := 0.0
var _max_at := 0.0
var _elapsed := 0.0
# 每秒最大帧耗时记录（供测试报告绘制趋势与定位异常区间）
var _per_sec: Array[String] = []
var _sec_ms: Array[float] = []


func _process(delta: float) -> void:
	var ms := delta * 1000.0
	_elapsed += delta
	_frames.append(ms)
	if ms > _max_ms:
		_max_ms = ms
		_max_at = _elapsed
	if ms > STALL_1_MS:
		_stall1 += 1
	if ms > STALL_2_MS:
		_stall2 += 1
	if ms > STALL_3_MS:
		_stall3 += 1
	_sec_bucket(ms)


func _sec_bucket(ms: float) -> void:
	var sec := int(_elapsed)
	while _sec_ms.size() <= sec:
		_sec_ms.append(-1.0)
	# 记录该秒内的最大单帧耗时峰值
	if ms > _sec_ms[sec]:
		_sec_ms[sec] = ms


# 计算指定比例（p）的耗时分位数（Percentile）
func _pct(p: float) -> float:
	if _frames.is_empty():
		return 0.0
	var a := _frames.duplicate()
	a.sort()
	var i := int(round(p * float(a.size() - 1)))
	return a[clampi(i, 0, a.size() - 1)]


func report_lines() -> Array[String]:
	var out: Array[String] = []
	var n := _frames.size()
	var span := 0.0
	for v in _frames:
		span += float(v)
	var fps := (float(n) * 1000.0 / span) if span > 0.0 else 0.0
	out.append("frames=%d" % n)
	out.append("fps_avg=%.1f" % fps)
	out.append("ft_p50=%.2f" % _pct(0.50))
	out.append("ft_p95=%.2f" % _pct(0.95))
	out.append("ft_p99=%.2f" % _pct(0.99))
	out.append("ft_max=%.2f" % _max_ms)
	out.append("ft_max_at=%.2f" % _max_at)
	out.append("stall_gt16_7=%d" % _stall1)
	out.append("stall_gt33_3=%d" % _stall2)
	out.append("stall_gt50=%d" % _stall3)
	# 统计单帧耗时峰值最高的前 5 个秒级区间（用于定位卡顿出现的具体时刻）
	var idx: Array = []
	for i in range(_sec_ms.size()):
		if _sec_ms[i] > 0.0:
			idx.append([i, _sec_ms[i]])
	idx.sort_custom(func(a, b): return float(a[1]) > float(b[1]))
	var worst: Array[String] = []
	for k in range(mini(5, idx.size())):
		worst.append("%ds:%.0fms" % [int(idx[k][0]), float(idx[k][1])])
	out.append("worst_seconds=%s" % ",".join(worst))
	return out
