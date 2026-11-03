extends RefCounted

# 冲刺 / 下冲的倍率与准入判据(纯函数,无节点状态)。
# 客户端预测与服务器重放各算一遍,必须是同一份算式 —— 分叉的第一帧就会变成位置分歧。
# 三条不变式:① 时间加速把冲刺速度 ×tm、把持续时间 ÷tm ⇒ 冲刺距离与跳跃高度都不随 tm 变;
#             ② 武器减速只乘速度 ⇒ 冲刺距离跟着变短;
#             ③ 当前速度已经超过冲刺 / 下冲速度时该次冲刺无效(否则冲刺会变成刹车)。

const TIME_MULT_MIN := 0.001   # 防除零:回溯态 tm=0,但 player 在那条路径上早退了,取不到这里


## 冲刺的水平速度(px/s):基准速度 × 时间倍率 × 武器移速倍率。
static func dash_speed(base_speed: float, time_mult: float, move_mult: float) -> float:
	return base_speed * time_mult * move_mult


## 一段冲刺走完所需的真实秒数:基准时长 ÷ 时间倍率。与 dash_speed 的 ×tm 相抵 ⇒ 距离不变。
static func dash_wall_time(base_time: float, time_mult: float) -> float:
	return base_time / maxf(time_mult, TIME_MULT_MIN)


## 当前水平速度是否允许起冲刺:已经比冲刺还快就不许(冲刺只会把他拽慢)。
static func dash_allowed(current_vx: float, dash_speed_px: float) -> bool:
	return absf(current_vx) <= absf(dash_speed_px)


## 下冲同理:下落速度已经超过下冲速度就不许(下冲会把下坠拽慢)。
static func down_dash_allowed(current_vy: float, down_speed_px: float) -> bool:
	return current_vy <= down_speed_px
