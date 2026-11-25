class_name RewindTape
extends RefCounted

# 死亡倒带的帧缓存和播放速度曲线。调用方提供帧数据，录制器传入 JPEG 字节数组。
# 达到容量上限后，在较早的一半画面中隔帧删除，始终保留起始帧。
# 画面短暂停在死亡时刻，再用 0.5 秒把倒放速度从 0.5 倍提高到 1 倍。
# 接着按几何级数加快倒放速度，回到起始帧后定格 0.1 秒。

const STEP0 := 1.0 / 60.0
const R_BASE := 1.04
const T_HIT := 0.10
const T_A := 0.50
const V_A0 := 0.50
const T_C := 0.10
const D_A := T_A * (V_A0 + 1.0) * 0.5          # 0.375
const T_SHOW_MAX := 3.5
const MIN_RUN := 2.5
const MAX_FRAMES := 320

var _t: Array[float] = []
var _payload: Array = []


func clear() -> void:
	_t.clear()
	_payload.clear()


func size() -> int:
	return _t.size()


func time_at(i: int) -> float:
	return _t[i]


func payload_at(i: int) -> Variant:
	return _payload[i]


func append(t: float, payload: Variant) -> void:
	_t.append(t)
	_payload.append(payload)
	_compact()


func _compact() -> void:
	# 超出上限时，降低较早一半画面的采样密度并保留起始帧。
	while _t.size() > MAX_FRAMES:
		var half := _t.size() / 2
		var nt: Array[float] = []
		var np: Array = []
		for i in _t.size():
			if i == 0:
				nt.append(_t[i])
				np.append(_payload[i])
			elif i < half and i % 2 == 1:
				continue   # 较早的画面隔帧删除。
			else:
				nt.append(_t[i])
				np.append(_payload[i])
		_t = nt
		_payload = np


## 生成倒带用的帧快照。frames 按录制时间升序排列，ages 记录各帧距死亡的游戏时间（秒）。
func freeze(now_t: float) -> Dictionary:
	var last_t := _t[_t.size() - 1] if not _t.is_empty() else now_t
	var d := clampf(now_t - _t[0] if not _t.is_empty() else 0.0, 0.0, now_t)
	var ages: Array[float] = []
	for i in _t.size():
		ages.append(maxf(now_t - _t[i], 0.0))
	return {
		"frames": _payload.duplicate(),
		"times": _t.duplicate(),
		"ages": ages,
		"run_seconds": d,
		"last_t": last_t,
		"origin_t": _t[0] if not _t.is_empty() else now_t,
	}


## 根据录制时长计算倒放速度与时长。录制时长不足时返回空字典。
static func schedule(run_seconds: float) -> Dictionary:
	var d := maxf(run_seconds, 0.0)
	if d < MIN_RUN:
		return {}
	var body := d - D_A
	if body <= STEP0:
		return {}
	var n := int(ceil(log(1.0 + body * (R_BASE - 1.0) / STEP0) / log(R_BASE)))
	n = mini(n, int((T_SHOW_MAX - T_HIT - T_A - T_C) * 60.0))
	n = maxi(n, 1)
	var r := _solve_r(body, n)
	return {
		"D": d,
		"body": body,
		"n": n,
		"r": r,
		"total": T_HIT + T_A + float(n) / 60.0 + T_C,
	}


static func _solve_r(body: float, n: int) -> float:
	var target := body / STEP0
	var lo := 1.0 + 1e-12
	var hi := 4.0
	for _i in 60:
		var mid := 0.5 * (lo + hi)
		if (pow(mid, n) - 1.0) / (mid - 1.0) < target:
			lo = mid
		else:
			hi = mid
	return 0.5 * (lo + hi)


## 根据倒放已播放的时间 tau 计算目标帧距死亡的秒数 age 和当前速度倍率 speed。
## tau ∈ [0, sched.total]；返回 Vector2(age, speed)。
static func age_at(tau: float, sched: Dictionary) -> Vector2:
	var d: float = sched["D"]
	var r: float = sched["r"]
	var n: int = sched["n"]
	if tau <= T_HIT:
		return Vector2(0.0, 1.0)
	var t := tau - T_HIT
	if t < T_A:
		var a := t / T_A
		var age := T_A * (V_A0 * a + 0.5 * (1.0 - V_A0) * a * a)
		return Vector2(age, lerpf(V_A0, 1.0, a))
	var t_geo := t - T_A
	var nf := t_geo * 60.0
	var age2 := D_A + STEP0 * (pow(r, nf) - 1.0) / (r - 1.0)
	return Vector2(minf(age2, d), pow(r, nf))


## 在 ages（按最老→最新排列，值为距死亡秒数，递减）里找最接近 target 的帧。
static func pick_index(ages: Array, target: float) -> int:
	if ages.is_empty():
		return -1
	# ages 递减：二分找第一个 <= target 的位置，再比较左右。
	var lo := 0
	var hi := ages.size() - 1
	while lo < hi:
		var mid := (lo + hi) / 2
		if ages[mid] > target:
			lo = mid + 1
		else:
			hi = mid
	var best := lo
	if lo > 0 and absf(ages[lo - 1] - target) < absf(ages[lo] - target):
		best = lo - 1
	return best
