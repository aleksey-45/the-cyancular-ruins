class_name RewindTape
extends RefCounted

# 死亡倒带的纯逻辑：内存环形缓冲 + 按年龄抽稀 + 回放加速曲线。
# 不碰 Node / Image / 文件；payload 由调用方给（录制侧是 JPEG PackedByteArray）。
#
# 曲线：显示帧几何级数 step_i = step_0 * r^i（step_0=1/60，r=1.04），
# 前面 0.5s 死亡慢放（0.5×→1×，吃掉 D_A=0.375 游戏秒），最后 0.1s 原点定格。
# 曲线参数只在死亡瞬间算一次（D 已知）；录制期按"最老帧再抽稀一半"控制内存。

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
	# 超上限时把"最老的一半"隔一个扔一个（保留最老那一帧 = 原点）。
	while _t.size() > MAX_FRAMES:
		var half := _t.size() / 2
		var nt: Array[float] = []
		var np: Array = []
		for i in _t.size():
			if i == 0:
				nt.append(_t[i])
				np.append(_payload[i])
			elif i < half and i % 2 == 1:
				continue   # 老段抽稀一半
			else:
				nt.append(_t[i])
				np.append(_payload[i])
		_t = nt
		_payload = np


## 冻结成回放带：frames 按 t 升序；ages 是"距死亡的游戏秒"（最老 = 最大）。
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


## 由一局时长算回放调度；返回 {} = 不播（太短/无帧）。
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


## 演出经过 tau 秒时：要倒回到多少游戏秒（age），当前倍率 speed。
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
