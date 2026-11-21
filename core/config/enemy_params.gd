class_name EnemyParams
extends RefCounted
# 转向、水中移动和溺水规则由各类敌人共用。
class shared:
	const hit_reaction_time: float = 0.1
	const corpse_time: float = 0.5
	const turn_min_interval: float = 0.5  # 改变朝向后，至少等这么多秒才能再次转向。
	const bird_swim_speed: float = 260.0   # 敌人在水中追击玩家时的目标水平速度（像素/秒）。
	const bird_buoyancy_k: float = 6.0     # 用敌人原点与水面的高度差乘以此系数，得到目标垂直速度。
	const bird_max_float: float = 260.0    # 上浮速度上限（像素/秒）。
	const bird_max_sink: float = 160.0     # 下沉速度上限（像素/秒）。
	const bird_water_damp: float = 5.0     # 控制敌人当前速度在水中接近目标速度的快慢。
	const drown_interval: float = 1.5      # 进入水中后，每隔这么多秒结算一次溺水伤害。
	const drown_damage: int = 5

class JumpBird:
	const wake_radius: float = 900.0    # 玩家进入这个距离后，跳鸟从休眠状态醒来。
	const wake_time: float = 0.5
	const settle_time: float = 0.5
	const give_up_radius: float = 1100.0 # 玩家离开这个范围后，跳鸟停止追击并进入休眠。
	const lunge_range: float = 400.0    # 玩家进入这个距离后，跳鸟可以开始为扑击蓄力。
	const lunge_max_dist: float = 450.0 # 跳鸟扑击时，累计移动距离达到此值就结束攻击。
	const lunge_speed: float = 1100.0
	const lunge_windup: float = 0.30    # 跳鸟开始蓄力到发起扑击的时间（秒）。
	const hop_interval: float = 0.55    # 连续追击时，两次起跳至少相隔这么多秒。
	const hop_horizontal_speed: float = 240.0  # 追击跳跃的基础水平速度（像素/秒），实际速度随起跳方向调整。
	const hop_jump_velocity: float = -750.0
	const back_hop_up: float = -520.0
	const back_hop_away: float = 320.0  # 扑击结束后，跳鸟按攻击方向的反方向跳开。

class FlyBird:
	const wake_radius: float = 1100.0     # 玩家进入这个距离后，飞鸟被唤醒。
	const wake_time: float = 0.5
	const settle_time: float = 0.5
	const max_chase_distance: float = 2000.0  # 玩家离飞鸟超过这个距离时，飞鸟放弃追击。
	const home_range: float = 2000.0      # 玩家离飞鸟的出生点超过这个距离时，飞鸟返回出生点。
	const hover_altitude: float = 40.0    # 飞行目的地相对于投弹点或出生点的悬停高度（像素）。
	const hover_offset_x: float = 260.0   # 投弹目标点位于玩家左侧或右侧，水平偏移量为此值（像素）。
	const hover_offset_y: float = 240.0   # 投弹目标点与玩家之间的高度差（像素）。
	const fly_speed: float = 320.0
	const take_off_speed: float = 750.0   # 起飞时，朝向玩家的单位向量的水平分量乘以此值得到水平速度。向上的初速度为此值的四分之三。
	const take_off_time: float = 0.5
	const shoot_range: float = 800.0      # 飞鸟在此距离内才会进入投弹状态。
	const shoot_reacquire_margin: float = 160.0  # 投弹状态的退出距离比进入距离多这么多像素，飞鸟在边界附近不会频繁改变动作。
	const shoot_position_radius: float = 120.0  # 飞鸟到达投弹目标点的这个范围内，才开始投弹。
	const shoot_cooldown: float = 1.6     # 发射后至少等这么多秒才可再投一枚。
	const strafe_range: float = 180.0    # 投弹后的移动目标在悬停位置附近随机选取，两个轴的偏移都不超过此值（像素）。
	const strafe_duration: float = 0.3   # 投弹后的移动在到达目标或经过这么多秒后结束，以先发生的为准。
	const bullet_damage: int = 2
	const bullet_range: float = 2000.0
	const bullet_gravity: float = 0.85     # 弹丸的下落加速度等于场景重力乘以此值。
	const bullet_size: float = 1.2        # 飞鸟投出的弹丸按此值等比缩放，贴图与碰撞形状使用同一比例。
	const bullet_min_speed: float = 312.5 # 计算抛射轨迹时，水平初速度不能低于此值（像素/秒）。
	const bullet_max_speed: float = 2000.0 # 计算抛射轨迹时，水平初速度不能高于此值（像素/秒）。
	const bullet_min_drop: float = 30.0   # 目标与飞鸟的高度差较小时，以这个最小值估算飞行时间（像素）。
	const charge_hp_fraction: float = 0.25 # 剩余生命值低于最大生命值的这个比例后，飞鸟改用冲撞。
	const charge_range: float = 1300.0    # 飞鸟等到玩家进入这个距离且中间无地形遮挡，才会冲撞。
	const charge_speed: float = 1000.0
	const charge_timeout: float = 2.5     # 冲撞达到此时长（秒）时，飞鸟结束飞行并自毁。
	const charge_damage: int = 5
	const charge_impact: float = 1500.0    # 冲撞命中后，目标以此速度向远离飞鸟的方向移动（像素/秒）。
	const charge_impact_up: float = 500.0 # 目标受到冲撞击退时，额外获得的向上速度（像素/秒）。
	const shoot_recoil: float = 500.0      # 飞鸟投弹时获得一个与弹丸水平移动方向相反的速度增量。
	const repath_interval: float = 0.75    # 周期性寻路的基础间隔（秒）。每只飞鸟在此基础上加一个固定的随机偏移，错开寻路时间。
	const arrival_radius: float = 50.0    # 飞鸟到出生点的距离不超过此值时，开始降落。
	const landing_time: float = 0.4       # 飞鸟回到出生点后，经过这段降落时间（秒）才重新休眠。
	const path_max_visit: int = 600       # A* 搜索每次访问的子格数上限。
	const search_radius_cells: int = 180  # A* 搜索半径，单位为 16 像素子格。
	const escape_search_range: int = 360  # 绕过障碍时，在左右两个方向上至多搜索这么多格。
	const escape_max_descent: int = 160     # 从当前高度往下找绕行位置时，至多检查这么多行子格。

class BlackBird:
	const wake_radius: float = 1000.0     # 玩家靠近到这个距离内时，乌鸫结束休眠。
	const wake_time: float = 0.625
	const settle_time: float = 0.625
	const sleep_radius: float = 1200.0   # 巡逻时，玩家离开这个范围后乌鸫重新休眠。
	const wander_speed: float = 300.0
	const wander_min_t: float = 1.0      # 乌鸫随机决定这一轮巡逻要走多久，此值是秒数下限。
	const wander_max_t: float = 3.0      # 一轮巡逻所随机选取的行走秒数不能超过此值。
	const wander_idle_max: float = 1.5   # 每轮巡逻开始前，乌鸫随机停顿，最长为此值（秒）。
	const wander_jump_velocity: float = -500.0  # 乌鸫巡逻撞墙后起跳时，使用这个值作为垂直初速度。
	const take_off_jump_velocity: float = -1000.0  # 找到传送位置后，乌鸫原地起跳时的垂直初速度。
	const flank_check_interval: float = 1.0  # 传送冷却结束后，乌鸫每隔这么多秒尝试寻找传送位置。
	const teleport_min_range := 128.0    # 传送落点与玩家的最小像素距离。
	const teleport_max_range := 384.0    # 传送落点与玩家的最大像素距离。
	const teleport_drop: float = 250.0    # 乌鸫传送到选定位置上方这么多像素处，随后开始下落。
	const landing_timeout: float = 0.3   # 从传送到允许继续执行冲刺准备的最长时间（秒）。
	const teleport_prep_time: float = 0.6
	const teleport_entry_time: float = 0.1
	const teleport_hover_time: float = 0.7
	const charge_prep_time: float = 0.4     # 结束等待落地后，到实际冲刺之间的蓄力时间（秒）。
	const teleport_cooldown: float = 3.0    # 结束冲刺后，经过这段冷却时间（秒）才再次寻找传送位置。
	const charge_speed: float = 900.0
	const charge_damage: int = 7         # 冲刺可对处于受击无敌时间内的目标造成伤害。
	const charge_impact: float = 1500.0  # 冲刺命中后，目标以此速度向远离乌鸫的方向移动（像素/秒）。
	const charge_impact_up: float = 500.0  # 冲刺击退目标时额外增加的向上速度（像素/秒）。
	const charge_timeout: float = 2.5    # 冲刺持续这么多秒后结束，乌鸫随后跳开。
	const charge_jump_velocity: float = -650.0  # 冲刺撞上侧墙后，乌鸫以这个速度向上起跳。
	const back_hop_up: float = -500.0    # 冲刺结束时，乌鸫向后跳开的垂直速度（像素/秒）。
	const back_hop_away: float = 800.0   # 乌鸫在冲刺结束时，沿远离玩家的方向跳开。此值控制水平速度。
