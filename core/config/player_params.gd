class_name PlayerParams
extends RefCounted

# 玩家专属参数集中地(从 gameParameters 拆出)。gameParameters 只留共享参数
# (gravity0/TILE_SIZE/地图尺寸/敌人生成)。访问方式: PlayerParams.move_speed。
# 与 EnemyParams 同风格: RefCounted + const,不做 autoload。

# ── 行走手感(方案 A)──
const move_speed: float = 700.0
const accel_ground: float = 30.0    # 地面加速缓动系数(越大起步越跟手)
const accel_air: float = 9.0        # 空中加速
const brake_ground: float = 16.0    # 地面松键减速(带一点滑行)
const brake_air: float = 6.0        # 空中松键减速
# 水平速度低于此值直接归零(避免贴地滑行 / 极慢速抖动)。
# 原先是 scenes/player/player.gd 里的 const STOP_SNAP,climb_component 里还抄过一份死副本 ——
# 归到这里,免得再被抄第二遍(移动手感数值的唯一去处就是本文件)。
const stop_snap: float = 1.0

# ── 跳跃手感(方案 A)──
const jump_velocity: float = -1000.0
const coyote_time: float = 0.1      # 离开地面后仍可起跳的时间(秒)
const jump_buffer_time: float = 0.12  # 落地前提前按跳的缓冲时间(秒)
const jump_cut_factor: float = 0.5  # 上升中松键时向上速度的衰减比例

# ── 下蹲 ──
const crouch_walk_speed: float = 245.0   # 蹲走水平速度(≈0.35×move_speed)

# ── 冲刺 ──
const charge_down_velocity: float = 2000.0
const charge_velocity: float = 1900.0   # 冲刺速度(1500→1900)
const charge_duration: float = 0.4    # 0.6→0.4(600px,保留长距离但可跳/墙打断)
const charge_air_gravity_mult: float = 0.35   # 空中冲刺重力倍率(<1=变平)
const charge_dir_window: float = 0.3  # 冲刺方向沿用最近移动方向的窗口(秒)

# ── 游泳 ──
const player_swim_speed: float = 540.0    # 水中水平移速(≈0.77×700)
const player_swim_up: float = -400.0      # 上浮速度
const player_swim_down: float = 320.0     # 下沉速度
const player_swim_accel: float = 6.0      # 水中水平缓动系数
const player_waterproof_max: int = 10        # 防水值(氧气)上限
const player_waterproof_damage: int = 5      # 防水值空后每秒扣血
# 呼吸扣减触发线:原判定「水面没过角色原点(≈胸口)才扣」;把参考线下移该像素到胸口下沿,
# 使「大部分(约2/3)没入、头能露出」时就开始扣呼吸,且要浮到水面低于此线才回气。
# (可调:越大=越早扣、要浮得越高才回气)
const water_breath_line_offset: float = 10.0

# ── 镜头手感(方案 A)──
const cam_lookahead_x: float = 100.0   # 满速时的水平前瞻像素
const cam_lookahead_y: float = 80.0    # 满速上升/下落时的垂直前瞻像素
const cam_y_bias: float = -100.0       # 基础向上偏移(保留原 100px)
const cam_smooth_x: float = 10.0       # X 平滑指数系数
const cam_smooth_y: float = 8.0        # Y 平滑指数系数
const cam_deadzone: float = 8.0        # 死区像素(小于此值镜头不动)
# 相机缩放(<1 = 视野更大;0.75 = 4→3 整数下采样,像素缩放最干净、无滚动抖动)
const cam_zoom: float = 0.75

# ── 攀爬 / 弹性 ──
const climb_speed: float = 300.0   # 攀爬基准速度(上爬 × tile_defs climb_speed:梯 1.6/锁链 2.0)
# 上行/梯子下行整体倍率:上爬(梯&锁链)与梯子下行都 ×1.2;锁链下行=自由落体不受影响。
const climb_vertical_mult: float = 1.2
const elastic_bounce: float = 150.0  # 弹性瓦片(树叶)弱反弹冲量

# ── 玩家战斗 ──
const player_max_hp: int = 50
const iframes_time: float = 0.25
const player_hit_knockback: float = 400.0
const player_hit_knockback_up: float = 200.0
const player_knock_decay_rate: float = 10.0  # 爆炸击退向量指数衰减率(越大停得越快)
const hit_cam_shake: float = 8.0        # 大伤害(一次扣血 >25% 最大血)相机震动基准幅度
const hit_cam_shake_time: float = 0.25  # 大伤害相机震动时长(秒)

# ── 爆炸镜头震动 ──
const explosion_cam_shake: float = 30.0      # 爆炸相机震动基准幅度(爆炸贴近玩家时,px)
const explosion_cam_shake_time: float = 0.5  # 爆炸相机震动时长(秒)

# ── 武器拾取 / 丢弃(2026-09-15,武器槽位计划)──
const weapon_pickup_radius: float = 64.0      # 可拾取半径(1 格)
const weapon_drop_hold_time: float = 2.0      # 长按 Q 多久算丢弃(用户指定 2s)
const weapon_drop_speed: float = 400.0        # 丢弃初速(水平,朝朝向)
const weapon_drop_up: float = 220.0           # 丢弃初速(向上)
const weapon_drop_offset := Vector2(24.0, -8.0)   # 掉落物生成点相对玩家的偏移
# 落地摩擦(指数衰减率)。"较大"= 很快停住。★ 与 weapon_stop_eps 一起构成
# 「落点与何时开始模拟无关」这条不变量(联机端客户端晚一个 RTT 才开始模拟,落点必须一致):
# 靠**速度衰减 + 阈值置零**,而不是"滑固定时长"。
const weapon_ground_friction: float = 12.0
const weapon_air_drag: float = 0.4            # 空中阻力(小)
const weapon_fall_gravity: float = 1600.0     # 落体重力
const weapon_stop_eps: float = 6.0            # 水平速度低于此值即置零(并标记 settled)
# 自己刚丢下的枪在这么久内不参与自己的拾取判定(防"丢-捡"抖动)
const weapon_pickup_self_delay: float = 0.5
