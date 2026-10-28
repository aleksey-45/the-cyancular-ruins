extends RefCounted

# 一次"整具身体"的水判定结果:由 Water.sample_body 填,消费方只读。
# ★ 不写 class_name:headless 下全局类缓存可能滞后,用 preload 当类型最稳(Water 里已 preload 本文件)。
# ★ 本文件只存读数、不做判定 —— 出现第二个"算一次水"的地方就是第二套口径。

const SURFACE_NONE := 0     # 不在任何水袋里
const SURFACE_FREE := 1     # 自由液面:上方是空气或可穿透通道
const SURFACE_CEILING := 2  # 封闭顶:上方是墙(水袋被压住,没有自由面)
const SURFACE_FULL := 3     # 整列液体(环面绕回仍无自由面;采样有上限,不会死循环)

var in_water: bool = false          # 滞回后的结论:玩家游泳 / 敌人浮力 / 水粒子都读它
var surface_y: float = 0.0          # 所在水袋顶边(px),已归一到离身体最近的环面副本
var surface_kind: int = SURFACE_NONE
var feet_y: float = 0.0             # 采样脚底(活动碰撞箱底边)
var head_y: float = 0.0             # 采样头顶(活动碰撞箱顶边)
var feet_depth: float = 0.0         # 脚底低于水面线的深度(px);>0 = 脚在水线下
var depth_px: float = 0.0           # 与 feet_depth 同值,给表现层的别名
var head_under: bool = false        # 头顶低于水面线 ⇒ 该扣氧(玩家与敌人同一条线)
var submersion_ratio: float = 0.0   # 身体与水柱重叠占身高的比例(0..1)
