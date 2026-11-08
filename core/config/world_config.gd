class_name WorldConfig
extends Resource
# 世界共享参数表:**只有 schema 和默认值**,真正生效的数值在 `world_config.tres`。
#
# ★ 什么进这里:物理手感与水的一整套阈值 —— 会被反复调、又不属于任何单个实体的数。
#   不进这里:`TILE_SIZE`(地图格式 v4 的结构常量,16px 子格 × 4,且被 `const` 上下文引用)。
#
# ★ .gd 里的默认值 = "在检查器里新建一份实例时的起点";**运行时永远读 `world_config.tres`**
#   (由 `GameParameters` 以 `const` preload 引入 ⇒ 缺文件是编译期/加载期硬失败,不会静默退化成 0)。

@export_group("物理")
## 全局重力加速度(px/s²)。改它同时改变跳跃高度、子弹下坠、敌人滞空。
@export_range(0.0, 4000.0, 1.0) var gravity0: float = 1600.0

@export_group("水面(纯表现)")
## 水面格上下起伏幅度(px,顶边拉伸)。
@export_range(0.0, 16.0, 0.1) var water_sway_amp: float = 2.0
## 水面起伏角速度(rad/s)。
@export_range(0.0, 8.0, 0.01) var water_sway_speed: float = 1.6
## 实体移动速度低于此值不发射水粒子。
@export_range(0.0, 400.0, 1.0) var water_fx_move_threshold: float = 40.0
## 脚底距水面线 ≤ 此值算溅水花(px)。
@export_range(0.0, 200.0, 1.0) var water_fx_splash_band: float = 20.0
## 溅水花粒子发射间隔(秒)。
@export_range(0.0, 2.0, 0.01) var water_fx_splash_interval: float = 0.15
## 水下气泡发射间隔(秒)。
@export_range(0.0, 2.0, 0.01) var water_fx_bubble_interval: float = 0.12

@export_group("水(玩法)")
## 子弹水中的指数阻力系数:速度 ×= exp(-drag·Δt)。
@export_range(0.0, 20.0, 0.01) var water_bullet_drag: float = 2.0
## 入水判定:脚底低于水面线 ≥ 此值(px)才进"在水中" —— 与 exit_depth 构成**滞回**。
@export_range(0.0, 64.0, 0.1) var water_enter_depth: float = 8.0
## 出水判定:脚底高于水面线 ≥ 2px 才退"在水中";两值之间保持上一帧结论。
@export_range(-64.0, 0.0, 0.1) var water_exit_depth: float = -2.0
## 没顶(head_under)时防水值每这么久掉 1(秒)。
@export_range(0.05, 10.0, 0.01) var water_drain_interval: float = 1.0
## 暴露空气时防水值每这么久回 1(秒)。
@export_range(0.05, 10.0, 0.01) var water_recover_interval: float = 0.3
## 防水值空后扣血间隔(秒)。
@export_range(0.05, 10.0, 0.01) var water_drown_damage_interval: float = 1.5
