class_name GameParameters
extends RefCounted

# 共享参数:物理与全局网格(玩家专属在 PlayerParams)。
# ★ 不做 autoload:本文件没有任何节点行为,只是常量 + 派生的世界尺寸。
#   Godot 官方《Autoloads versus regular nodes》:纯数据容器用 Resource / static,不做单例。
#   附带收益:`-s` 冒烟可直接引用 —— 原先 water / explosion / collision_builder 各抄一份
#   `TILE_TS = 64`,就是为了躲开"autoload 在 -s 里未实例化"。

const gravity0: float = 1600.0
const TILE_SIZE: int = 64

const water_sway_amp: float = 2.0
const water_sway_speed: float = 1.6
const water_bullet_drag: float = 2.0
const water_fx_move_threshold: float = 40.0
const water_fx_splash_band: float = 20.0
const water_fx_splash_interval: float = 0.15
const water_fx_bubble_interval: float = 0.12
const water_enter_depth: float = 8.0
const water_exit_depth: float = -2.0
const water_drain_interval: float = 1.0
const water_recover_interval: float = 0.3
const water_drown_damage_interval: float = 1.5

# ── 世界像素尺寸:从当前网格派生,零存储、零写点 ──
# 网格已加载 ⇒ 网格尺寸;未加载(菜单态)⇒ 地图文件头。
# ★ 旧实现是两个可写字段:`_ready()` 按地图文件写一次、`world_builder` 加载网格后**再写一次**,
#   两者之间没有一致性断言(见 docs/eng/world.md「参数体系」)。派生之后这种失败模式不存在。
# ★ 网格永远优先:它才是这一局真正在跑的东西,文件头只是"还没开局时"的推测值。
static var MAP_WIDTH: int:
	get: return MazeGenerator.world_cells().x * TILE_SIZE
static var MAP_HEIGHT: int:
	get: return MazeGenerator.world_cells().y * TILE_SIZE
