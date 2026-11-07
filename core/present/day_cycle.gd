class_name DayCycle
extends RefCounted
# 昼夜模型:**纯函数 + 常量**,不依赖任何节点。
#
# ★ 为什么单独一个文件:这套东西(太阳/月亮高度角、环境光、天空关键帧)是"一天的物理",
#   和"怎么把它画到屏幕上"(PostProcess 的 shader 参数)是两件事。之前全塞在 PostProcess 里,
#   一个 419 行的文件里混着着色器宿主 + 光照模型 + 天空数据 + 通道相机同步 + 各种视效。
#   搬出来之后:这里可以单独推演/核对(全 static),PostProcess 只管把结果喂给 shader。
#
# ★ 数据流:时刻(hour) → sun_at/moon_at → sun_light/moon_amount → ambient_for(环境光)
#                          → sky_base(天空基色)
#   PostProcess 每帧读这几个量,写进 shader uniforms。

# ── 时钟 ──
const DAY_CYCLE_SECONDS := 60.0   # 现实 60 秒 = 游戏内 24 小时(1 秒 = 24 分钟)
const DAY_START_HOUR := 6.0       # 开局时刻:早上六点
const SUNRISE_HOUR := 6.0
const SUNSET_HOUR := 18.0

# ── 环境光:天光底 + 太阳/月亮取大 ──
const AMB_BASE := 0.15       # 天光底的**默认值**;真值来自 lighting_params.tres(见 set_amb_base)
static var _amb_base: float = AMB_BASE   # 运行时由 PostProcess 按 .tres 写入

## 由 PostProcess 在启动时按 lighting_params.tres 写一次。
static func set_amb_base(v: float) -> void:
	_amb_base = clampf(v, 0.0, 1.0)
const MOON_SCALE := 0.26     # 月光峰值(必须低于晨昏的太阳项,否则半夜比傍晚亮)

# ── 由太阳高度角定义的分段阈值 ──
const ELEV_NIGHT := -18.0    # 低于它 = 全夜(只剩天光底)
const ELEV_DAY := 12.0       # 高于它 = 环境光拉满(= 原版亮度)

# ── 天空关键帧 ──
# ★ 插值走 **RGB 直线**,不走色轮:HSV 最短弧从橙(24°)到夜蓝(220°)会经过 351°→319°→
#   286°→254°,黄昏会依次变粉变紫,读起来"各种颜色乱窜"(实测)。
# ★ 直线插值的坑:两个高饱和色直接混,中点会掉饱和度(橙→夜蓝中点只有 0.31,两端 0.55/0.63)。
#   所以黄昏→夜**手工插了 3 个关键帧**把路径"拱"起来 —— 每帧都是明确选定的颜色,不是算出来的灰。
#   (单纯增加采样点没用:直线上的点还在直线上。)
# ★ 夜晚不是一档颜色:蓝调→入夜→深夜→后半夜→将明,占了整轮 1/3。
# ★ 12:00 那一帧 = 原版晴空,所以正午用 ambient=1 时精确等于原版。
const SKY_KEYS := [
	[0.0, Color("0a1220ff")],   # 子夜:最深
	[2.0, Color("0b1526ff")],   # 后半夜:略回蓝
	[3.5, Color("131f36ff")],   # 将明:开始抬亮
	[5.0, Color("8a6f9aff")],   # 黎明:带紫的晨光
	[5.8, Color("c08a92ff")],   # 日出前:暖粉(黎明自己的"颜色时刻",与黄昏对称)
	[6.5, Color("9fb9ccff")],   # 清晨
	[12.0, Color("a5d5e6ff")],  # 正午:原版晴空(必须精确)
	[16.8, Color("a7c4bfff")],  # 下午:偏暖偏淡
	[17.7, Color("c49277ff")],  # 傍晚:开始暖(比原来的 18:00 推后)
	[18.3, Color("b87a52ff")],  # 黄昏:暖琥珀(峰值)
	[18.9, Color("96687aff")],  # 玫红:降饱和,带灰紫
	[19.5, Color("6e5a9aff")],  # 紫罗兰
	[20.3, Color("34407cff")],  # 靛蓝
	[21.0, Color("22304fff")],  # 入夜
	[22.5, Color("101a2eff")],  # 夜
	[24.0, Color("0a1220ff")],  # 回到子夜(与 0.0 同值 ⇒ 首尾连续)
]


static func _ss(a: float, b: float, x: float) -> float:
	if is_equal_approx(a, b):
		return 1.0 if x >= b else 0.0
	var t := clampf((x - a) / (b - a), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


## 太阳位置:(高度角°, 方位 ±1)。高度角 < 0 = 地平线下。
## ★ 物理口径:高度角 = asin(sinδ·sinφ + cosδ·cosφ·cosH),H 是**小时角**(15°/小时)。
##   取二分点、赤道(δ=φ=0)时化简为 elev = 90° − |H|,H = 15°·(h − 12)。
##   所以一天的高度角是一条**三角波**,不是正弦(旧写法 86·sin(π(h−6)/12) 把小时角当成了高度角)。
static func sun_at(hour: float) -> Vector2:
	var h := fposmod(hour, 24.0)
	var hour_angle := (h - 12.0) * 15.0            # 度;正午 0、六点 −90、十八点 +90
	var elev := 90.0 - absf(hour_angle)            # 二分点/赤道:elev = 90 − |H|,夜里自动为负
	var azim := -1.0 if h < 12.0 else 1.0
	return Vector2(elev, azim)


## 月亮高度角(°):与太阳反相(18:00 升、00:00 天顶、06:00 落),口径同太阳。
static func moon_at(hour: float) -> float:
	var h := fposmod(hour, 24.0)
	var hour_angle := (h - 0.0) * 15.0
	var wrapped := fposmod(hour_angle + 180.0, 360.0) - 180.0   # 折到 [−180,180)
	return 90.0 - absf(wrapped)


## 白天的程度(环境光插值参数)。★ 必须**跨过地平线**:太阳刚冒头时还得是"清晨"而不是全黑。
static func day_amount(elev_deg: float) -> float:
	return _ss(ELEV_NIGHT, ELEV_DAY, elev_deg)


## 低角太阳的程度(晨昏 ⇒ 斜影与暖光)。不设上限:任何高度角都照常投。
static func low_sun_amount(elev_deg: float) -> float:
	return _ss(-6.0, 10.0, elev_deg)


## 白天的光强 0..1:辐照度 ∝ sin(高度角)。
## ★ 不用"按时刻的余弦":余弦在峰谷导数趋零,实测正午要 2.35h 看起来不变、午夜 2.71h ——
##   60 秒一天里就是好几秒完全静止。高度角是三角波,sin 升得快、峰值窄,平台自然短。
static func day_arc(hour: float) -> float:
	return clampf(sin(deg_to_rad(maxf(sun_at(hour).x, 0.0))), 0.0, 1.0)


## 月亮强度 0..1:同一口径,所以午夜也有起伏。
static func moon_amount(hour: float) -> float:
	return clampf(sin(deg_to_rad(maxf(moon_at(hour), 0.0))), 0.0, 1.0)


## 太阳的"有效高度"贡献。
## ★ 太阳项**不能在地平线归零**:sin(0°)=0 ⇒ 黎明/黄昏只剩天光底,比半夜的月光还黑
##   (实测:建筑物晚上比白天亮)。这里把有效高度抬高 18°,等价于民用晨昏,
##   于是"傍晚 > 半夜"的顺序才对。归一到 90° 恰为 1.0(正午 = 原版亮度)。
static func sun_light(sun_elev: float) -> float:
	var raw := sin(deg_to_rad(sun_elev + 18.0)) / sin(deg_to_rad(108.0))
	return pow(clampf(raw, 0.0, 1.0), 0.6)


## 平滑取"占主导的光源":不用 maxf(交点处会留折角 —— 暮色过渡会"顿一下")。
static func _soft_take(a: float, b: float) -> float:
	var t := clampf((a - b) / 0.12 + 0.5, 0.0, 1.0)
	return lerpf(b, a, smoothstep(0.0, 1.0, t))


## 环境光(恒 ∈ [0,1]):乘性、只压不抬 ⇒ 实体亮度 ≤ 贴图原值(永不发光)。
## 正午恰为 1.0 ⇒ 12:00 就是原版光照。
static func ambient_for(hour: float, moon_amt: float) -> float:
	var sun_arc := sun_light(sun_at(hour).x)
	var moon_arc := moon_amt * MOON_SCALE
	return clampf(_amb_base + (1.0 - _amb_base) * _soft_take(sun_arc, moon_arc), 0.0, 1.0)


## 某时刻的天空基色(关键帧之间 smoothstep 插值,首尾相接保证 23:59→00:00 连续)。
static func sky_base(hour: float) -> Color:
	var h := fposmod(hour, 24.0)
	var n := SKY_KEYS.size()
	for i in range(n - 1):
		var h0: float = SKY_KEYS[i][0]
		var h1: float = SKY_KEYS[i + 1][0]
		if h >= h0 and h <= h1:
			var t := 0.0 if is_equal_approx(h1, h0) else (h - h0) / (h1 - h0)
			return (SKY_KEYS[i][1] as Color).lerp(SKY_KEYS[i + 1][1] as Color, smoothstep(0.0, 1.0, t))
	return SKY_KEYS[n - 1][1]

# ── 地面/天空亮度比:按时段给定,插值得到"此刻地面该比天空暗多少" ──
# ★ 为什么用**比值**而不是单一路径的 ambient:天空是绝对值、地面是"贴图 × ambient"。
#   只调 ambient 的话,黄昏(天空亮、环境光已掉)会把建筑压成黑剪影;只调 link 又会在正午过曝。
#   给定"每个时段地面是天空的百分之几",再由砖色亮度反推 ambient 就两边都对得上。
# 取值依据:正午地面自然就比天空暗(砖反射率 ~0.48),其余时段按"天越暗、地面越贴近天空"抬。
const SKY_LINK_KEYS := [
	[0.0, 2.60],    # 子夜:天空极暗但月光照着地面 ⇒ 比值 >1
	[4.5, 1.20],    # 凌晨:天空还没亮,别把地面抬得比午夜还亮
	[5.5, 0.55],    # 天开始亮,地面跟上
	[6.5, 0.72],    # 清晨:直接抬到位,别拖到 9 点
	[9.0, 0.66],
	[12.0, 0.62],   # 正午:自然值(砖反射率)
	[15.0, 0.60],
	[18.0, 0.62],
	[18.7, 0.80],   # 黄昏:天空仍亮,故意抬高 ⇒ 建筑不再是黑剪影
	[19.3, 0.90],   # 蓝调
	[20.5, 1.30],
	[21.0, 1.70],
	[24.0, 2.60],   # 回到子夜(与 0.0 同值 ⇒ 首尾连续)
]


const BRICK_LUMA := 0.48


## 某时刻"地面亮度 / 天空亮度"的目标比值(关键帧之间 smoothstep 插值)。
static func sky_link(hour: float) -> float:
	var h := fposmod(hour, 24.0)
	var n := SKY_LINK_KEYS.size()
	for i in range(n - 1):
		var h0: float = SKY_LINK_KEYS[i][0]
		var h1: float = SKY_LINK_KEYS[i + 1][0]
		if h >= h0 and h <= h1:
			var t := 0.0 if is_equal_approx(h1, h0) else (h - h0) / (h1 - h0)
			return lerpf(SKY_LINK_KEYS[i][1], SKY_LINK_KEYS[i + 1][1], smoothstep(0.0, 1.0, t))
	return SKY_LINK_KEYS[n - 1][1]
