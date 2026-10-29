class_name PlayerParams
extends RefCounted

# 玩家专属参数集中地:RefCounted + const,不做 autoload(与 EnemyParams 同风格);gameParameters
# 只留共享参数(gravity0/TILE_SIZE/地图尺寸/敌人生成),访问方式 PlayerParams.move_speed。
const move_speed: float = 700.0
const accel_ground: float = 30.0    # 地面加速缓动系数(越大起步越跟手)
const accel_air: float = 9.0        # 空中加速
const brake_ground: float = 16.0    # 地面松键减速(带一点滑行)
const brake_air: float = 6.0        # 空中松键减速
# 水平速度低于此值直接归零(避免贴地滑行 / 极慢速抖动)。★ 移动手感数值的唯一去处就是本文件,别再抄第三份。
const stop_snap: float = 1.0

const jump_velocity: float = -1000.0
const coyote_time: float = 0.1      # 离开地面后仍可起跳的时间(秒)
const jump_buffer_time: float = 0.12  # 落地前提前按跳的缓冲时间(秒)
const jump_cut_factor: float = 0.5  # 上升中松键时向上速度的衰减比例

const crouch_walk_speed: float = 245.0   # 蹲走水平速度(≈0.35×move_speed)

const charge_down_velocity: float = 2000.0
const charge_distance: float = 256.0    # 冲刺总距离(px;2026-10-29 用户定为原 640 的 40%)
const charge_velocity: float = 3000.0   # 冲刺速度(2026-10-28 用户指定)
const charge_duration: float = charge_distance / charge_velocity   # = charge_distance / charge_velocity ≈ 0.0853s(可跳/墙打断仍有效)
const charge_air_gravity_mult: float = 0.35   # 空中冲刺重力倍率(<1=变平)
const charge_dir_window: float = 0.3  # 冲刺方向沿用最近移动方向的窗口(秒)

const player_swim_speed: float = 540.0    # 水中水平移速(≈0.77×700)
const player_swim_up: float = -400.0      # 上浮速度
const player_swim_down: float = 320.0     # 下沉速度
const player_swim_accel: float = 6.0      # 水中水平缓动系数
const player_waterproof_max: int = 10        # 防水值(氧气)上限
const player_waterproof_damage: int = 5      # 防水值空后每秒扣血

const cam_lookahead_x: float = 100.0   # 满速时的水平前瞻像素
const cam_lookahead_y: float = 80.0    # 满速上升/下落时的垂直前瞻像素
const cam_y_bias: float = -100.0       # 基础向上偏移(保留原 100px)
const cam_smooth_x: float = 10.0       # X 平滑指数系数
const cam_smooth_y: float = 8.0        # Y 平滑指数系数
const cam_deadzone: float = 8.0        # 死区像素(小于此值镜头不动)
# 相机缩放(<1 = 视野更大;0.75 = 4→3 整数下采样,像素缩放最干净、无滚动抖动)
const cam_zoom: float = 0.75

# 攀爬速度(2026-10-28 用户指定绝对值,不再乘瓦片倍率/上行倍率;时间场倍率照乘)。
# 梯子:上 850 / 下 800;锁链:上 800(锁链下行仍是自由落体,由 climb_component 解除攀附交重力)。
const climb_ladder_up_speed: float = 850.0
const climb_ladder_down_speed: float = 800.0
const climb_chain_up_speed: float = 800.0
const elastic_bounce: float = 150.0  # 弹性瓦片(树叶)弱反弹冲量

const player_max_hp: int = 50
const iframes_time: float = 0.25
const player_hit_knockback: float = 400.0
const player_hit_knockback_up: float = 200.0
const player_knock_decay_rate: float = 10.0  # 爆炸击退向量指数衰减率(越大停得越快)
const hit_cam_shake: float = 8.0        # 大伤害(一次扣血 >25% 最大血)相机震动基准幅度
const hit_cam_shake_time: float = 0.25  # 大伤害相机震动时长(秒)

const explosion_cam_shake: float = 30.0      # 爆炸相机震动基准幅度(爆炸贴近玩家时,px)
const explosion_cam_shake_time: float = 0.5  # 爆炸相机震动时长(秒)

const weapon_pickup_radius: float = 64.0      # 可拾取半径(1 格)
const weapon_drop_hold_time: float = 0.6      # 长按 Q 多久算丢弃(手感值,用户多轮收紧到 0.6s)
const weapon_drop_speed: float = 400.0        # 丢弃初速(水平,朝朝向)
const weapon_drop_up: float = 220.0           # 丢弃初速(向上)
const weapon_drop_offset := Vector2(24.0, -8.0)   # 掉落物生成点相对玩家的偏移
# ★ 落地摩擦与 weapon_stop_eps 一起构成「落点与何时开始模拟无关」这条不变量(联机端客户端晚一个 RTT 才开始模拟,落点必须一致):靠速度衰减 + 阈值置零,而不是"滑固定时长"。
const weapon_ground_friction: float = 12.0
const weapon_air_drag: float = 0.4            # 空中阻力(小)
const weapon_fall_gravity: float = 1600.0     # 落体重力
const weapon_stop_eps: float = 6.0            # 水平速度低于此值即置零(并标记 settled)
const weapon_pickup_self_delay: float = 0.5

# 补间形变(squash & stretch,实现见 scenes/effects/squash_stretch.gd):上限 0.06 = 满冲击时最少 0.94 / 最多 1.06,
# 每项都是在 [-1,1] 的合成量上相乘 ⇒ 叠加多少事件都不会超上限。★ 这组常量在 EnemyParams.shared 有一份同名同值
# 副本(8 个同名:amount / recover / land_min_vy / land_ref_vy / land / hurt / air / air_ref_vy),两侧刻意不共享常量
# ⇒ 改一侧要问另一侧是否也该改;零守卫(squash_stretch_smoke.gd 已删·2026-10-09 曾逐名钉这 8 个同值),两份漂移是真隐患。
const squash_amount: float = 0.06          # 满冲击形变量
const squash_recover: float = 16.0         # 冲击回归速率(指数,越大回正越快)
const squash_jump: float = 0.75            # 起跳拉伸
const squash_land_min_vy: float = 220.0    # 落速低于此不挤压(下小台阶不触发)
const squash_land_ref_vy: float = 900.0    # 达到此落速 = 满挤压
const squash_land: float = 1.00            # 落地挤压上限
const squash_hurt: float = 0.50            # 受击挤压
const squash_dash: float = 0.80            # 冲刺拉伸
const squash_air: float = 0.10             # 空中连续项上限
const squash_air_ref_vy: float = 700.0     # 空中连续项参考速度
