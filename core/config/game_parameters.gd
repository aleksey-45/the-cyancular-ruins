class_name GameParameters
extends RefCounted

# 世界共享参数的**访问入口**(玩家专属在 PlayerParams)。
# ★ 数值不在本文件:`core/config/world_config.tres` 是唯一真相源,这里只做转发。
#   为什么不直接让调用方读 .tres:203 处调用点要 `GameParameters.xxx`,转发层保住这个写法。
# ★ 不做 autoload:本文件没有任何节点行为(官方《Autoloads versus regular nodes》:纯数据容器用 static/Resource)。
#   附带收益:`-s` 冒烟可直接引用。
#
# ★★ 为什么是"static var = _CFG.x"而不是"getter 转发":实测 getter→Resource 每次读比 const 慢 13.8×
#    (200 万次:319ms vs 23ms)。而 gravity0 这类值在**每条子弹、每个敌人、每把枪的每一帧**被读
#    (`bullet_base` / `enemy_base` / `enemy_bullet` / `weapon_base`),逐次穿 Resource 是实打实的回归。
#    改成类加载时读一次后,读成本回到 static var 量级(34ms,与 const 同数量级)。
#    代价:改 .tres 后要重启进程才生效(原本 autoload 也是这样)。
# ★ `const _CFG := preload(...)`:仓库里 .tres 缺文件/坏文件是**加载期硬失败**,
#   不会静默退化成 0(那会让重力变 0、水判定全失效,而且没人报错)。

const _CFG: WorldConfig = preload("res://core/config/world_config.tres")

# ── 结构常量(不可调,不进 .tres)──
# TILE_SIZE 不是"手感值":它是地图格式 v4 的结构定义(16px 子格 × 4),
# 且被 3 处 `const TILE_TS: int = GameParameters.TILE_SIZE` 当**编译期常量**引用 ⇒ 必须留 const。
const TILE_SIZE: int = 64

# ── 可调参数:类加载时从 .tres 读一次 ──
static var gravity0: float = _CFG.gravity0

static var water_sway_amp: float = _CFG.water_sway_amp
static var water_sway_speed: float = _CFG.water_sway_speed
static var water_fx_move_threshold: float = _CFG.water_fx_move_threshold
static var water_fx_splash_band: float = _CFG.water_fx_splash_band
static var water_fx_splash_interval: float = _CFG.water_fx_splash_interval
static var water_fx_bubble_interval: float = _CFG.water_fx_bubble_interval
static var water_bullet_drag: float = _CFG.water_bullet_drag
static var water_enter_depth: float = _CFG.water_enter_depth
static var water_exit_depth: float = _CFG.water_exit_depth
static var water_drain_interval: float = _CFG.water_drain_interval
static var water_recover_interval: float = _CFG.water_recover_interval
static var water_drown_damage_interval: float = _CFG.water_drown_damage_interval

# ── 世界像素尺寸:从当前网格派生,零存储、零写点 ──
# 网格已加载 ⇒ 网格尺寸;未加载(菜单态)⇒ 地图文件头。
# ★ 旧实现是两个可写字段:`_ready()` 按地图文件写一次、`world_builder` 加载网格后**再写一次**,
#   两者之间没有一致性断言(见 docs/systems/gameplay/world.md「参数体系」)。派生之后这种失败模式不存在。
# ★ 网格永远优先:它才是这一局真正在跑的东西,文件头只是"还没开局时"的推测值。
# (这两个是 getter:它们依赖运行时网格状态,且读取点远少于 gravity0 那批。)
static var MAP_WIDTH: int:
	get: return MazeGenerator.world_cells().x * TILE_SIZE
static var MAP_HEIGHT: int:
	get: return MazeGenerator.world_cells().y * TILE_SIZE
