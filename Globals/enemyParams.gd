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
	const wake_radius: float = 1000.0     # 视野半径,屏幕外可见
	const max_chase_distance: float = 3000.0  # 距玩家超此值不启动任何寻路(直接返程)
	const home_range: float = 2000.0      # 玩家距出生点超此值 → 放弃，然后返程
	const hover_altitude: float = 40.0    # 巡航高度(路径格上方 px)
	const hover_offset_x: float = 260.0   # 斜上锚点水平偏移
	const hover_offset_y: float = 240.0   # 斜上锚点垂直偏移(上)
	const fly_speed: float = 320.0        # 飞行移动速度
	const take_off_speed: float = 750.0   # 起飞斜上初速(上跳分量 0.75x)
	const take_off_time: float = 0.5      # 起飞滑翔时长(秒)
	const shoot_range: float = 800.0      # 进入射击距离
	const shoot_reacquire_margin: float = 160.0  # 出射程余量(重接近阈值)
	const shoot_position_radius: float = 120.0  # 距斜上射击位多远算"就位"可进 SHOOT
	const shoot_cooldown: float = 1.6     # 抛弹间隔(秒)
	const strafe_range: float = 180.0    # 开火后短距随机移动最大偏移(px)
	const strafe_duration: float = 0.3   # 短距移动最长时长(秒,到点或超时结束)
	const bullet_damage: int = 2          # 投弹伤害
	const bullet_range: float = 2000.0    # 投弹射程
	const bullet_gravity: float = 0.85     # 投弹重力倍率
	const bullet_size: float = 1.2        # 投弹放大倍数(贴图+碰撞体)
	const bullet_min_speed: float = 250.0 # 平抛初速下限
	const bullet_max_speed: float = 1600.0 # 平抛初速上限
	const bullet_min_drop: float = 30.0   # 落点落差下限
	const charge_hp_fraction: float = 0.25 # 冲撞血量阈值(HP<25%)
	const charge_range: float = 1300.0    # 冲撞触发距离(且需 LOS)
	const charge_speed: float = 1000.0     # 冲撞速度
	const charge_timeout: float = 2.5     # 冲撞超时 → 自毁
	const charge_damage: int = 5          # 冲撞撞玩家伤害
	const charge_impact: float = 1500.0    # 冲撞冲击力(撞飞玩家水平速度)
	const charge_impact_up: float = 500.0 # 冲撞冲击力(上跳分量)
	const shoot_recoil: float = 500.0      # 开火后座力(鸟沿发射反方向被推)
	const repath_interval: float = 0.5    # 重寻路间隔(秒)
	const arrival_radius: float = 50.0    # 到路径格/回家判定
	const landing_time: float = 0.4       # 到家落地后多久直接入睡(不再等地板接触)
	const path_max_visit: int = 4000      # 寻路(A*)展开格数上限(预算超限时走直线兜底)
	const escape_search_range: int = 40   # 死区逃逸时向左右搜索的格数上限
	const death_flash_time: float = 0.5   # 死亡白闪时长(秒),闪完销毁
