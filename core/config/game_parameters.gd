class_name GameParameters
extends RefCounted

# 物理模拟和地图绘制共用这些参数。距离以游戏世界中的像素计，速度以像素/秒计。

const gravity0: float = 1600.0

const water_sway_amp: float = 2.0        # 水面上下摆动的最大偏移（像素）。
const water_sway_speed: float = 1.6      # 水面波形随时间变化的角速度（弧度/秒）。
const water_bullet_drag: float = 2.0     # 弹丸在水中按指数减速。数值越大，速度下降越快。
const water_fx_move_threshold: float = 40.0   # 只有物体速度达到此值（像素/秒），才会播放水花或气泡效果。
const water_fx_splash_band: float = 20.0     # 脚底在水面下的深度超过碰撞形状半高加此值时，播放气泡效果。较浅时在水面播放水花。
const water_fx_splash_interval: float = 0.15
const water_fx_bubble_interval: float = 0.12
const water_drain_interval: float = 1.0    # 头部在水下时，每隔这么多秒扣除 1 点氧气。
const water_recover_interval: float = 0.3  # 头部露出水面后，每隔这么多秒补充 1 点氧气。
const water_drown_damage_interval: float = 1.5  # 氧气降为 0 后，相邻两次溺水伤害的时间间隔（秒）。
