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

class FlyBird:
	const wake_radius: float = 1500.0     # 视野半径,屏幕外可见
	const home_range: float = 2200.0      # 玩家距出生点超此值 → 放弃返程
	const hover_altitude: float = 40.0    # 巡航高度(路径格上方 px)
	const hover_offset_x: float = 260.0   # 斜上锚点水平偏移
	const hover_offset_y: float = 240.0   # 斜上锚点垂直偏移(上)
	const fly_speed: float = 280.0        # 飞行移动速度
	const take_off_speed: float = 750.0   # 起飞斜上初速(上跳分量 0.75x)
	const take_off_time: float = 0.5      # 起飞滑翔时长(秒)
	const shoot_range: float = 520.0      # 进入射击距离
	const shoot_reacquire_margin: float = 160.0  # 出射程余量(重接近阈值)
	const shoot_cooldown: float = 1.4     # 抛弹间隔(秒)
	const bullet_damage: int = 2          # 投弹伤害
	const bullet_range: float = 1600.0    # 投弹射程
	const bullet_gravity: float = 1.0     # 投弹重力倍率
	const bullet_color: Color = Color(1.0, 0.6, 0.2, 1.0)  # 橙色投弹
	const bullet_min_speed: float = 260.0 # 平抛初速下限
	const bullet_max_speed: float = 1400.0 # 平抛初速上限
	const bullet_min_drop: float = 30.0   # 落点落差下限
	const charge_hp_fraction: float = 0.25 # 冲撞血量阈值(HP<25%)
	const charge_range: float = 1300.0    # 冲撞触发距离(且需 LOS)
	const charge_speed: float = 950.0     # 冲撞速度
	const charge_timeout: float = 2.5     # 冲撞超时 → 自毁
	const charge_damage: int = 5          # 冲撞撞玩家伤害
	const repath_interval: float = 0.5    # 重寻路间隔(秒)
	const arrival_radius: float = 50.0    # 到路径格/回家判定
