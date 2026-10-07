extends Node

# 全局共享参数：供玩家、敌人与子弹等实体共享的物理常数、世界网格规格与敌人生成参数。
# 玩家独立参数已移至 PlayerParams（包含移动、跳跃、冲刺、相机与战斗相关参数）。

# ── 基础物理参数（全局共享）──
const gravity0: float = 1600.0
const TILE_SIZE: int = 64

# ── 水体物理与表现参数 ──
const water_sway_amp: float = 2.0        # 水面起伏振幅（像素，用于顶部网格形变拉伸）
const water_sway_speed: float = 1.6      # 水面晃动角速度（rad/s）
const water_bullet_drag: float = 2.0     # 子弹在水中的指数阻力衰减系数（exp(-drag·Δt)）
const water_fx_move_threshold: float = 40.0   # 实体在水中的移动速度低于此阈值时不发射水花粒子
const water_fx_splash_band: float = 20.0     # 实体底部距离水面高度差在此范围内判定为表面水花
const water_fx_splash_interval: float = 0.15
const water_fx_bubble_interval: float = 0.12
const water_drain_interval: float = 1.0    # 完全浸水状态下防水值（氧气）每 1s 扣除 1 点
const water_recover_interval: float = 0.3  # 脱离水面暴露在空气中时每 0.3s 恢复 1 点
const water_drown_damage_interval: float = 1.5  # 防水值耗尽后的溺水扣除生命值间隔（秒）

var MAP_WIDTH: int
var MAP_HEIGHT: int

func _ready() -> void:
	# 地图尺寸以实际加载的地图规格为准动态刷新
	refresh_map_size()

# 根据当前选定的地图文件重新计算世界像素尺寸。
# PvP 服务端与单人模式切换地图后必须调用此方法更新：
# 避免不同尺寸地图（如 125×75 与 150×100）导致环面回绕与寻路边界错位产生错误的物理阻挡。
func refresh_map_size() -> void:
	var cells := MazeGenerator.map_size()
	MAP_WIDTH = cells.x * TILE_SIZE
	MAP_HEIGHT = cells.y * TILE_SIZE
