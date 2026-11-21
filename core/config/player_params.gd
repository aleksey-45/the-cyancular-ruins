class_name PlayerParams
extends RefCounted

# 碰撞矩形以角色原点为基准，使用与武器挂点相同的局部坐标。
const body_scale := 2.5
const standing_hull := Rect2(-18, -20, 32, 42.8)
const crouched_hull := Rect2(-18, -14, 32, 36.8)

const move_speed: float = 700.0
const accel_ground: float = 30.0    # 在地面移动时，控制水平速度接近目标速度的快慢。
const accel_air: float = 9.0        # 腾空时，用这个系数代替地面加速系数。
const brake_ground: float = 16.0    # 地面上没有水平移动输入时，速度按此系数趋近于 0。
const brake_air: float = 6.0        # 空中没有水平移动输入时，使用这个减速系数。
# 减速后若水平速度的绝对值低于这个阈值，就直接停下。
const stop_snap: float = 1.0

const jump_velocity: float = -1000.0
const coyote_time: float = 0.1      # 角色走出平台边缘后，在这段时间（秒）内按跳跃键仍可起跳。
const jump_buffer_time: float = 0.12  # 角色即将落地时按下跳跃键，输入会暂存这么多秒。如果期间落地，角色立即起跳。
const jump_cut_factor: float = 0.5  # 角色还在上升时松开跳跃键，垂直速度乘以该比例，跳跃高度随之降低。

const crouch_walk_speed: float = 245.0   # 按住蹲伏时，水平移动使用这个基础速度（像素/秒）。

const charge_down_velocity: float = 2000.0
const charge_velocity: float = 3000.0
const charge_duration: float = 256.0 / 3000.0   # 持续时间等于 256 像素除以冲刺初速度。
const charge_air_gravity_mult: float = 0.35   # 角色在空中冲刺时，实际重力等于场景重力乘以此值。
const charge_dir_window: float = 0.3  # 最近一次水平移动距今不超过这么多秒时，冲刺可以沿用当时的方向。

const player_swim_speed: float = 540.0    # 游泳时用这个值作为目标水平速度（像素/秒）。
const player_swim_up: float = -400.0
const player_swim_down: float = 320.0
const player_swim_accel: float = 6.0      # 控制游泳时的水平速度接近目标速度的快慢。
const player_waterproof_max: int = 10
const player_waterproof_damage: int = 5      # 氧气降为 0 后，每次溺水扣除这么多生命值。

const cam_lead_x: float = 100.0        # 达到标准跑速时，摄像机跟随点向移动方向偏移的距离（世界像素）。
const cam_y_bias: float = -100.0       # 摄像机跟随点在角色原点的上方，此值为它的垂直偏移（像素）。
const cam_smooth_x: float = 10.0       # 控制摄像机中心在水平方向上接近跟随点的快慢。
const cam_smooth_y: float = 8.0        # 控制摄像机中心在垂直方向上接近跟随点的快慢。
const cam_deadzone: float = 8.0        # 跟随点在某个轴上偏离摄像机中心超过此距离（像素）时，摄像机才沿对应的轴移动。
const cam_zoom: float = 1.0
const cam_seam_margin: float = 512.0   # 摄像机可在边缘外移动这么多像素，地形绘制范围随之扩大。

const climb_speed: float = 300.0   # 攀爬速度以此值为基础，再根据角色所处的瓦片调整。
# 沿梯子上下移动或向上攀爬铁链时使用此倍率。沿铁链下滑时由重力控制。
const climb_vertical_mult: float = 1.2
const climb_recoil_mult: float = 0.1  # 开火时若正在攀爬，后坐力乘以此值。
const climb_foot_offset: float = 57.0    # 检测脚下是否有可攀爬的瓦片时，从角色原点向下偏移这么多像素。
const elastic_bounce: float = 150.0  # 撞到弹性表面后，沿碰撞法线设置的速度分量（像素/秒）。
const step_max_height: float = 64.0   # 水平移动撞到障碍时，角色会尝试跨上不超过这个高度的台阶（像素）。

const player_max_hp: int = 50
const iframes_time: float = 0.25
const player_hit_knockback: float = 400.0
const player_hit_knockback_up: float = 200.0
const player_knock_decay_rate: float = 10.0  # 击退速度随时间按指数减小，数值越大，击退越快结束。
const hit_cam_shake: float = 8.0        # 单次伤害超过最大生命值的四分之一时，以此值作为摄像机抖动的基准幅度，再按伤害比例放大。
const hit_cam_shake_time: float = 0.25  # 受伤量超过最大生命值的四分之一时，摄像机抖动持续这么多秒。

const explosion_cam_shake: float = 30.0      # 爆炸中心处的最大摄像机抖动幅度（像素）。离中心越远，抖动越轻。
const explosion_cam_shake_time: float = 0.5  # 一次爆炸产生的摄像机抖动持续这么多秒。

const weapon_pickup_radius: float = 64.0      # 武器距角色在这个范围内时可以拾取，距离以像素计。
const weapon_drop_hold_time: float = 0.6      # 玩家至少按住丢弃键这么多秒，才会丢出当前武器。
const weapon_drop_speed: float = 400.0        # 丢出的武器沿角色当前朝向获得这个水平速度（像素/秒）。
const weapon_drop_up: float = 220.0           # 丢出的武器还会获得向上的初速度，单位为像素/秒。
const weapon_drop_offset := Vector2(24.0, -8.0)   # 武器刚丢出时相对角色原点的偏移量。水平分量随朝向翻转。
# 武器落地后，水平速度随时间按指数减小。
const weapon_ground_friction: float = 12.0
const weapon_air_drag: float = 0.4
const weapon_fall_gravity: float = 1600.0
const weapon_stop_eps: float = 6.0            # 武器已经着地且水平速度的绝对值低于此值时，停止滑动。
# 在这段时间（秒）内，刚丢出的武器不能被原持有者拾回。
const weapon_pickup_self_delay: float = 0.5
