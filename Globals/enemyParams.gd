class_name EnemyParams
extends RefCounted
# 敌人参数集中地。每个敌人一个嵌套类,专属数值归位;跨敌人共享的放 shared。
# 访问方式: EnemyParams.JumpBird.wake_radius / EnemyParams.shared.hit_flash。
# 加新敌人 = 在此加一个嵌套类,不污染全局 GameParameters。

class shared:
	const hit_flash: float = 0.1        # 受击白闪时长(秒)

class JumpBird:
	const wake_radius: float = 900.0    # 玩家多近苏醒
	const give_up_radius: float = 1100.0 # 玩家多远放弃追击
	const lunge_range: float = 400.0    # 冲刺触发距离
	const lunge_max_dist: float = 450.0 # 冲刺最远距离
	const lunge_speed: float = 1100.0   # 冲刺速度
	const lunge_windup: float = 0.30    # 冲刺蓄力时间
	const hop_interval: float = 0.55    # 跳跃间隔
	const hop_horizontal_speed: float = 240.0  # 跳跃水平速度
	const hop_jump_velocity: float = -750.0   # 跳跃高度
	const back_hop_up: float = -520.0   # 后跳高度
	const back_hop_away: float = 320.0  # 后跳距离
