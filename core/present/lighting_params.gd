class_name LightingParams
extends Resource
# 光照参数表:**只有 schema 和默认值**,真正的数值在 `lighting_params.tres`。
#
# ★ 为什么不做成常量写在 .gd 里:这些是**观感调参**,不是逻辑。放进 Resource 好处有三:
#   ① 在检查器里直接拖、改完立刻生效,不用改代码重启;
#   ② .tres 是纯数据,git diff 能看清"哪个数值被动了";
#   ③ 单机 / PvP / 菜单可以用不同的 .tres 实例,不用写分支。
# ★ .gd 里保留的默认值 = "没配 .tres 时的兜底",别把调好的值只写在这里。

@export_group("环境光")
## 天光底:夜里也不会全黑的底线(乘性,只压不抬)。
@export_range(0.0, 0.6, 0.01) var amb_base: float = 0.15
## 环境光染色强度:0 = 纯白环境光,1 = 完全按天空色的色相染色。三通道恒 ≤ 1,只染色不提亮。
@export_range(0.0, 1.0, 0.01) var amb_tint_strength: float = 0.35
## 地面色相拉向光源的权重:0 = 纯乘(蓝墙在暖光下仍发蓝),1 = 完全取光源色相(只剩明暗)。
@export_range(0.0, 1.0, 0.01) var amb_hue_mix: float = 0.5
## 地面亮度跟随天空亮度的系数:ambient 至少 = 天空亮度 × 该值(0 = 关闭)。
@export_range(0.0, 2.0, 0.01) var amb_sky_link: float = 1.3
## 白天环境地板:受光方向项把亮度从"地板"顶到 1.0,不是把整屏一起压暗。
@export_range(0.1, 1.0, 0.01) var amb_floor_day: float = 0.55
## 夜里环境地板。
@export_range(0.05, 0.8, 0.01) var amb_floor_night: float = 0.30

@export_group("形体光(玩家/武器/敌人)")
## 背光面压暗强度上限。
@export_range(0.0, 1.0, 0.01) var form_gain: float = 0.50
## 预提亮量:贴图先整体乘 (1+boost),再只压暗面 ⇒ 亮面可高于原图、暗面低于原图,平均接近原值。
@export_range(0.0, 0.5, 0.01) var form_boost: float = 0.15
## 精灵明暗色阶数(像素化):0/1 = 关闭(连续渐变),3 = 亮/中/暗三档。
@export_range(0.0, 6.0, 1.0) var form_steps: float = 4.0
## 精灵明暗抖动强度(0 = 硬色阶;1 = 满强度 Bayer)。
@export_range(0.0, 1.0, 0.01) var form_dither: float = 0.3
## 椭球鼓起系数:>1 = 球面感更强(1.0 = 包围盒原始椭球)。
@export_range(0.5, 3.0, 0.01) var form_bulge: float = 1.0

@export_group("地形受光")
## 地形受光强度:0 = 关闭(墙只吃环境光),越大墙的竖向体积感越强。
@export_range(0.0, 0.8, 0.01) var terrain_gain: float = 0.25
## 地形受光的色阶数(像素化):0/1 = 关闭。
@export_range(0.0, 6.0, 1.0) var terrain_steps: float = 4.0
## 地形受光抖动强度(0 = 硬色阶;1 = 满强度 Bayer)。
@export_range(0.0, 1.0, 0.01) var terrain_dither: float = 1.0

@export_group("影子")
## 影子远端残留:影子里最淡的那一端保留多少亮度。
@export_range(0.0, 1.0, 0.01) var shadow_far: float = 0.32
